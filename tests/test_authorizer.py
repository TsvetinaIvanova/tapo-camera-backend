"""API authorizer Lambda: shared secret in the x-api-key header, checked against SSM."""

import logging

import boto3
import pytest

from conftest import SECRET, SECRET_PARAMETER, load_handler


@pytest.fixture
def handler(aws, monkeypatch):
    monkeypatch.setenv("SECRET_PARAMETER_NAME", SECRET_PARAMETER)
    return load_handler("authorizer")


@pytest.fixture
def secret(aws):
    boto3.client("ssm").put_parameter(Name=SECRET_PARAMETER, Value=SECRET, Type="SecureString")


@pytest.fixture
def ssm_calls(handler, monkeypatch):
    """Count the handler's SSM lookups."""
    calls = []
    real = handler.ssm.get_parameter

    def counting(**kwargs):
        calls.append(kwargs)
        return real(**kwargs)
    monkeypatch.setattr(handler.ssm, "get_parameter", counting)
    return calls


def authorize(handler, headers):
    return handler.lambda_handler({"headers": headers}, None)


def test_correct_key_is_authorized(handler, secret):
    assert authorize(handler, {"x-api-key": SECRET}) == {"isAuthorized": True}


@pytest.mark.parametrize("key", [
    "wrong",
    SECRET[:-1],        # prefix of the secret
    SECRET + "x",
    SECRET.upper(),
    " " + SECRET,
])
def test_wrong_key_is_denied(handler, secret, key):
    assert authorize(handler, {"x-api-key": key}) == {"isAuthorized": False}


@pytest.mark.parametrize("event", [
    {"headers": {}},
    {"headers": {"x-api-key": ""}},
    {"headers": None},
    {},
    {"headers": {"authorization": SECRET}},  # secret in the wrong header
])
def test_missing_key_is_denied_without_calling_ssm(handler, secret, ssm_calls, event):
    assert handler.lambda_handler(event, None) == {"isAuthorized": False}
    assert ssm_calls == []


def test_comparison_is_constant_time(handler, secret, monkeypatch):
    compared = []
    real = handler.hmac.compare_digest

    def spy(a, b):
        compared.append((a, b))
        return real(a, b)
    monkeypatch.setattr(handler.hmac, "compare_digest", spy)

    authorize(handler, {"x-api-key": "wrong"})

    assert compared == [(b"wrong", SECRET.encode())]


def test_secret_is_fetched_decrypted_and_cached(handler, secret, ssm_calls):
    for _ in range(3):
        assert authorize(handler, {"x-api-key": SECRET}) == {"isAuthorized": True}

    assert ssm_calls == [{"Name": SECRET_PARAMETER, "WithDecryption": True}]


def test_ssm_failure_denies_and_is_retried(handler, ssm_calls):
    # The parameter doesn't exist yet: fail closed, and don't cache the failure.
    assert authorize(handler, {"x-api-key": SECRET}) == {"isAuthorized": False}

    boto3.client("ssm").put_parameter(Name=SECRET_PARAMETER, Value=SECRET, Type="SecureString")

    assert authorize(handler, {"x-api-key": SECRET}) == {"isAuthorized": True}
    assert len(ssm_calls) == 2


def test_keys_are_not_logged(handler, secret, caplog):
    with caplog.at_level(logging.INFO):
        authorize(handler, {"x-api-key": SECRET})
        authorize(handler, {"x-api-key": "wrong-guess"})

    assert SECRET not in caplog.text
    assert "wrong-guess" not in caplog.text


def test_non_ascii_key_is_denied(handler, secret):
    assert authorize(handler, {"x-api-key": "pässword"}) == {"isAuthorized": False}
