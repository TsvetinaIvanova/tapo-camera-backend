#!/usr/bin/env bash
# Smoke-test the processor image without touching AWS: ffmpeg runs at the
# path the handler uses, the handler and runtime client import, and the
# handler's own generate_thumbnail() turns the fixture clips into JPEGs.
# Fixtures (testdata/) are synthetic H.264 and HEVC (hev1, like the C660)
# clips with an AAC track, like Tapo recordings; the minimal ffmpeg can only
# decode, so they are committed rather than generated here. Their source
# width is in the name (..._<width>w.mp4), so the test checks the exact
# thumbnail width: downscaled to the cap, never upscaled.
# Usage: smoke-test.sh <image>
set -euo pipefail

image="$1"
testdata="$(cd "$(dirname "$0")/testdata" && pwd)"
env_args=(-e DYNAMODB_TABLE=smoke-test -e S3_BUCKET=smoke-test -e AWS_DEFAULT_REGION=eu-central-1)

echo "== ffmpeg version"
docker run --rm --entrypoint /opt/bin/ffmpeg "$image" -hide_banner -version | head -1

echo "== handler thumbnails from fixture clips"
docker run --rm "${env_args[@]}" -v "$testdata:/testdata:ro" --entrypoint python "$image" -c '
import glob, os, struct
import awslambdaric  # noqa: F401  (entrypoint must be importable)
import handler


def jpeg_size(path):
    """(width, height) from the JPEG SOF marker; no imaging library needed."""
    with open(path, "rb") as f:
        data = f.read()
    i = 2
    while i < len(data):
        marker, length = data[i + 1], struct.unpack(">H", data[i + 2:i + 4])[0]
        if 0xC0 <= marker <= 0xC3:
            h, w = struct.unpack(">HH", data[i + 5:i + 9])
            return w, h
        i += 2 + length
    raise ValueError("no SOF marker")


clips = sorted(glob.glob("/testdata/*.mp4"))
assert clips, "no fixture clips found"
for clip in clips:
    thumb = "/tmp/" + os.path.basename(clip) + ".jpg"
    assert handler.generate_thumbnail(clip, thumb), f"generate_thumbnail failed for {clip}"
    size = os.path.getsize(thumb)
    assert size > 0, f"empty thumbnail for {clip}"
    w, h = jpeg_size(thumb)
    src_w = int(os.path.basename(clip).rsplit("_", 1)[1].removesuffix("w.mp4"))
    expected = min(src_w, handler.THUMBNAIL_MAX_WIDTH)
    assert w == expected, f"thumbnail width {w}px, expected {expected}px"
    print(f"{os.path.basename(clip)}: thumbnail ok ({w}x{h}, {size} bytes)")
'
