#!/usr/bin/env bash
# Smoke-test the processor image without touching AWS: ffmpeg runs at the
# path the handler uses, the handler and runtime client import, and the
# handler's own generate_thumbnail() turns the fixture clips into JPEGs.
# Fixtures (testdata/) are synthetic H.264 and HEVC clips with an AAC track,
# like Tapo recordings; the minimal ffmpeg can only decode, so they are
# committed rather than generated here.
# Usage: smoke-test.sh <image>
set -euo pipefail

image="$1"
testdata="$(cd "$(dirname "$0")/testdata" && pwd)"
env_args=(-e DYNAMODB_TABLE=smoke-test -e S3_BUCKET=smoke-test -e AWS_DEFAULT_REGION=eu-central-1)

echo "== ffmpeg version"
docker run --rm --entrypoint /opt/bin/ffmpeg "$image" -hide_banner -version | head -1

echo "== handler thumbnails from fixture clips"
docker run --rm "${env_args[@]}" -v "$testdata:/testdata:ro" --entrypoint python "$image" -c '
import glob, os
import awslambdaric  # noqa: F401  (entrypoint must be importable)
import handler

clips = sorted(glob.glob("/testdata/*.mp4"))
assert clips, "no fixture clips found"
for clip in clips:
    thumb = "/tmp/" + os.path.basename(clip) + ".jpg"
    assert handler.generate_thumbnail(clip, thumb), f"generate_thumbnail failed for {clip}"
    size = os.path.getsize(thumb)
    assert size > 0, f"empty thumbnail for {clip}"
    print(f"{os.path.basename(clip)}: thumbnail ok ({size} bytes)")
'
