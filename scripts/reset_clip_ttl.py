#!/usr/bin/env python3
"""
Bring existing clip rows in line with the current retention.

The processor sets a row's ttl once, when it processes the clip, so shortening
clips_ttl_days only affects new rows. Older rows keep their longer ttl and stay
listed long after S3 has expired their clip. This sets ttl to start_time + --days
on those rows.

A ttl that ends up in the past makes DynamoDB delete the row, usually within a
few days. That can't be undone. A ttl is only ever lowered, and rows within
SKEW_DAYS of the target are left alone: the processor counts from processing
time, so its rows sit slightly above the target. Rows with no ttl (demo footage
is kept until deleted by hand) are never touched.

Dry run by default; pass --apply to write.

  scripts/reset_clip_ttl.py
  scripts/reset_clip_ttl.py --apply

Uses the default AWS credential chain (set AWS_PROFILE as needed).
"""
import argparse
import collections
import time

import boto3
from botocore.exceptions import ClientError

REGION = "eu-central-1"
TABLE = "tapo-camera-clips"
DAY_SECONDS = 86400
SKEW_DAYS = 2


def scan_rows(table):
    kwargs = {
        "ProjectionExpression": "camera_id, start_time, #ttl",
        "ExpressionAttributeNames": {"#ttl": "ttl"},
    }
    while True:
        response = table.scan(**kwargs)
        yield from response["Items"]
        if "LastEvaluatedKey" not in response:
            return
        kwargs["ExclusiveStartKey"] = response["LastEvaluatedKey"]


def new_ttl(row, days):
    """The ttl this row should get, or None to leave it alone."""
    if "ttl" not in row:
        return None
    target = int(row["start_time"]) + days * DAY_SECONDS
    if int(row["ttl"]) <= target + SKEW_DAYS * DAY_SECONDS:
        return None
    return target


def set_ttl(table, row, ttl):
    """Returns False if the row was deleted or lost its ttl since the scan."""
    try:
        table.update_item(
            Key={"camera_id": row["camera_id"], "start_time": row["start_time"]},
            UpdateExpression="SET #ttl = :ttl",
            ConditionExpression="attribute_exists(#ttl)",
            ExpressionAttributeNames={"#ttl": "ttl"},
            ExpressionAttributeValues={":ttl": ttl},
        )
        return True
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return False
        raise


def reset(table, days, apply, now):
    counts = collections.Counter()
    expiring = collections.Counter()
    for row in scan_rows(table):
        ttl = new_ttl(row, days)
        if ttl is None:
            counts["no ttl (kept)" if "ttl" not in row else "already correct"] += 1
            continue
        counts["already past the new ttl" if ttl <= now else "ttl lowered, still in the future"] += 1
        if ttl <= now:
            expiring[row["camera_id"]] += 1
        if apply and not set_ttl(table, row, ttl):
            counts["changed since the scan (skipped)"] += 1
    return counts, expiring


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--days", type=int, default=60, help="retention in days (clips_ttl_days, default 60)")
    ap.add_argument("--apply", action="store_true", help="write the new ttls (default: dry run)")
    args = ap.parse_args()
    if args.days <= 30:
        ap.error("--days must be greater than 30 (same check as clips_ttl_days)")

    table = boto3.resource("dynamodb", region_name=REGION).Table(TABLE)
    counts, expiring = reset(table, args.days, args.apply, int(time.time()))

    print("Applied:" if args.apply else "Dry run, nothing written:")
    for name, count in sorted(counts.items()):
        print(f"  {name}: {count}")
    print(f"  to be deleted by DynamoDB, per camera: {dict(sorted(expiring.items()))}")


if __name__ == "__main__":
    main()
