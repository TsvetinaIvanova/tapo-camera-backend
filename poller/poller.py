"""
tapo-poller — continuous multi-camera clip downloader and S3 uploader.

Runs in a loop, polling each camera every interval_seconds.
Tracks last-seen clip per camera in a state file to avoid re-downloading.

Usage:
    python3 poller.py [--config /path/to/config.yaml]
"""
import argparse
import asyncio
import json
import logging
import os
import sys
import time
from datetime import datetime, timezone, timedelta
from pathlib import Path

import boto3
import yaml
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

# ── CLI ───────────────────────────────────────────────────
parser = argparse.ArgumentParser(description="Tapo camera clip poller")
parser.add_argument(
    "--config",
    default=os.path.join(os.path.dirname(__file__), "config.yaml"),
    help="Path to config.yaml",
)
args = parser.parse_args()


# ── Config ────────────────────────────────────────────────
def load_config(path: str) -> dict:
    with open(path) as f:
        return yaml.safe_load(f)


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
    session = boto3.Session(profile_name=profile, region_name=region)
    return session.client("s3")


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
        logger.info(f"  ☁️  Uploaded s3://{bucket}/{s3_key}")
        return True
    except ClientError as e:
        logger.error(f"  ❌  Upload failed: {e}")
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
    end_time   = clip["endTime"]
    duration   = end_time - start_time

    start_dt   = datetime.fromtimestamp(start_time, timezone.utc)
    time_str   = start_dt.strftime("%H%M%S")
    file_name  = f"{camera_name}_{time_str}_{duration}s.mp4"
    local_path = os.path.join(output_dir, file_name)

    if os.path.exists(local_path):
        logger.debug(f"  ⏭  Already exists locally: {file_name}")
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
    skipped        = False
    interrupted    = False

    async for status in downloader.download():
        action = status.get("currentAction", "")

        if action == "Recording in progress":
            logger.info(f"  ⏸  Recording in progress — skipping {file_name}")
            interrupted = True
            break
        elif action == "Skipping":
            logger.info(f"  ⏭  Already exists: {file_name}")
            skipped = True
        elif action == "Downloading":
            progress = status.get("progress", 0)
            total    = status.get("total", 0)
            if total > 0:
                pct = min(int((progress / total) * 100), 100)
                bar = ("█" * (pct // 5)).ljust(20)
                print(
                    f"\r  ⬇  [{bar}] {pct}% {file_name}",
                    end="",
                    flush=True,
                )
        elif action == "Converting":
            print()  # newline after progress bar
            saw_converting = True
            logger.info(f"  🔄  Converting: {file_name}")

    if interrupted:
        return None

    if skipped or saw_converting:
        return local_path

    logger.warning(f"  ⚠️  No completion signal for {file_name}")
    return None


# ── Camera poll ───────────────────────────────────────────
async def poll_camera(
    camera: dict,
    config: dict,
    state: dict,
    s3_client,
    tmp_dir: str,
) -> dict:
    name     = camera["name"]
    ip       = camera["ip"]
    user     = camera["user"]
    password = camera["password"]
    bucket   = config["aws"]["bucket"]

    logger.info(f"📷  Polling {name} ({ip})")

    # Connect in a thread executor — Tapo() runs its own internal event loop
    # which clashes with the outer asyncio loop if called directly from async context
    def connect():
        tapo = Tapo(ip, user, password, password)
        time_correction = tapo.getTimeCorrection()
        return tapo, time_correction

    try:
        loop = asyncio.get_event_loop()
        tapo, time_correction = await loop.run_in_executor(None, connect)
    except Exception as e:
        logger.error(f"  ❌  Connection failed for {name}: {e}")
        return state

    # Determine date range to check — today + yesterday to catch midnight boundary
    now       = datetime.now(timezone.utc)
    dates     = [
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
            logger.error(f"  ❌  Could not get recordings for {name} on {date}: {e}")
            continue

        # Filter to only clips newer than last_seen
        new_clips = []
        for entry in recordings:
            for clip in entry.values():
                if clip["startTime"] > last_seen:
                    new_clips.append(clip)

        if not new_clips:
            logger.info(f"  ✅  No new clips for {name} on {date}")
            continue

        logger.info(f"  📋  {len(new_clips)} new clip(s) for {name} on {date}")

        for clip in new_clips:
            local_path = await download_clip(
                tapo, clip, time_correction, camera_tmp, name
            )

            if local_path and os.path.exists(local_path):
                success = upload_to_s3(s3_client, local_path, bucket, name, date)

                if success:
                    os.remove(local_path)
                    logger.info(f"  🗑️  Deleted local: {os.path.basename(local_path)}")
                    if clip["startTime"] > new_last_seen:
                        new_last_seen = clip["startTime"]
                else:
                    logger.warning(
                        f"  ⚠️  Upload failed — keeping local file for retry next run"
                    )
            else:
                logger.warning(f"  ⚠️  Download failed or skipped for clip at {clip['startTime']}")

    # Update state only if we made progress
    if new_last_seen > last_seen:
        if name not in state:
            state[name] = {}
        state[name]["last_start_time"] = new_last_seen
        state[name]["last_poll"] = int(time.time())

    return state


# ── Main loop ─────────────────────────────────────────────
async def run_poll_cycle(config: dict, state: dict, s3_client) -> dict:
    """Run one full poll cycle across all cameras. Returns updated state."""
    tmp_dir = os.path.join(os.path.dirname(__file__), "tapo_clips")

    for camera in config["cameras"]:
        try:
            state = await poll_camera(camera, config, state, s3_client, tmp_dir)
        except Exception as e:
            logger.error(f"Unexpected error polling {camera['name']}: {e}", exc_info=True)

    return state


def main():
    config     = load_config(args.config)
    state_file = config["poller"]["state_file"]
    interval   = config["poller"]["interval_seconds"]

    s3_client = make_s3_client(
        config["aws"]["profile"],
        config["aws"]["region"],
    )

    logger.info("🚀  Tapo poller starting")
    logger.info(f"   Cameras : {[c['name'] for c in config['cameras']]}")
    logger.info(f"   Interval: {interval}s")
    logger.info(f"   State   : {state_file}")
    logger.info(f"   Bucket  : {config['aws']['bucket']}")

    while True:
        state = load_state(state_file)

        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)

        try:
            state = loop.run_until_complete(run_poll_cycle(config, state, s3_client))
        except Exception as e:
            logger.error(f"Poll cycle failed: {e}", exc_info=True)
        finally:
            loop.close()

        save_state(state_file, state)
        logger.info(f"💤  Sleeping {interval}s until next poll...")
        time.sleep(interval)


if __name__ == "__main__":
    main()