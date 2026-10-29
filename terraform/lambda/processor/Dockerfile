# Processor Lambda as a container image (replaces the third-party ffmpeg layer).
#
# ffmpeg is built from source with only what the handler uses: read an
# MP4/MOV file, decode H.264/HEVC, encode one MJPEG frame. That leaves out
# the codec, image and XML libraries a distro ffmpeg pulls in (libtiff,
# librsvg, libxml2, ...), which account for all of Debian ffmpeg's scan
# findings, and gives a small, static, LGPL-only binary.
#
# Tradeoff: ECR scanning only sees OS packages, so it cannot see this ffmpeg.
# Its CVEs are tracked by pinning FFMPEG_VERSION and following FFmpeg
# security releases (see docs/project-notes.md).
#
# Both stages use the same digest-pinned base (ECR Public, no Docker Hub
# rate limits), so the binary is built against the same glibc it runs on.
# The reference is repeated in both FROM lines rather than put in an ARG
# because Dependabot only bumps literal FROM lines; it updates both together.

# ── Build stage: minimal static ffmpeg ──────────────────────
FROM public.ecr.aws/docker/library/python:3.15-slim-trixie@sha256:94d3426f1def7db4a106a232ac121bfd975393e5dfd40a619b955fae45fe7913 AS ffmpeg-build

# Source tarball pinned by SHA-256. The hash was taken after verifying the
# tarball's GPG signature against the FFmpeg release signing key
# (FCF9 86EA 15E6 E293 A564 4F10 B432 2F04 D676 58D8).
ARG FFMPEG_VERSION=9.0.2
ARG FFMPEG_SHA256=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential nasm pkg-config xz-utils \
    && rm -rf /var/lib/apt/lists/*

ADD --checksum=sha256:${FFMPEG_SHA256} \
    https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz /tmp/ffmpeg.tar.xz

WORKDIR /tmp/ffmpeg
RUN tar -xJf /tmp/ffmpeg.tar.xz --strip-components=1 \
    && ./configure \
        --prefix=/opt/ffmpeg \
        --enable-static --disable-shared \
        --disable-autodetect --disable-everything \
        --disable-doc --disable-debug --disable-network \
        --disable-ffplay --disable-ffprobe --disable-avdevice \
        --enable-protocol=file \
        --enable-demuxer=mov \
        --enable-parser=h264,hevc \
        --enable-decoder=h264,hevc \
        --enable-encoder=mjpeg \
        --enable-muxer=image2 \
        --enable-filter=scale \
    && make -j"$(nproc)" \
    && make install \
    && strip /opt/ffmpeg/bin/ffmpeg \
    && cd / && rm -rf /tmp/ffmpeg /tmp/ffmpeg.tar.xz   # keep the cached layer small

# ── Runtime stage ───────────────────────────────────────────
FROM public.ecr.aws/docker/library/python:3.15-slim-trixie@sha256:94d3426f1def7db4a106a232ac121bfd975393e5dfd40a619b955fae45fe7913

# The handler calls /opt/bin/ffmpeg (the old layer path), so it is unchanged.
COPY --from=ffmpeg-build /opt/ffmpeg/bin/ffmpeg /opt/bin/ffmpeg

WORKDIR /var/task

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY handler.py .

# Non-AWS base image, so the runtime interface client is the entrypoint.
ENTRYPOINT ["python", "-m", "awslambdaric"]
CMD ["handler.lambda_handler"]
