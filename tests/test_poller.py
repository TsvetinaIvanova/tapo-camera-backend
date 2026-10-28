"""
Tests for the poller's pause logic: the SSM override and battery auto-pause.

pytapo isn't a test dependency (and must never reach a real camera here), so
it is replaced with a stub module before poller.py is imported. Tapo itself
is swapped for a fake per test.
"""

import asyncio
import importlib.util
import json
import pathlib
import sys
import types
from datetime import datetime, timedelta, timezone

import boto3
import pytest
from botocore.exceptions import ClientError

POLLER_PATH = pathlib.Path(__file__).resolve().parents[1] / "poller" / "poller.py"
CAMERA = "c660_street"
PARAMETER = f"/tapo/poller/override/{CAMERA}"
AUTO_PAUSE = {"pause_below_percent": 35, "resume_above_percent": 55, "probe_interval_seconds": 10800}


@pytest.fixture(scope="module")
def poller():
    stubs = {
        "pytapo": types.ModuleType("pytapo"),
        "pytapo.media_stream": types.ModuleType("pytapo.media_stream"),
        "pytapo.media_stream.downloader": types.ModuleType("pytapo.media_stream.downloader"),
    }
    stubs["pytapo"].Tapo = None
    stubs["pytapo.media_stream.downloader"].Downloader = None
    saved = {name: sys.modules.get(name) for name in stubs}
    sys.modules.update(stubs)
    try:
        spec = importlib.util.spec_from_file_location("poller", POLLER_PATH)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    finally:
        for name, original in saved.items():
            if original is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = original
    return module


def override_value(mode="pause", hours=2):
    until = datetime.now(timezone.utc) + timedelta(hours=hours)
    return json.dumps({"mode": mode, "until": until.strftime("%Y-%m-%dT%H:%M:%SZ"), "set_by": "tester"})


def battery_camera(**extra):
    return {"name": CAMERA, "ip": "192.0.2.1", "user": "u", "password": "p", "battery_powered": True, **extra}


# ── parse_override ───────────────────────────────────────

def test_parse_override_reads_mode_and_utc_until(poller):
    override = poller.parse_override('{"mode": "pause", "until": "2026-10-29T12:00:00Z", "set_by": "me"}', CAMERA)
    assert override == {
        "mode": "pause",
        "until": datetime(2026, 10, 29, 12, tzinfo=timezone.utc),
        "set_by": "me",
    }


@pytest.mark.parametrize("value", [
    "not json",
    '{"until": "2026-10-29T12:00:00Z"}',
    '{"mode": "pause"}',
    '{"mode": "stop", "until": "2026-10-29T12:00:00Z"}',
    '{"mode": "pause", "until": "2026-10-29T12:00:00"}',  # no timezone
    '{"mode": "pause", "until": "tomorrow"}',
    '["pause"]',
])
def test_parse_override_ignores_malformed_values(poller, value):
    assert poller.parse_override(value, CAMERA) is None


# ── read_override ────────────────────────────────────────

def test_no_parameter_means_no_override(poller, aws):
    assert poller.read_override(boto3.client("ssm"), CAMERA, {}) is None


def test_active_override_is_returned(poller, aws):
    ssm = boto3.client("ssm")
    ssm.put_parameter(Name=PARAMETER, Type="String", Value=override_value("pause"))
    assert poller.read_override(ssm, CAMERA, {})["mode"] == "pause"


def test_expired_override_is_ignored(poller, aws):
    ssm = boto3.client("ssm")
    ssm.put_parameter(Name=PARAMETER, Type="String", Value=override_value("pause", hours=-1))
    assert poller.read_override(ssm, CAMERA, {}) is None


def test_deleted_parameter_clears_the_override(poller, aws):
    ssm = boto3.client("ssm")
    cache = {}
    ssm.put_parameter(Name=PARAMETER, Type="String", Value=override_value("pause"))
    assert poller.read_override(ssm, CAMERA, cache) is not None
    ssm.delete_parameter(Name=PARAMETER)
    assert poller.read_override(ssm, CAMERA, cache) is None


class FailingSSM:
    def __init__(self, error):
        self.error = error

    def get_parameter(self, **kwargs):
        raise self.error


@pytest.mark.parametrize("error", [
    ClientError({"Error": {"Code": "AccessDeniedException"}}, "GetParameter"),
    TimeoutError("connect timeout"),
])
def test_ssm_failure_keeps_the_last_known_override(poller, aws, error):
    ssm = boto3.client("ssm")
    cache = {}
    ssm.put_parameter(Name=PARAMETER, Type="String", Value=override_value("pause"))
    poller.read_override(ssm, CAMERA, cache)
    assert poller.read_override(FailingSSM(error), CAMERA, cache)["mode"] == "pause"


def test_ssm_failure_without_a_last_value_means_normal_polling(poller):
    error = ClientError({"Error": {"Code": "ThrottlingException"}}, "GetParameter")
    assert poller.read_override(FailingSSM(error), CAMERA, {}) is None


def test_kept_override_still_expires(poller):
    cache = {"override": {"mode": "pause", "until": datetime.now(timezone.utc) - timedelta(seconds=1)}}
    error = ClientError({"Error": {"Code": "ThrottlingException"}}, "GetParameter")
    assert poller.read_override(FailingSSM(error), CAMERA, cache) is None


# ── auto-pause thresholds ────────────────────────────────

def test_auto_pause_has_a_gap_between_pause_and_resume(poller):
    camera = battery_camera(auto_pause=AUTO_PAUSE)
    cam_state = {}
    readings = [52, 36, 34, 40, 55, 54, 56, 40]
    decisions = [poller.update_auto_pause(camera, cam_state, p, CAMERA) for p in readings]
    assert decisions == [False, False, True, True, True, True, False, False]


def test_failed_battery_read_keeps_the_previous_decision(poller):
    camera = battery_camera(auto_pause=AUTO_PAUSE)
    assert poller.update_auto_pause(camera, {"auto_paused": True}, None, CAMERA) is True
    assert poller.update_auto_pause(camera, {"auto_paused": False}, None, CAMERA) is False


def test_without_auto_pause_settings_a_camera_is_never_paused(poller):
    cam_state = {"auto_paused": True}
    assert poller.update_auto_pause(battery_camera(), cam_state, 5, CAMERA) is False
    assert "auto_paused" not in cam_state


def test_battery_check_is_due_after_the_probe_interval(poller):
    camera = battery_camera(auto_pause=AUTO_PAUSE)
    cam_state = {"auto_paused": True, "last_battery_check": 1000}
    assert poller.seconds_until_battery_check(camera, cam_state, now=1000 + 3600) == 7200
    assert poller.seconds_until_battery_check(camera, cam_state, now=1000 + 10800) == 0
    assert poller.seconds_until_battery_check(camera, {"auto_paused": False}, now=0) == 0


@pytest.mark.parametrize("camera", [
    {"name": CAMERA, "auto_pause": AUTO_PAUSE},  # not battery_powered
    battery_camera(auto_pause={"pause_below_percent": 55, "resume_above_percent": 35}),
    battery_camera(auto_pause={"pause_below_percent": 35}),
    battery_camera(auto_pause={**AUTO_PAUSE, "probe_interval_seconds": 0}),
])
def test_invalid_auto_pause_settings_disable_auto_pause(poller, camera):
    poller.validate_auto_pause(camera)
    assert "auto_pause" not in camera


def test_valid_auto_pause_settings_are_kept(poller):
    camera = battery_camera(auto_pause=AUTO_PAUSE)
    poller.validate_auto_pause(camera)
    assert camera["auto_pause"] == AUTO_PAUSE


# ── poll_camera while auto-paused ────────────────────────

class FakeTapo:
    battery_percent = 30
    recordings_calls = 0

    def __init__(self, *args):
        pass

    def getTimeCorrection(self):
        return 0

    def getBatteryStatus(self):
        return {"battery": {"status": {"battery_percent": FakeTapo.battery_percent}}}

    def getRecordings(self, date):
        FakeTapo.recordings_calls += 1
        return []


class RecordingCloudWatch:
    def __init__(self):
        self.metrics = []

    def put_metric_data(self, Namespace, MetricData):
        self.metrics += [m["MetricName"] for m in MetricData]


@pytest.fixture
def fake_tapo(poller, monkeypatch):
    monkeypatch.setattr(poller, "Tapo", FakeTapo)
    FakeTapo.recordings_calls = 0
    return FakeTapo


def run_poll(poller, tmp_path, state, force_poll=False, cloudwatch=None):
    config = {"aws": {"bucket": "unused"}}
    camera = battery_camera(auto_pause=AUTO_PAUSE)
    return asyncio.run(poller.poll_camera(
        camera, config, state, None, str(tmp_path), cloudwatch_client=cloudwatch, force_poll=force_poll,
    ))


def test_low_battery_pauses_before_listing_recordings(poller, fake_tapo, tmp_path):
    fake_tapo.battery_percent = 30
    cloudwatch = RecordingCloudWatch()
    state = run_poll(poller, tmp_path, {}, cloudwatch=cloudwatch)
    assert state[CAMERA]["auto_paused"] is True
    assert state[CAMERA]["last_battery_check"] > 0
    assert fake_tapo.recordings_calls == 0
    assert cloudwatch.metrics == ["PollCycleCompleted", "BatteryPercent", "PollCyclePaused"]


def test_recharged_battery_resumes_downloads_in_the_same_session(poller, fake_tapo, tmp_path):
    fake_tapo.battery_percent = 60
    state = run_poll(poller, tmp_path, {CAMERA: {"auto_paused": True}})
    assert state[CAMERA]["auto_paused"] is False
    assert fake_tapo.recordings_calls == 2  # yesterday and today


def test_poll_override_downloads_while_auto_paused(poller, fake_tapo, tmp_path):
    fake_tapo.battery_percent = 30
    state = run_poll(poller, tmp_path, {}, force_poll=True)
    assert state[CAMERA]["auto_paused"] is True
    assert fake_tapo.recordings_calls == 2
