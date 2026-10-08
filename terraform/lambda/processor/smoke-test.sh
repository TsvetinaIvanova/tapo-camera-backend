#!/usr/bin/env bash
# Smoke-test the processor image without touching AWS: ffmpeg runs at the
# path the handler uses, the handler and runtime client import, and the
# handler's own generate_thumbnail() turns synthetic H.264 and H.265 clips
# (the codecs Tapo cameras record) into JPEGs.
# Usage: smoke-test.sh <image>
set -euo pipefail

image="$1"
env_args=(-e DYNAMODB_TABLE=smoke-test -e S3_BUCKET=smoke-test -e AWS_DEFAULT_REGION=eu-central-1)

echo "== ffmpeg version"
docker run --rm --entrypoint /opt/bin/ffmpeg "$image" -hide_banner -version | head -1

echo "== handler thumbnails from synthetic clips"
docker run --rm "${env_args[@]}" --entrypoint python "$image" -c '
import os, subprocess
import awslambdaric  # noqa: F401  (entrypoint must be importable)
import handler

for codec, extra in (("libx264", []), ("libx265", ["-x265-params", "log-level=none"])):
    clip, thumb = f"/tmp/{codec}.mp4", f"/tmp/{codec}.jpg"
    subprocess.run(
        ["/opt/bin/ffmpeg", "-loglevel", "error", "-f", "lavfi",
         "-i", "testsrc=duration=3:size=640x360:rate=15",
         "-c:v", codec, *extra, "-pix_fmt", "yuv420p", clip],
        check=True,
    )
    assert handler.generate_thumbnail(clip, thumb), f"generate_thumbnail failed for {codec}"
    size = os.path.getsize(thumb)
    assert size > 0, f"empty thumbnail for {codec}"
    print(f"{codec}: thumbnail ok ({size} bytes)")
'
