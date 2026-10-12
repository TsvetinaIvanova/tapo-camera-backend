#!/usr/bin/env python3
"""
Re-run the clip processor for clips it never finished.

A clip counts as processed when DynamoDB has its (camera_id, start_time) row
with processing_status == "complete". Anything else (no row, "failed",
"thumbnail_failed") is a candidate, e.g. clips whose S3 event was dropped
while the function was being replaced.

Candidates are re-processed by invoking the processor asynchronously with a
synthetic S3 ObjectCreated event, the same payload S3 sends, so the real
code path runs. Reprocessing is idempotent: the thumbnail and the row are
overwritten.

Dry run by default; pass --invoke to actually invoke.

  # what would be reprocessed since yesterday
  scripts/backfill_processor.py --since 20261009
  # do it
  scripts/backfill_processor.py --since 20261009 --invoke
  # verification: reprocess one specific clip, even if already complete
  scripts/backfill_processor.py --key clips/c325_back/20261008/c325_back_112948_64s.mp4 --invoke

Uses the default AWS credential chain (set AWS_PROFILE as needed).
"""
import argparse
import json
import os
import sys

import boto3

REGION = "eu-central-1"
BUCKET = "vladaya-tapo-cameras"
TABLE = "tapo-camera-clips"
FUNCTION = "tapo-clip-processor"

# Reuse the handler's own key parsing so the DynamoDB key can't drift from
# what the processor writes. The handler reads these at import time.
os.environ.setdefault("DYNAMODB_TABLE", TABLE)
os.environ.setdefault("S3_BUCKET", BUCKET)
os.environ.setdefault("AWS_DEFAULT_REGION", REGION)
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "terraform", "lambda", "processor"))
from handler import parse_s3_key  # noqa: E402


def list_clip_keys(s3, camera, since, until):
    prefix = f"clips/{camera}/" if camera else "clips/"
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=BUCKET, Prefix=prefix):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            parts = key.split("/")
            if len(parts) != 4 or not key.endswith(".mp4"):
                continue
            date = parts[2]
            if since and date < since:
                continue
            if until and date > until:
                continue
            yield key


def processing_status(table, key):
    parsed = parse_s3_key(key)
    item = table.get_item(
        Key={"camera_id": parsed["camera_id"], "start_time": parsed["start_time"]},
        ProjectionExpression="processing_status",
    ).get("Item")
    return item["processing_status"] if item else None


def s3_event(key):
    return {"Records": [{
        "eventSource": "aws:s3",
        "eventName": "ObjectCreated:Put",
        "s3": {"bucket": {"name": BUCKET}, "object": {"key": key}},
    }]}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--since", help="first date to include, YYYYMMDD")
    ap.add_argument("--until", help="last date to include, YYYYMMDD")
    ap.add_argument("--camera", help="only this camera_id")
    ap.add_argument("--key", help="reprocess exactly this clip key, regardless of status")
    ap.add_argument("--invoke", action="store_true", help="invoke the processor (default: dry run)")
    args = ap.parse_args()

    if not (args.key or args.since):
        ap.error("give --since (to bound the scan) or --key")

    s3 = boto3.client("s3", region_name=REGION)
    table = boto3.resource("dynamodb", region_name=REGION).Table(TABLE)
    lam = boto3.client("lambda", region_name=REGION)

    if args.key:
        candidates = [(args.key, processing_status(table, args.key))]
    else:
        candidates = []
        for key in list_clip_keys(s3, args.camera, args.since, args.until):
            status = processing_status(table, key)
            if status != "complete":
                candidates.append((key, status))

    for key, status in candidates:
        print(f"{'invoke' if args.invoke else 'would invoke'}: {key} (status: {status or 'no row'})")
        if args.invoke:
            lam.invoke(FunctionName=FUNCTION, InvocationType="Event", Payload=json.dumps(s3_event(key)))

    print(f"{len(candidates)} clip(s) {'submitted' if args.invoke else 'to reprocess (dry run)'}")


if __name__ == "__main__":
    main()
