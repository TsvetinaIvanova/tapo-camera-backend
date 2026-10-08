# Processor Lambda as a container image (replaces the third-party ffmpeg layer).
#
# ffmpeg comes from Debian, not a copied-in static binary: Debian ships
# security fixes for it, and ECR scanning can only see OS packages, so a
# vulnerable ffmpeg shows up in scan results.
#
# Base pinned by digest (from ECR Public, which avoids Docker Hub rate limits);
# Dependabot bumps it. Rebuilding picks up Debian's latest ffmpeg patch.
FROM public.ecr.aws/docker/library/python:3.12-slim-trixie@sha256:05cda9777409a9c3ffddd94a4c476b79f0769a0b4857f0c7ed9226b6800b0d6f

RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/* \
    # The handler calls /opt/bin/ffmpeg (the layer path); keep it working
    # for both the zip+layer and the image packaging.
    && mkdir -p /opt/bin \
    && ln -s /usr/bin/ffmpeg /opt/bin/ffmpeg

WORKDIR /var/task

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY handler.py .

# Non-AWS base image, so the runtime interface client is the entrypoint.
ENTRYPOINT ["python", "-m", "awslambdaric"]
CMD ["handler.lambda_handler"]
