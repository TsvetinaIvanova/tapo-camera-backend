"""Processor Lambda: S3 key parsing and the download/thumbnail/metadata flow."""

import os
import pathlib
import subprocess

import pytest
from botocore.exceptions import ClientError

from conftest import BUCKET, TABLE, load_handler

CLIP_KEY = "clips/c325_back/20261008/c325_back_112948_64s.mp4"
THUMB_KEY = "thumbnails/c325_back/20261008/c325_back_112948_64s.jpg"
CLIP_START = 1791458988  # 2026-10-08 11:29:48 UTC
CLIP_BODY = b"not really an mp4" * 100


class FakeFfmpeg:
    """Stands in for subprocess.run: one return code (or exception) per call.

    A zero return code writes the output file, like ffmpeg would.
    """

    def __init__(self, *outcomes):
        self.outcomes = list(outcomes)
        self.calls = []

    def __call__(self, cmd, **kwargs):
        self.calls.append(list(cmd))  # copy: the handler mutates cmd for its fallback
        outcome = self.outcomes.pop(0)
        if isinstance(outcome, Exception):
            raise outcome
        if outcome == 0:
            pathlib.Path(cmd[-1]).write_bytes(b"\xff\xd8 fake jpeg")
        return subprocess.CompletedProcess(cmd, outcome, stdout="", stderr="" if outcome == 0 else "ffmpeg error")


@pytest.fixture
def handler(bucket, table, monkeypatch, tmp_path):
    monkeypatch.setenv("DYNAMODB_TABLE", TABLE)
    monkeypatch.setenv("S3_BUCKET", BUCKET)
    monkeypatch.setenv("TTL_DAYS", "30")
    module = load_handler("processor")
    monkeypatch.setattr(module, "TMP_DIR", str(tmp_path))
    return module


@pytest.fixture
def ffmpeg(handler, monkeypatch):
    def install(*outcomes):
        fake = FakeFfmpeg(*outcomes)
        monkeypatch.setattr(handler.subprocess, "run", fake)
        return fake
    return install


def s3_event(*keys):
    return {"Records": [{"s3": {"bucket": {"name": BUCKET}, "object": {"key": key}}} for key in keys]}


def get_row(table, camera_id="c325_back", start_time=CLIP_START):
    return table.get_item(Key={"camera_id": camera_id, "start_time": start_time}).get("Item")


# ── parse_s3_key ────────────────────────────────────────────

def test_parse_s3_key(handler):
    assert handler.parse_s3_key(CLIP_KEY) == {
        "camera_id":  "c325_back",
        "date":       "20261008",
        "start_time": CLIP_START,
        "end_time":   CLIP_START + 64,
        "duration_s": 64,
        "filename":   "c325_back_112948_64s.mp4",
    }


@pytest.mark.parametrize("key", [
    "thumbnails/c325_back/20261008/c325_back_112948_64s.jpg",  # not under clips/
    "clips/c325_back/c325_back_112948_64s.mp4",                # no date folder
    "clips/c325_back/20261008/extra/c325_back_112948_64s.mp4",  # too deep
    "clips/c325_back/20261008/clip.mp4",                       # no time/duration in the name
    "clips/c325_back/20261008/c325_back_112948_longs.mp4",     # duration is not a number
    "clips/c325_back/20261008/c325_back_256199_64s.mp4",       # impossible time
    "clips/c325_back/2026-10-08/c325_back_112948_64s.mp4",     # wrong date format
])
def test_parse_s3_key_rejects_unexpected_keys(handler, key):
    with pytest.raises(ValueError):
        handler.parse_s3_key(key)


# ── process_record / lambda_handler ─────────────────────────

def test_clip_gets_thumbnail_and_complete_row(handler, bucket, table, ffmpeg, tmp_path):
    bucket.put_object(Bucket=BUCKET, Key=CLIP_KEY, Body=CLIP_BODY)
    fake = ffmpeg(0)

    assert handler.lambda_handler(s3_event(CLIP_KEY), None) == {"statusCode": 200, "body": "ok"}

    thumbnail = bucket.get_object(Bucket=BUCKET, Key=THUMB_KEY)
    assert thumbnail["ContentType"] == "image/jpeg"

    row = get_row(table)
    assert row["processing_status"] == "complete"
    assert row["s3_key"] == CLIP_KEY
    assert row["s3_bucket"] == BUCKET
    assert row["thumbnail_s3_key"] == THUMB_KEY
    assert row["date"] == "20261008"
    assert row["end_time"] == CLIP_START + 64
    assert row["duration_s"] == 64
    assert row["file_size_bytes"] == len(CLIP_BODY)
    assert row["has_person"] == "unknown"
    assert row["ttl"] == row["uploaded_at"] + 30 * 86400

    assert len(fake.calls) == 1
    assert os.listdir(tmp_path) == [], "temporary clip and thumbnail must be removed"


def test_ffmpeg_command_seeks_to_1s_and_caps_width(handler, bucket, ffmpeg):
    bucket.put_object(Bucket=BUCKET, Key=CLIP_KEY, Body=CLIP_BODY)
    fake = ffmpeg(0)

    handler.lambda_handler(s3_event(CLIP_KEY), None)

    cmd = fake.calls[0]
    assert cmd[0] == handler.FFMPEG_PATH
    assert cmd[cmd.index("-ss") + 1] == "1"
    assert cmd[cmd.index("-vf") + 1] == f"scale='min({handler.THUMBNAIL_MAX_WIDTH},iw)':-2"
    assert cmd[cmd.index("-vframes") + 1] == "1"


def test_short_clip_falls_back_to_first_frame(handler, bucket, table, ffmpeg):
    bucket.put_object(Bucket=BUCKET, Key=CLIP_KEY, Body=CLIP_BODY)
    fake = ffmpeg(1, 0)

    handler.lambda_handler(s3_event(CLIP_KEY), None)

    first, second = fake.calls
    assert first[first.index("-ss") + 1] == "1"
    assert second[second.index("-ss") + 1] == "0"
    # Only the seek position may differ between the two attempts.
    assert [a for a, b in zip(first, second) if a != b] == ["1"]
    assert get_row(table)["processing_status"] == "complete"


@pytest.mark.parametrize("outcomes", [
    (1, 1),                                               # both attempts fail
    (subprocess.TimeoutExpired(cmd="ffmpeg", timeout=30),),  # ffmpeg hangs
])
def test_thumbnail_failure_still_writes_row(handler, bucket, table, ffmpeg, tmp_path, outcomes):
    bucket.put_object(Bucket=BUCKET, Key=CLIP_KEY, Body=CLIP_BODY)
    ffmpeg(*outcomes)

    handler.lambda_handler(s3_event(CLIP_KEY), None)

    row = get_row(table)
    assert row["processing_status"] == "thumbnail_failed"
    assert "thumbnail_s3_key" not in row
    assert row["file_size_bytes"] == len(CLIP_BODY)
    with pytest.raises(ClientError):
        bucket.head_object(Bucket=BUCKET, Key=THUMB_KEY)
    assert os.listdir(tmp_path) == []


def test_thumbnail_upload_failure_still_writes_row(handler, bucket, table, ffmpeg, monkeypatch):
    bucket.put_object(Bucket=BUCKET, Key=CLIP_KEY, Body=CLIP_BODY)
    ffmpeg(0)

    def denied(*args, **kwargs):
        raise ClientError({"Error": {"Code": "AccessDenied", "Message": "denied"}}, "PutObject")
    monkeypatch.setattr(handler, "upload_thumbnail", denied)

    handler.lambda_handler(s3_event(CLIP_KEY), None)

    row = get_row(table)
    assert row["processing_status"] == "complete"  # current behaviour: the status reflects ffmpeg, not the upload
    assert "thumbnail_s3_key" not in row


def test_missing_clip_writes_failed_row(handler, table, ffmpeg):
    fake = ffmpeg()

    assert handler.lambda_handler(s3_event(CLIP_KEY), None)["statusCode"] == 200

    row = get_row(table)
    assert row["processing_status"] == "failed"
    assert row["file_size_bytes"] == 0
    assert "thumbnail_s3_key" not in row
    assert fake.calls == []


def test_unparseable_key_is_skipped(handler, table, ffmpeg):
    fake = ffmpeg()

    assert handler.lambda_handler(s3_event("clips/readme.txt"), None)["statusCode"] == 200

    assert table.scan()["Items"] == []
    assert fake.calls == []


def test_every_record_in_a_batch_is_processed(handler, bucket, table, ffmpeg):
    other_key = "clips/c660_street/20261008/c660_street_112950_10s.mp4"
    for key in (CLIP_KEY, other_key):
        bucket.put_object(Bucket=BUCKET, Key=key, Body=CLIP_BODY)
    ffmpeg(0, 0)

    handler.lambda_handler(s3_event(CLIP_KEY, "clips/readme.txt", other_key), None)

    assert get_row(table)["processing_status"] == "complete"
    assert get_row(table, "c660_street", CLIP_START + 2)["processing_status"] == "complete"
    assert len(table.scan()["Items"]) == 2


def test_event_without_records(handler):
    assert handler.lambda_handler({}, None) == {"statusCode": 200, "body": "ok"}
