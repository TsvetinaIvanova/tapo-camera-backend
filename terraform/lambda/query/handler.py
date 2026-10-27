"""
tapo-clip-query Lambda handler

GET /clips?date=YYYYMMDD[&camera=camera_id]

Returns a list of clip metadata records for the given date,
optionally filtered by camera. Each clip includes presigned
S3 URLs for both the video and thumbnail.

Query patterns:
  - date only     → uses date-start_time-index GSI (all cameras)
  - date + camera → uses primary key (single camera, most efficient)

The same code also runs as tapo-clip-query-demo behind the keyless
GET /demo/clips route, with CAMERA_SCOPE set. Then every query is pinned
to that one camera (the camera parameter is ignored), date is optional
(without it: the newest DEMO_LIMIT clips), and no row or URL outside that
camera is ever returned. The demo function's IAM role is pinned to the
same camera's rows and S3 prefixes, so a bug here fails closed.
"""

import json
import logging
import os
from decimal import Decimal

import boto3
from boto3.dynamodb.conditions import Key
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

dynamodb = boto3.resource("dynamodb")
s3_client = boto3.client("s3")

TABLE_NAME = os.environ["DYNAMODB_TABLE"]
S3_BUCKET = os.environ["S3_BUCKET"]
URL_EXPIRY = int(os.environ.get("PRESIGNED_URL_EXPIRY", "3600"))
CAMERA_SCOPE = os.environ.get("CAMERA_SCOPE") or None
SCOPE_KEY_ROOT = os.environ.get("SCOPE_KEY_ROOT", "")  # e.g. "demo/" for the demo camera
DEMO_LIMIT = 50

table = dynamodb.Table(TABLE_NAME)


def decimal_to_python(obj):
    """DynamoDB returns Decimals — convert to int/float for JSON serialisation."""
    if isinstance(obj, Decimal):
        return int(obj) if obj % 1 == 0 else float(obj)
    raise TypeError(f"Object of type {type(obj)} is not JSON serialisable")


def make_presigned_url(s3_key: str) -> str | None:
    """Generate a presigned GET URL valid for URL_EXPIRY seconds."""
    if not s3_key:
        return None
    try:
        return s3_client.generate_presigned_url(
            "get_object",
            Params={"Bucket": S3_BUCKET, "Key": s3_key},
            ExpiresIn=URL_EXPIRY,
        )
    except ClientError as e:
        logger.warning(f"Could not generate presigned URL for {s3_key}: {e}")
        return None


def query_by_date_and_camera(date: str, camera_id: str) -> list:
    """Primary key query — most efficient, used when camera is specified."""
    from boto3.dynamodb.conditions import Key as DKey
    from datetime import datetime, timezone

    # Convert date to Unix timestamp range
    dt = datetime.strptime(date, "%Y%m%d").replace(tzinfo=timezone.utc)
    start = int(dt.timestamp())
    end = start + 86400 - 1

    response = table.query(
        KeyConditionExpression=(
            DKey("camera_id").eq(camera_id) & DKey("start_time").between(start, end)
        ),
        ScanIndexForward=False,  # most recent first
    )
    return response.get("Items", [])


def query_latest(camera_id: str, limit: int) -> list:
    """Newest clips for one camera, any date (demo route without a date)."""
    response = table.query(
        KeyConditionExpression=Key("camera_id").eq(camera_id),
        ScanIndexForward=False,  # most recent first
        Limit=limit,
    )
    return response.get("Items", [])


def query_by_date(date: str) -> list:
    """GSI query — all cameras for a given date."""
    response = table.query(
        IndexName="date-start_time-index",
        KeyConditionExpression=Key("date").eq(date),
        ScanIndexForward=False,  # most recent first
    )
    return response.get("Items", [])


def in_scope(s3_key: str | None) -> bool:
    """Unscoped: any key. Scoped: only keys under the scoped camera's prefixes."""
    if not CAMERA_SCOPE or not s3_key:
        return True
    return s3_key.startswith((
        f"{SCOPE_KEY_ROOT}clips/{CAMERA_SCOPE}/",
        f"{SCOPE_KEY_ROOT}thumbnails/{CAMERA_SCOPE}/",
    ))


def enrich_with_urls(items: list) -> list:
    """Add presigned video and thumbnail URLs to each item."""
    enriched = []
    for item in items:
        if CAMERA_SCOPE and not (
            item.get("camera_id") == CAMERA_SCOPE
            and in_scope(item.get("s3_key"))
            and in_scope(item.get("thumbnail_s3_key"))
        ):
            logger.warning("Dropped an out-of-scope row from a scoped query")
            continue
        item["video_url"] = make_presigned_url(item.get("s3_key"))
        item["thumbnail_url"] = make_presigned_url(item.get("thumbnail_s3_key"))
        enriched.append(item)
    return enriched


def response(status_code: int, body: dict) -> dict:
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            # "Access-Control-Allow-Origin": "*",
        },
        "body": json.dumps(body, default=decimal_to_python),
    }


def lambda_handler(event: dict, context) -> dict:
    # Log only the query parameters: the full event carries the request
    # headers, and with them the x-api-key secret.
    params = event.get("queryStringParameters") or {}
    logger.info(f"Query parameters: {json.dumps(params)}")
    date = params.get("date")
    camera_id = CAMERA_SCOPE or params.get("camera")

    # Validate date (optional on the scoped demo route)
    if not date and not CAMERA_SCOPE:
        return response(400, {"error": "date parameter is required (YYYYMMDD)"})

    try:
        from datetime import datetime

        if date:
            datetime.strptime(date, "%Y%m%d")
    except ValueError:
        return response(400, {"error": "date must be in YYYYMMDD format"})

    try:
        if not date:
            items = query_latest(camera_id, DEMO_LIMIT)
            logger.info(f"Query: latest camera={camera_id} → {len(items)} items")
        elif camera_id:
            items = query_by_date_and_camera(date, camera_id)
            logger.info(f"Query: date={date} camera={camera_id} → {len(items)} items")
        else:
            items = query_by_date(date)
            logger.info(f"Query: date={date} all cameras → {len(items)} items")

        items = enrich_with_urls(items)

        return response(
            200,
            {
                "date": date,
                "count": len(items),
                "clips": items,
            },
        )

    except Exception as e:
        logger.error(f"Query failed: {e}", exc_info=True)
        return response(500, {"error": "Internal server error"})
