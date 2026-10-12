"""
tapo-clip-processor Lambda handler

Triggered by S3 PutObject on clips/*.mp4
For each clip:
  1. Parses camera_id, start_time, end_time from the S3 key
  2. Generates a JPEG thumbnail via ffmpeg
  3. Uploads thumbnail to thumbnails/{camera}/{date}/{name}.jpg
  4. Writes full metadata record to DynamoDB

Expected S3 key format:
  clips/{camera_id}/{YYYYMMDD}/{camera_id}_{HHMMSS}_{duration}s.mp4
  e.g. clips/c225_front/20260617/c225_front_081430_67s.mp4
"""

import logging
import os
import subprocess
import time
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client("s3")
dynamodb = boto3.resource("dynamodb")

TABLE_NAME = os.environ["DYNAMODB_TABLE"]
S3_BUCKET = os.environ["S3_BUCKET"]
THUMBNAIL_PREFIX = os.environ.get("THUMBNAIL_PREFIX", "thumbnails")
TTL_DAYS = int(os.environ.get("TTL_DAYS", "365"))

table = dynamodb.Table(TABLE_NAME)

FFMPEG_PATH = "/opt/bin/ffmpeg"   # built into the container image (see Dockerfile)
# Thumbnails only need to fill a frontend card; full camera resolution
# (up to 3840px on the C660) made them ~1.3 MB each.
THUMBNAIL_MAX_WIDTH = 1280
TMP_DIR = "/tmp"


def parse_s3_key(s3_key: str) -> dict:
    """
    Parse metadata from the S3 key.

    Expected format:
      clips/{camera_id}/{date}/{filename}.mp4
      filename: {camera_id}_{HHMMSS}_{duration}s

    Returns dict with camera_id, date, start_time_str, duration_s,
    or raises ValueError if the key doesn't match expected format.
    """
    # clips/c225_front/20260617/c225_front_081430_67s.mp4
    parts = s3_key.split("/")
    if len(parts) != 4 or parts[0] != "clips":
        raise ValueError(f"Unexpected S3 key format: {s3_key}")

    _, camera_id, date_str, filename = parts
    stem = filename.replace(".mp4", "")

    # stem: c225_front_081430_67s
    # Split from the right to isolate duration, then time, then camera name
    stem_parts = stem.rsplit("_", 2)
    if len(stem_parts) != 3:
        raise ValueError(f"Unexpected filename format: {filename}")

    _, time_str, duration_part = stem_parts
    duration_s = int(duration_part.replace("s", ""))

    # Reconstruct start datetime from date + time_str
    dt = datetime.strptime(f"{date_str}{time_str}", "%Y%m%d%H%M%S")
    dt = dt.replace(tzinfo=timezone.utc)
    start_time = int(dt.timestamp())
    end_time = start_time + duration_s

    return {
        "camera_id":  camera_id,
        "date":       date_str,
        "start_time": start_time,
        "end_time":   end_time,
        "duration_s": duration_s,
        "filename":   filename,
    }


def download_clip(bucket: str, s3_key: str, local_path: str) -> int:
    """Download clip from S3, return file size in bytes."""
    logger.info(f"Downloading s3://{bucket}/{s3_key} to {local_path}")
    s3.download_file(bucket, s3_key, local_path)
    return os.path.getsize(local_path)


def generate_thumbnail(clip_path: str, thumbnail_path: str) -> bool:
    """
    Extract a single frame at 1 second into the clip as a JPEG, scaled
    down to THUMBNAIL_MAX_WIDTH (never up), keeping the aspect ratio.
    Falls back to frame 0 if the clip is shorter than 1 second.
    Returns True on success.
    """
    cmd = [
        FFMPEG_PATH,
        "-ss", "1",           # seek to 1 second
        "-i", clip_path,
        "-vframes", "1",      # extract exactly one frame
        # Width capped, never upscaled; -2 keeps the aspect ratio with an even height
        "-vf", f"scale='min({THUMBNAIL_MAX_WIDTH},iw)':-2",
        "-q:v", "12",          # JPEG quality (1=best, 31=worst)
        "-y",                 # overwrite if exists
        thumbnail_path,
    ]

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=30,
        )
        if result.returncode != 0:
            # Clip may be shorter than 1s — retry from frame 0
            logger.warning(
                f"ffmpeg at 1s failed, retrying from frame 0: {result.stderr}"
            )
            cmd[2] = "0"
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)

        if result.returncode == 0:
            logger.info(f"Thumbnail generated: {thumbnail_path}")
            return True
        else:
            logger.error(f"ffmpeg failed: {result.stderr}")
            return False

    except subprocess.TimeoutExpired:
        logger.error("ffmpeg timed out")
        return False


def upload_thumbnail(local_path: str, bucket: str, s3_key: str) -> str:
    """Upload thumbnail to S3, return the S3 key."""
    logger.info(f"Uploading thumbnail to s3://{bucket}/{s3_key}")
    s3.upload_file(
        local_path,
        bucket,
        s3_key,
        ExtraArgs={"ContentType": "image/jpeg"},
    )
    return s3_key


def write_metadata(
    parsed: dict,
    s3_key: str,
    file_size_bytes: int,
    thumbnail_s3_key: str | None,
    processing_status: str,
) -> None:
    """Write clip metadata record to DynamoDB."""
    ttl = int(time.time()) + (TTL_DAYS * 86400)

    item = {
        "camera_id":         parsed["camera_id"],
        "start_time":        parsed["start_time"],
        "date":              parsed["date"],
        "end_time":          parsed["end_time"],
        "duration_s":        parsed["duration_s"],
        "s3_key":            s3_key,
        "s3_bucket":         S3_BUCKET,
        "file_size_bytes":   file_size_bytes,
        "uploaded_at":       int(time.time()),
        "processing_status": processing_status,
        "has_person":        "unknown",   # populated later by Rekognition pass
        "ttl":               ttl,
    }

    if thumbnail_s3_key:
        item["thumbnail_s3_key"] = thumbnail_s3_key

    table.put_item(Item=item)
    logger.info(f"Metadata written for {parsed['camera_id']} at {parsed['start_time']}")


def cleanup(*paths: str) -> None:
    """Remove temporary files from /tmp."""
    for path in paths:
        try:
            if os.path.exists(path):
                os.remove(path)
        except OSError as e:
            logger.warning(f"Could not clean up {path}: {e}")


def process_record(record: dict) -> None:
    """Process a single S3 event record."""
    bucket = record["s3"]["bucket"]["name"]
    s3_key = record["s3"]["object"]["key"]
    s3_key = s3_key.replace("+", " ")   # S3 URL-encodes spaces as +

    logger.info(f"Processing: s3://{bucket}/{s3_key}")

    # Parse metadata from key
    try:
        parsed = parse_s3_key(s3_key)
    except ValueError as e:
        logger.error(f"Skipping — could not parse key: {e}")
        return

    clip_name = parsed["filename"].replace(".mp4", "")
    local_clip = os.path.join(TMP_DIR, parsed["filename"])
    local_thumb = os.path.join(TMP_DIR, f"{clip_name}.jpg")
    thumbnail_key = (
        f"{THUMBNAIL_PREFIX}/{parsed['camera_id']}/{parsed['date']}/{clip_name}.jpg"
    )

    try:
        # 1. Download clip
        file_size = download_clip(bucket, s3_key, local_clip)

        # 2. Generate thumbnail
        thumb_ok = generate_thumbnail(local_clip, local_thumb)

        # 3. Upload thumbnail
        thumbnail_s3_key = None
        if thumb_ok:
            try:
                thumbnail_s3_key = upload_thumbnail(local_thumb, bucket, thumbnail_key)
            except ClientError as e:
                logger.error(f"Thumbnail upload failed: {e}")

        # 4. Write metadata
        status = "complete" if thumb_ok else "thumbnail_failed"
        write_metadata(parsed, s3_key, file_size, thumbnail_s3_key, status)

    except Exception as e:
        logger.error(f"Processing failed for {s3_key}: {e}", exc_info=True)
        # Still try to write a failed metadata record so the clip isn't invisible
        try:
            write_metadata(parsed, s3_key, 0, None, "failed")
        except Exception as inner:
            logger.error(f"Could not write failure metadata: {inner}")
    finally:
        cleanup(local_clip, local_thumb)


def lambda_handler(event: dict, context) -> dict:
    """Entry point — handles batched S3 event records."""
    logger.info(f"Received event with {len(event.get('Records', []))} record(s)")

    for record in event.get("Records", []):
        process_record(record)

    return {"statusCode": 200, "body": "ok"}
