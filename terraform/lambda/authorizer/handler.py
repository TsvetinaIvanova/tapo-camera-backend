"""
tapo-api-authorizer Lambda

Simple REQUEST authorizer for the HTTP API (payload format 2.0, simple
response). Validates a shared-secret header against the value stored
in SSM Parameter Store, using a constant-time comparison to avoid
timing attacks.

Expected header: x-api-key: <secret>

The secret is fetched from SSM once per warm Lambda instance and
cached in memory for the container's lifetime — API Gateway's own
authorizer result caching (see authorizer_result_ttl_in_seconds in
Terraform) means this function usually isn't invoked on every request
anyway, but the in-memory cache avoids a redundant SSM call even when
it is.
"""

import hmac
import logging
import os

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ssm = boto3.client("ssm")

PARAMETER_NAME = os.environ["SECRET_PARAMETER_NAME"]

_cached_secret = None


def get_secret() -> str:
    global _cached_secret
    if _cached_secret is None:
        resp = ssm.get_parameter(Name=PARAMETER_NAME, WithDecryption=True)
        _cached_secret = resp["Parameter"]["Value"]
    return _cached_secret


def lambda_handler(event: dict, context) -> dict:
    # HTTP API lower-cases header names before they reach the authorizer.
    headers = event.get("headers") or {}
    provided = headers.get("x-api-key", "")

    if not provided:
        logger.info("Authorization denied — missing x-api-key header")
        return {"isAuthorized": False}

    try:
        expected = get_secret()
    except Exception as e:
        # Fail closed: if we can't reach SSM, deny rather than default-allow.
        logger.error(f"Failed to fetch secret from SSM: {e}", exc_info=True)
        return {"isAuthorized": False}

    is_authorized = hmac.compare_digest(provided, expected)

    if not is_authorized:
        logger.info("Authorization denied — invalid x-api-key value")

    return {"isAuthorized": is_authorized}
