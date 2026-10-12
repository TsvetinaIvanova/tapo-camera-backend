"""Query Lambda: GET /clips?date=YYYYMMDD[&camera=camera_id]."""

import json
import logging
from decimal import Decimal

import pytest

from conftest import BUCKET, SECRET, TABLE, load_handler

DAY = 1791417600  # 2026-10-08 00:00:00 UTC


@pytest.fixture
def handler(bucket, table, monkeypatch):
    monkeypatch.setenv("DYNAMODB_TABLE", TABLE)
    monkeypatch.setenv("S3_BUCKET", BUCKET)
    monkeypatch.setenv("PRESIGNED_URL_EXPIRY", "900")
    return load_handler("query")


def put_clip(table, camera_id, start_time, date="20261008", thumbnail=True):
    item = {
        "camera_id": camera_id,
        "start_time": start_time,
        "date": date,
        "duration_s": 10,
        "s3_key": f"clips/{camera_id}/{date}/{camera_id}_{start_time}.mp4",
    }
    if thumbnail:
        item["thumbnail_s3_key"] = f"thumbnails/{camera_id}/{date}/{camera_id}_{start_time}.jpg"
    table.put_item(Item=item)


def get(handler, **params):
    result = handler.lambda_handler({"queryStringParameters": params or None}, None)
    return result["statusCode"], json.loads(result["body"])


@pytest.mark.parametrize("params, error", [
    ({}, "date parameter is required (YYYYMMDD)"),
    ({"camera": "c325_back"}, "date parameter is required (YYYYMMDD)"),
    ({"date": "2026-10-08"}, "date must be in YYYYMMDD format"),
    ({"date": "20261340"}, "date must be in YYYYMMDD format"),
])
def test_invalid_date_is_a_400(handler, params, error):
    assert get(handler, **params) == (400, {"error": error})


def test_date_returns_all_cameras_newest_first(handler, table):
    put_clip(table, "c325_back", DAY + 100)
    put_clip(table, "c660_street", DAY + 300)
    put_clip(table, "c325_back", DAY + 200)
    put_clip(table, "c325_back", DAY + 86400 + 5, date="20261009")  # another day

    status, body = get(handler, date="20261008")

    assert status == 200
    assert body["date"] == "20261008"
    assert body["count"] == 3
    assert [(c["camera_id"], c["start_time"]) for c in body["clips"]] == [
        ("c660_street", DAY + 300),
        ("c325_back", DAY + 200),
        ("c325_back", DAY + 100),
    ]


def test_camera_filter_returns_only_that_camera_and_day(handler, table):
    put_clip(table, "c325_back", DAY)                 # first second of the day
    put_clip(table, "c325_back", DAY + 86399)         # last second of the day
    put_clip(table, "c325_back", DAY - 1, date="20261007")
    put_clip(table, "c325_back", DAY + 86400, date="20261009")
    put_clip(table, "c660_street", DAY + 50)

    status, body = get(handler, date="20261008", camera="c325_back")

    assert status == 200
    assert [(c["camera_id"], c["start_time"]) for c in body["clips"]] == [
        ("c325_back", DAY + 86399),
        ("c325_back", DAY),
    ]


def test_no_clips_is_an_empty_200(handler):
    assert get(handler, date="20261008") == (200, {"date": "20261008", "count": 0, "clips": []})
    assert get(handler, date="20261008", camera="c325_back")[1]["count"] == 0


def test_clips_get_presigned_urls(handler, table):
    put_clip(table, "c325_back", DAY + 100)

    clip = get(handler, date="20261008")[1]["clips"][0]

    for field, key in (("video_url", clip["s3_key"]), ("thumbnail_url", clip["thumbnail_s3_key"])):
        assert clip[field].startswith(f"https://{BUCKET}.s3.")
        assert key in clip[field]
        assert "X-Amz-Expires=900" in clip[field]
        assert "X-Amz-Signature=" in clip[field]


def test_clip_without_thumbnail_has_null_thumbnail_url(handler, table):
    put_clip(table, "c325_back", DAY + 100, thumbnail=False)

    clip = get(handler, date="20261008")[1]["clips"][0]

    assert clip["thumbnail_url"] is None
    assert clip["video_url"]


def test_dynamodb_numbers_are_json_numbers(handler, table):
    put_clip(table, "c325_back", DAY + 100)

    clip = get(handler, date="20261008")[1]["clips"][0]

    assert clip["start_time"] == DAY + 100 and isinstance(clip["start_time"], int)
    assert handler.decimal_to_python(Decimal("1.5")) == 1.5
    with pytest.raises(TypeError):
        handler.decimal_to_python(object())


def test_response_is_json(handler):
    result = handler.lambda_handler({"queryStringParameters": {"date": "20261008"}}, None)
    assert result["headers"]["Content-Type"] == "application/json"


def test_dynamodb_error_is_a_500_without_details(handler, monkeypatch):
    def broken(date):
        raise RuntimeError("table arn and other internals")
    monkeypatch.setattr(handler, "query_by_date", broken)

    assert get(handler, date="20261008") == (500, {"error": "Internal server error"})


def test_api_key_is_not_logged(handler, caplog):
    event = {
        "headers": {"x-api-key": SECRET},
        "queryStringParameters": {"date": "20261008", "camera": "c325_back"},
    }
    with caplog.at_level(logging.INFO):
        handler.lambda_handler(event, None)

    assert SECRET not in caplog.text
    assert "x-api-key" not in caplog.text
    # The query itself is still logged, for debugging.
    assert "20261008" in caplog.text and "c325_back" in caplog.text
