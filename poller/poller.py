"""
tapo-poller — continuous multi-camera clip downloader and S3 uploader.

Each camera runs in its own thread with its own independent poll/sleep
cycle, so a slow or backlogged camera never delays the others. Cameras
can override the global poll interval, and battery-powered cameras can
define a "night_mode" window with a longer (not zero) interval to avoid
draining the battery overnight while still preventing a huge backlog
from building up before sunrise.

Battery-powered cameras can also stop being polled to save battery: by
hand, through an expiring SSM override set from GitHub Actions
(camera-override.yml), or automatically below a battery threshold
(auto_pause), checking the battery now and then until it has recharged.

Tracks last-seen clip per camera in a shared state file (guarded by a
lock, since multiple threads write to it).

Usage:
    python3 poller.py [--config /path/to/config.yaml]
"""
import argparse
import asyncio
import json
import logging
import os
import socket
import threading
import time
from datetime import datetime, timezone, timedelta
from pathlib import Path

import boto3
import yaml
from botocore.config import Config
from botocore.exceptions import ClientError
from pytapo import Tapo
from pytapo.media_stream.downloader import Downloader

# ── Logging ───────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("tapo-poller")


def setup_cloudwatch_logging(profile: str, region: str, log_group: str) -> None:
    """
    Mirror all log output — this module's, plus library loggers like
    asyncio's (e.g. the "Task was destroyed" warnings) — to a CloudWatch
    Logs group, in addition to the existing journal/stdout output.

    Attached to the root logger (not just "tapo-poller") so it's
    inclusive of everything running in this process.

    Best-effort: if this fails at startup (package not installed, bad
    profile), log a warning and keep running without it rather than
    refusing to start the poller over a logging feature. Nothing here may
    call AWS: setup runs once, often right after a power cut, before the
    internet is back. Sends that fail later are dropped by watchtower's
    own thread, which keeps going.
    """
    try:
        import watchtower

        session = boto3.Session(profile_name=profile, region_name=region)
        handler = watchtower.CloudWatchLogHandler(
            boto3_client=session.client("logs"),
            log_group_name=log_group,
            log_stream_name=socket.gethostname(),
            # Terraform owns the group (poller.tf). Creating it (or setting
            # tags or retention here) is an API call in the constructor.
            create_log_group=False,
            send_interval=10,   # batch and flush at most every 10s
        )
        handler.setFormatter(logging.Formatter(
            "%(asctime)s [%(levelname)s] %(name)s: %(message)s",
            datefmt="%Y-%m-%d %H:%M:%S",
        ))
        logging.getLogger().addHandler(handler)
        logger.info(f"☁️  CloudWatch log shipping enabled (group: {log_group})")
    except Exception as e:
        logger.warning(f"⚠️  Could not enable CloudWatch log shipping: {e}")


# ── CLI ───────────────────────────────────────────────────
parser = argparse.ArgumentParser(description="Tapo camera clip poller")
parser.add_argument(
    "--config",
    default=os.path.join(os.path.dirname(__file__), "config.yaml"),
    help="Path to config.yaml",
)


# ── Config ────────────────────────────────────────────────
def load_config(path: str) -> dict:
    with open(path) as f:
        return yaml.safe_load(f)


def get_camera_interval(camera: dict, config: dict) -> int:
    """
    Resolve the poll interval (seconds) for a camera right now, accounting
    for an optional per-camera night_mode window.

    camera["interval_seconds"] overrides the global default.
    camera["night_mode"] = {
        enabled: true,
        start_hour: 22,          # local hour, 0-23
        end_hour: 6,              # local hour, 0-23 (wraps past midnight)
        interval_seconds: 1800,   # slower cadence during the window
    }
    """
    default_interval = config["poller"]["interval_seconds"]
    base_interval = camera.get("interval_seconds", default_interval)

    night_cfg = camera.get("night_mode")
    if not night_cfg or not night_cfg.get("enabled"):
        return base_interval

    hour = datetime.now().astimezone().hour
    start_hour = night_cfg["start_hour"]
    end_hour = night_cfg["end_hour"]

    if start_hour > end_hour:
        # window wraps past midnight, e.g. 22 -> 6
        in_window = hour >= start_hour or hour < end_hour
    else:
        in_window = start_hour <= hour < end_hour

    if in_window:
        return night_cfg.get("interval_seconds", base_interval)
    return base_interval


# ── State ─────────────────────────────────────────────────
def load_state(path: str) -> dict:
    """Load last-seen state per camera. Returns empty dict if file missing."""
    try:
        with open(path) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save_state(path: str, state: dict) -> None:
    """Persist state atomically."""
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f, indent=2)
    os.replace(tmp, path)   # atomic on Linux


# ── AWS ───────────────────────────────────────────────────
def make_s3_client(profile: str, region: str):
    # A single boto3 low-level client is safe to share across threads
    # for concurrent independent calls (unlike boto3 Resources).
    session = boto3.Session(profile_name=profile, region_name=region)
    return session.client("s3")


def make_cloudwatch_client(profile: str, region: str):
    session = boto3.Session(profile_name=profile, region_name=region)
    return session.client("cloudwatch")


def make_ssm_client(profile: str, region: str):
    # Short timeouts and few retries: the override is read before every
    # cycle, and an SSM outage must not stall polling.
    session = boto3.Session(profile_name=profile, region_name=region)
    return session.client(
        "ssm",
        config=Config(connect_timeout=3, read_timeout=3, retries={"max_attempts": 2}),
    )


def emit_metric(
    cloudwatch_client, metric_name: str, camera_name: str, value: float = 1.0, unit: str = "Count"
) -> None:
    """
    Push a heartbeat/error metric to CloudWatch. Failures here are logged
    but never raised — a metrics outage must never take down the poller
    or block an upload.
    """
    try:
        cloudwatch_client.put_metric_data(
            Namespace="Tapo/Camera",
            MetricData=[
                {
                    "MetricName": metric_name,
                    "Dimensions": [{"Name": "CameraName", "Value": camera_name}],
                    "Value": value,
                    "Unit": unit,
                }
            ],
        )
    except Exception as e:
        logger.warning(f"  ⚠️  [{camera_name}] Failed to emit {metric_name} metric: {e}")


def upload_to_s3(
    s3_client,
    local_path: str,
    bucket: str,
    camera_name: str,
    date: str,
) -> bool:
    filename = os.path.basename(local_path)
    s3_key = f"clips/{camera_name}/{date}/{filename}"
    try:
        s3_client.upload_file(local_path, bucket, s3_key)
        logger.info(f"  ☁️  [{camera_name}] Uploaded s3://{bucket}/{s3_key}")
        return True
    except ClientError as e:
        logger.error(f"  ❌  [{camera_name}] Upload failed: {e}")
        return False


# ── Download ──────────────────────────────────────────────
async def download_clip(
    tapo: Tapo,
    clip: dict,
    time_correction: int,
    output_dir: str,
    camera_name: str,
) -> str | None:
    """
    Download a single clip. Returns local file path on success, None on failure.
    """
    start_time = clip["startTime"]
    end_time = clip["endTime"]
    duration = end_time - start_time

    start_dt = datetime.fromtimestamp(start_time, timezone.utc)
    time_str = start_dt.strftime("%H%M%S")
    file_name = f"{camera_name}_{time_str}_{duration}s.mp4"
    local_path = os.path.join(output_dir, file_name)

    if os.path.exists(local_path):
        logger.debug(f"  ⏭  [{camera_name}] Already exists locally: {file_name}")
        return local_path

    downloader = Downloader(
        tapo,
        start_time,
        end_time,
        time_correction,
        output_dir + "/",
        None,
        False,
        None,
        fileName=file_name,
    )

    saw_converting = False
    skipped = False
    interrupted = False

    async for status in downloader.download():
        action = status.get("currentAction", "")

        if action == "Recording in progress":
            logger.info(f"  ⏸  [{camera_name}] Recording in progress — skipping {file_name}")
            interrupted = True
            break
        elif action == "Skipping":
            logger.info(f"  ⏭  [{camera_name}] Already exists: {file_name}")
            skipped = True
        elif action == "Downloading":
            progress = status.get("progress", 0)
            total = status.get("total", 0)
            if total > 0:
                pct = min(int((progress / total) * 100), 100)
                bar = ("█" * (pct // 5)).ljust(20)
                print(
                    f"\r  ⬇  [{camera_name}] [{bar}] {pct}% {file_name}",
                    end="",
                    flush=True,
                )
        elif action == "Converting":
            print()  # newline after progress bar
            saw_converting = True
            logger.info(f"  🔄  [{camera_name}] Converting: {file_name}")

    if interrupted:
        return None

    if skipped or saw_converting:
        return local_path

    logger.warning(f"  ⚠️  [{camera_name}] No completion signal for {file_name}")
    return None


def persist_clip_progress(
    state_lock: threading.Lock,
    state_file: str,
    camera_name: str,
    start_time: int,
) -> None:
    """
    Immediately persist a single confirmed-uploaded clip's start_time to
    the shared state file. Called after every successful upload+local-delete
    (not just once at the end of a poll cycle) so that a restart mid-cycle
    resumes from the actual last confirmed clip instead of replaying
    everything already uploaded in that cycle.
    """
    with state_lock:
        full_state = load_state(state_file)
        cam_state = full_state.get(camera_name, {})
        if start_time > cam_state.get("last_start_time", 0):
            cam_state["last_start_time"] = start_time
            cam_state["last_poll"] = int(time.time())
            full_state[camera_name] = cam_state
            save_state(state_file, full_state)


# ── Pausing: manual override and battery auto-pause ──────
OVERRIDE_PARAMETER_PREFIX = "/tapo/poller/override/"
OVERRIDE_MODES = ("pause", "poll")
DEFAULT_PROBE_INTERVAL_SECONDS = 3 * 3600


def parse_override(value: str, camera_name: str):
    """
    Parse an override parameter value, written by camera-override.yml:
      {"mode": "pause" | "poll", "until": "2026-10-29T12:00:00Z", "set_by": "..."}
    "pause" stops contacting the camera; "poll" polls it even while
    auto-paused. Returns a dict with a timezone-aware "until", or None if
    the value is malformed (logged, then ignored: polling goes on as normal).
    """
    try:
        data = json.loads(value)
        mode = data["mode"]
        until = datetime.fromisoformat(data["until"].replace("Z", "+00:00"))
    except (ValueError, KeyError, TypeError, AttributeError) as e:
        logger.warning(f"  ⚠️  [{camera_name}] Ignoring malformed override {value!r}: {e}")
        return None
    if mode not in OVERRIDE_MODES or until.tzinfo is None:
        logger.warning(f"  ⚠️  [{camera_name}] Ignoring override with unknown mode or no timezone: {value!r}")
        return None
    return {"mode": mode, "until": until, "set_by": data.get("set_by")}


def read_override(ssm_client, camera_name: str, cache: dict):
    """
    Return the camera's active override, or None. A missing parameter means
    no override. If SSM can't be reached, the last value read is kept (and
    still expires on time); after a restart with SSM down there is no last
    value, so polling is normal. Never raises.
    """
    if ssm_client is not None:
        try:
            response = ssm_client.get_parameter(Name=OVERRIDE_PARAMETER_PREFIX + camera_name)
            cache["override"] = parse_override(response["Parameter"]["Value"], camera_name)
        except ClientError as e:
            if e.response.get("Error", {}).get("Code") == "ParameterNotFound":
                cache["override"] = None
            else:
                logger.warning(f"  ⚠️  [{camera_name}] Could not read override, keeping last known: {e}")
        except Exception as e:
            logger.warning(f"  ⚠️  [{camera_name}] Could not read override, keeping last known: {e}")

    override = cache.get("override")
    if override and override["until"] > datetime.now(timezone.utc):
        return override
    return None


def validate_auto_pause(camera: dict) -> None:
    """
    Check a camera's auto_pause settings at startup:
      auto_pause:
        pause_below_percent: 35
        resume_above_percent: 55
        probe_interval_seconds: 10800   # battery check while paused
    Invalid settings disable auto-pause for that camera (logged as an error)
    instead of stopping the poller, so uploads go on.
    """
    cfg = camera.get("auto_pause")
    if cfg is None:
        return
    try:
        valid = (
            camera.get("battery_powered") is True
            and 0 <= cfg["pause_below_percent"] < cfg["resume_above_percent"] <= 100
            and cfg.get("probe_interval_seconds", DEFAULT_PROBE_INTERVAL_SECONDS) > 0
        )
    except (KeyError, TypeError):
        valid = False
    if not valid:
        logger.error(
            f"❌  [{camera['name']}] Invalid auto_pause settings {cfg!r} (needs battery_powered: true and "
            f"0 <= pause_below_percent < resume_above_percent <= 100): auto-pause disabled"
        )
        camera.pop("auto_pause")


def update_auto_pause(camera: dict, cam_state: dict, percent, camera_name: str) -> bool:
    """
    Apply the auto_pause thresholds to a battery reading and return whether
    the camera is (still) auto-paused. Two thresholds, so a reading around
    one level doesn't switch between pausing and polling every cycle.
    Without a reading (percent is None), the previous decision stands.
    """
    cfg = camera.get("auto_pause")
    if not cfg:
        cam_state.pop("auto_paused", None)
        return False

    paused = cam_state.get("auto_paused", False)
    if percent is not None:
        if not paused and percent < cfg["pause_below_percent"]:
            paused = True
            logger.warning(
                f"  🪫  [{camera_name}] Battery {percent}% < {cfg['pause_below_percent']}%: auto-pausing downloads"
            )
        elif paused and percent > cfg["resume_above_percent"]:
            paused = False
            logger.info(
                f"  🔋  [{camera_name}] Battery {percent}% > {cfg['resume_above_percent']}%: resuming downloads"
            )
    cam_state["auto_paused"] = paused
    return paused


def emit_skipped_cycle(cloudwatch_client, camera_name: str) -> None:
    """
    Metrics for a cycle skipped on purpose, without contacting the camera.
    PollCycleCompleted is the heartbeat ("the thread ran"), so the heartbeat
    alarm stays a plain one-metric alarm instead of metric math, which bills
    every metric in the expression. PollCyclePaused says nothing was polled,
    so availability (SLO) numbers can subtract paused cycles.
    """
    if cloudwatch_client:
        emit_metric(cloudwatch_client, "PollCycleCompleted", camera_name)
        emit_metric(cloudwatch_client, "PollCyclePaused", camera_name)


def seconds_until_battery_check(camera: dict, cam_state: dict, now: float = None) -> float:
    """
    While auto-paused, seconds until the next battery check is due; 0 when
    it is due now, or when the camera isn't auto-paused (poll as normal).
    """
    cfg = camera.get("auto_pause")
    if not cfg or not cam_state.get("auto_paused"):
        return 0.0
    now = time.time() if now is None else now
    due = cam_state.get("last_battery_check", 0) + cfg.get(
        "probe_interval_seconds", DEFAULT_PROBE_INTERVAL_SECONDS
    )
    return max(0.0, due - now)


async def report_battery(loop, tapo, camera_name: str, cloudwatch_client=None):
    """
    Log and emit the battery level of a battery-powered camera, and return
    it (None if it couldn't be read). Reuses the session poll_camera already
    opened, so it costs no extra wake. Best-effort: a failure is logged and
    ignored, never counted as a poll error, and never blocks the downloads
    that follow.
    """
    try:
        response = await loop.run_in_executor(None, tapo.getBatteryStatus)
        status = response["battery"]["status"]
        percent = status["battery_percent"]
    except Exception as e:
        logger.warning(f"  ⚠️  [{camera_name}] Could not read battery status: {e}")
        return None

    logger.info(
        f"  🔋  [{camera_name}] Battery {percent}% "
        f"(charging: {status.get('battery_charging')}, {status.get('battery_temperature')}°C)"
    )
    if cloudwatch_client:
        emit_metric(cloudwatch_client, "BatteryPercent", camera_name, percent, unit="Percent")
    return percent


# ── Camera poll (single pass, one camera) ────────────────
async def poll_camera(
    camera: dict,
    config: dict,
    state: dict,
    s3_client,
    tmp_dir: str,
    cloudwatch_client=None,
    state_lock: threading.Lock = None,
    state_file: str = None,
    force_poll: bool = False,
) -> dict:
    name = camera["name"]
    ip = camera["ip"]
    user = camera["user"]
    password = camera["password"]
    bucket = config["aws"]["bucket"]

    logger.info(f"📷  [{name}] Polling ({ip})")

    # Heartbeat: emitted regardless of outcome below, so absence of this
    # metric means the poller thread itself is dead or hung — not that
    # there was simply nothing to upload.
    if cloudwatch_client:
        emit_metric(cloudwatch_client, "PollCycleCompleted", name)

    # Connect in a thread executor — Tapo() runs its own internal event loop
    # which clashes with the outer asyncio loop if called directly from async context
    def connect():
        tapo = Tapo(ip, user, password, password)
        time_correction = tapo.getTimeCorrection()
        return tapo, time_correction

    try:
        loop = asyncio.get_running_loop()
        tapo, time_correction = await loop.run_in_executor(None, connect)
    except Exception as e:
        logger.error(f"  ❌  [{name}] Connection failed: {e}")
        if cloudwatch_client:
            emit_metric(cloudwatch_client, "PollCycleErrors", name)
        return state

    if camera.get("battery_powered"):
        percent = await report_battery(loop, tapo, name, cloudwatch_client)
        cam_state = state.setdefault(name, {})
        # Recorded even if the read failed, so a failing read can't turn
        # every cycle into a battery check (one wake each).
        cam_state["last_battery_check"] = int(time.time())
        if update_auto_pause(camera, cam_state, percent, name):
            if not force_poll:
                logger.info(f"  ⏸️  [{name}] Auto-paused (low battery): skipping downloads")
                if cloudwatch_client:
                    emit_metric(cloudwatch_client, "PollCyclePaused", name)
                return state
            logger.info(f"  ⏩  [{name}] Auto-paused, but a poll override is active: downloading")

    # Determine date range to check — today + yesterday to catch midnight boundary
    now = datetime.now(timezone.utc)
    dates = [
        (now - timedelta(days=1)).strftime("%Y%m%d"),
        now.strftime("%Y%m%d"),
    ]

    last_seen = state.get(name, {}).get("last_start_time", 0)
    new_last_seen = last_seen

    camera_tmp = os.path.join(tmp_dir, name)
    os.makedirs(camera_tmp, exist_ok=True)

    for date in dates:
        try:
            recordings = await loop.run_in_executor(
                None, tapo.getRecordings, date
            )
        except Exception as e:
            logger.error(
                f"  ❌  [{name}] Could not get recordings on {date}: {e}"
            )
            if cloudwatch_client:
                emit_metric(cloudwatch_client, "PollCycleErrors", name)
            continue

        # Filter to only clips newer than last_seen
        new_clips = []
        for entry in recordings:
            for clip in entry.values():
                if clip["startTime"] > last_seen:
                    new_clips.append(clip)

        if not new_clips:
            logger.info(f"  ✅  [{name}] No new clips on {date}")
            continue

        logger.info(f"  📋  [{name}] {len(new_clips)} new clip(s) on {date}")

        for clip in new_clips:
            local_path = await download_clip(
                tapo, clip, time_correction, camera_tmp, name
            )

            if local_path and os.path.exists(local_path):
                success = upload_to_s3(s3_client, local_path, bucket, name, date)

                if success:
                    os.remove(local_path)
                    logger.info(
                        f"  🗑️  [{name}] Deleted local: {os.path.basename(local_path)}"
                        )
                    new_last_seen = max(new_last_seen, clip["startTime"])
                    # Persist immediately — don't wait for the whole cycle
                    # to finish. If the process is killed right after this
                    # line, we've lost nothing: this clip is already safely
                    # in S3 and recorded as done.
                    if state_lock is not None and state_file is not None:
                        persist_clip_progress(state_lock, state_file, name, clip["startTime"])
                else:
                    logger.warning(
                        f"  ⚠️  [{name}] Upload failed — keeping local file for retry next run"
                    )
            else:
                logger.warning(
                    f"  ⚠️  [{name}] Download failed or skipped for clip at {clip['startTime']}"
                )

    # Update state only if we made progress
    if new_last_seen > last_seen:
        if name not in state:
            state[name] = {}
        state[name]["last_start_time"] = new_last_seen
        state[name]["last_poll"] = int(time.time())

    return state


# ── Per-camera worker thread ──────────────────────────────
def camera_worker(
    camera: dict,
    config: dict,
    s3_client,
    state_lock: threading.Lock,
    state_file: str,
    tmp_dir: str,
    cloudwatch_client=None,
    startup_delay: float = 0.0,
    ssm_client=None,
) -> None:
    """
    Runs forever in its own thread. Polls one camera, sleeps for that
    camera's own interval (which may vary by time of day via night_mode),
    and repeats — completely independent of every other camera's thread.

    A cycle is skipped without contacting the camera while a "pause"
    override is active, or while it is auto-paused and no battery check
    is due. A skipped cycle still emits the PollCycleCompleted heartbeat
    (the thread is alive), plus PollCyclePaused to say why nothing was
    polled; see emit_skipped_cycle.

    startup_delay staggers each camera's *first* poll so all threads
    don't hit their cameras' auth handshake at the exact same moment
    when the service starts.
    """
    name = camera["name"]

    if startup_delay > 0:
        time.sleep(startup_delay)

    # One event loop per thread, for the thread's entire lifetime — not
    # recreated every cycle. pytapo's media-stream download uses async
    # generators internally (e.g. HttpMediaSession.transceive) that
    # aren't always finalized the instant our coroutine returns; Python
    # closes them via garbage collection at a time of its own choosing,
    # scheduled onto this loop. Destroying the loop every 15 minutes
    # could kill that finalizer mid-flight ("Task was destroyed but it
    # is pending"). Keeping the loop alive across cycles means any
    # deferred cleanup from cycle N just runs at the start of cycle
    # N+1's run_until_complete() instead of being cut off.
    loop = asyncio.new_event_loop()
    override_cache = {}

    try:
        while True:
            interval = get_camera_interval(camera, config)
            override = read_override(ssm_client, name, override_cache)
            mode = override["mode"] if override else None

            with state_lock:
                state = load_state(state_file)
            check_in = seconds_until_battery_check(camera, state.get(name, {}))

            if mode == "pause":
                remaining = (override["until"] - datetime.now(timezone.utc)).total_seconds()
                logger.info(
                    f"⏸️  [{name}] Paused by override ({override.get('set_by') or 'unknown'}) until "
                    f"{override['until'].astimezone(timezone.utc):%Y-%m-%d %H:%M} UTC: not contacting the camera"
                )
                emit_skipped_cycle(cloudwatch_client, name)
                sleep_for = min(interval, max(remaining, 1))
            elif check_in > 0 and mode != "poll":
                logger.info(
                    f"⏸️  [{name}] Auto-paused (low battery): next battery check in {check_in / 60:.0f} min"
                )
                emit_skipped_cycle(cloudwatch_client, name)
                sleep_for = min(interval, check_in)
            else:
                if mode == "poll":
                    logger.info(
                        f"⏩  [{name}] Poll override ({override.get('set_by') or 'unknown'}) until "
                        f"{override['until'].astimezone(timezone.utc):%Y-%m-%d %H:%M} UTC"
                    )
                try:
                    updated_state = loop.run_until_complete(
                        poll_camera(
                            camera, config, state, s3_client, tmp_dir,
                            cloudwatch_client=cloudwatch_client,
                            state_lock=state_lock,
                            state_file=state_file,
                            force_poll=mode == "poll",
                        )
                    )
                except Exception as e:
                    logger.error(
                        f"  ❌  [{name}] Unexpected error in poll cycle: {e}", exc_info=True
                        )
                    if cloudwatch_client:
                        emit_metric(cloudwatch_client, "PollCycleErrors", name)
                    updated_state = state

                # Belt-and-suspenders final sync — poll_camera already persists
                # progress incrementally after every clip via persist_clip_progress,
                # so this is normally a no-op write of values already on disk.
                # It stays as a safety net for the (rare) case a whole cycle
                # completes with in-memory state ahead of what got persisted.
                # It is also where the auto-pause decision gets saved, so it
                # survives a restart.
                with state_lock:
                    full_state = load_state(state_file)
                if name in updated_state:
                    full_state[name] = updated_state[name]
                save_state(state_file, full_state)
                sleep_for = interval

            logger.info(f"💤  [{name}] sleeping {sleep_for:.0f}s until next poll...")
            time.sleep(sleep_for)
    finally:
        # Only reached if the while loop is ever broken out of (it isn't,
        # currently — this is a safety net, not a normal code path).
        loop.close()


# ── Main ──────────────────────────────────────────────────
def main():
    args = parser.parse_args()  # here, not at import, so tests can import the module
    config = load_config(args.config)
    state_file = config["poller"]["state_file"]

    setup_cloudwatch_logging(
        config["aws"]["profile"],
        config["aws"]["region"],
        config.get("poller", {}).get("cloudwatch_log_group", "tapo-poller"),
    )

    s3_client = make_s3_client(
        config["aws"]["profile"],
        config["aws"]["region"],
    )
    cloudwatch_client = make_cloudwatch_client(
        config["aws"]["profile"],
        config["aws"]["region"],
    )
    ssm_client = make_ssm_client(
        config["aws"]["profile"],
        config["aws"]["region"],
    )
    for camera in config["cameras"]:
        validate_auto_pause(camera)

    tmp_dir = os.path.join(os.path.dirname(__file__), "tapo_clips")
    state_lock = threading.Lock()

    logger.info("🚀  Tapo poller starting (independent per-camera threads)")
    logger.info(f"   Cameras : {[c['name'] for c in config['cameras']]}")
    logger.info(f"   State   : {state_file}")
    logger.info(f"   Bucket  : {config['aws']['bucket']}")

    # Stagger each camera's first poll by a few seconds so we don't hit
    # every camera's auth handshake in the same instant at startup.
    STARTUP_STAGGER_SECONDS = 8

    threads = []
    for i, camera in enumerate(config["cameras"]):
        t = threading.Thread(
            target=camera_worker,
            args=(camera, config, s3_client, state_lock, state_file, tmp_dir),
            kwargs={
                "cloudwatch_client": cloudwatch_client,
                "startup_delay": i * STARTUP_STAGGER_SECONDS,
                "ssm_client": ssm_client,
            },
            name=f"poller-{camera['name']}",
            daemon=True,
        )
        t.start()
        threads.append(t)
        logger.info(f"   Started thread for {camera['name']} (startup delay {i * STARTUP_STAGGER_SECONDS}s)")

    try:
        # Main thread just idles — the daemon worker threads do the work.
        # Idling in a loop (rather than thread.join()) keeps Ctrl+C responsive.
        while True:
            time.sleep(60)
    except KeyboardInterrupt:
        logger.info("🛑  Shutting down (Ctrl+C received)")


if __name__ == "__main__":
    main()
