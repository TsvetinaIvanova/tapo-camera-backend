"""
Shared fixtures for the Lambda handler tests.

The three handlers are all called handler.py and create their boto3 clients
and read their environment at import time, so each test loads a fresh copy
from its file path, inside moto's mock and with the environment already set.
Nothing here touches real AWS.
"""

import importlib.util
import pathlib

import boto3
import pytest
from moto import mock_aws

LAMBDA_DIR = pathlib.Path(__file__).resolve().parents[1] / "terraform" / "lambda"

REGION = "eu-central-1"
BUCKET = "test-clips"
TABLE = "test-camera-clips"
SECRET_PARAMETER = "/test/api-shared-secret"
SECRET = "correct-horse-battery-staple"


def load_handler(name: str):
    """Import terraform/lambda/<name>/handler.py as a fresh module."""
    spec = importlib.util.spec_from_file_location(f"{name}_handler", LAMBDA_DIR / name / "handler.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def aws(monkeypatch):
    """moto mock with fake credentials; a real profile must never be picked up."""
    monkeypatch.delenv("AWS_PROFILE", raising=False)
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "testing")
    monkeypatch.setenv("AWS_SESSION_TOKEN", "testing")
    monkeypatch.setenv("AWS_DEFAULT_REGION", REGION)
    with mock_aws():
        yield


@pytest.fixture
def bucket(aws):
    s3 = boto3.client("s3")
    s3.create_bucket(Bucket=BUCKET, CreateBucketConfiguration={"LocationConstraint": REGION})
    return s3


@pytest.fixture
def table(aws):
    """Same keys and GSI as aws_dynamodb_table.camera_clips in terraform/clips.tf."""
    return boto3.resource("dynamodb").create_table(
        TableName=TABLE,
        BillingMode="PAY_PER_REQUEST",
        AttributeDefinitions=[
            {"AttributeName": "camera_id", "AttributeType": "S"},
            {"AttributeName": "start_time", "AttributeType": "N"},
            {"AttributeName": "date", "AttributeType": "S"},
        ],
        KeySchema=[
            {"AttributeName": "camera_id", "KeyType": "HASH"},
            {"AttributeName": "start_time", "KeyType": "RANGE"},
        ],
        GlobalSecondaryIndexes=[{
            "IndexName": "date-start_time-index",
            "KeySchema": [
                {"AttributeName": "date", "KeyType": "HASH"},
                {"AttributeName": "start_time", "KeyType": "RANGE"},
            ],
            "Projection": {"ProjectionType": "ALL"},
        }],
    )
