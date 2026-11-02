"""Tests for scripts/reset_clip_ttl.py."""
import importlib.util
import pathlib

import pytest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "scripts" / "reset_clip_ttl.py"
DAY = 86400
NOW = 2_000_000_000


@pytest.fixture
def script():
    spec = importlib.util.spec_from_file_location("reset_clip_ttl", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def put(table, camera, start, ttl=None):
    item = {"camera_id": camera, "start_time": start, "date": "20260101"}
    if ttl is not None:
        item["ttl"] = ttl
    table.put_item(Item=item)


def ttl_of(table, camera, start):
    return table.get_item(Key={"camera_id": camera, "start_time": start})["Item"].get("ttl")


def test_long_ttl_is_lowered_to_start_plus_days(script, table):
    start = NOW - 10 * DAY
    put(table, "c325_back", start, ttl=start + 365 * DAY)
    counts, expiring = script.reset(table, 60, True, NOW)
    assert ttl_of(table, "c325_back", start) == start + 60 * DAY
    assert counts["ttl lowered, still in the future"] == 1
    assert not expiring


def test_row_past_the_new_ttl_is_reported_as_deleted(script, table):
    start = NOW - 90 * DAY
    put(table, "c325_back", start, ttl=start + 365 * DAY)
    counts, expiring = script.reset(table, 60, True, NOW)
    assert ttl_of(table, "c325_back", start) == start + 60 * DAY
    assert counts["already past the new ttl"] == 1
    assert expiring == {"c325_back": 1}


def test_dry_run_writes_nothing(script, table):
    start = NOW - 90 * DAY
    put(table, "c325_back", start, ttl=start + 365 * DAY)
    counts, _ = script.reset(table, 60, False, NOW)
    assert ttl_of(table, "c325_back", start) == start + 365 * DAY
    assert counts["already past the new ttl"] == 1


def test_row_without_ttl_is_never_touched(script, table):
    put(table, "demo", NOW - 90 * DAY)
    counts, _ = script.reset(table, 60, True, NOW)
    assert ttl_of(table, "demo", NOW - 90 * DAY) is None
    assert counts["no ttl (kept)"] == 1


@pytest.mark.parametrize("lifetime_days", [59, 60, 62])
def test_ttl_at_or_near_the_target_is_left_alone(script, table, lifetime_days):
    start = NOW - 10 * DAY
    put(table, "c325_back", start, ttl=start + lifetime_days * DAY)
    counts, _ = script.reset(table, 60, True, NOW)
    assert ttl_of(table, "c325_back", start) == start + lifetime_days * DAY
    assert counts["already correct"] == 1


def test_row_deleted_after_the_scan_is_not_recreated(script, table):
    start = NOW - 90 * DAY
    assert script.set_ttl(table, {"camera_id": "c325_back", "start_time": start}, NOW) is False
    assert "Item" not in table.get_item(Key={"camera_id": "c325_back", "start_time": start})
