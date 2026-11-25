"""
Tests for terraform/lambda/triage/handler.py.

AWS is mocked with moto; Bedrock is a scripted fake Converse client, so no
model is called. What matters most here: the loop's control flow (tool calls,
turn cap, blocked output), that a failure still sends a notice, and that every tool
enforces its own allowlist on top of IAM.
"""

import copy
import json
import time
from datetime import datetime, timedelta, timezone

import boto3
import pytest

from conftest import REGION, TABLE, load_handler

CAMERAS = ["c225_garage", "c660_street"]
LOG_GROUPS = ["tapo-poller", "/aws/lambda/tapo-clip-processor"]
TOPIC_NAME = "test-incident-reports"
OVERRIDE_PREFIX = "/test/poller/override/"
SELF_ALARM = "tapo-incident-triage-errors"


def alarm_event(name="tapo-poller-errors-c660_street", state="ALARM"):
    alarm = {
        "AlarmName": name,
        "NewStateValue": state,
        "NewStateReason": "Threshold Crossed: 4 datapoints were greater than or equal to the threshold (1.0).",
        "StateChangeTime": "2026-11-24T10:00:00.000+0000",
        "Trigger": {"MetricName": "PollCycleErrors", "Namespace": "Tapo/Camera",
                    "Dimensions": [{"name": "CameraName", "value": "c660_street"}]},
    }
    return {"Records": [{"Sns": {"Message": json.dumps(alarm)}}]}


# ── Fake Bedrock (Converse) ─────────────────────────────────

def text_block(text):
    return {"text": text}


def tool_block(name, args, block_id="tooluse_1"):
    return {"toolUse": {"toolUseId": block_id, "name": name, "input": args}}


def response(content, stop_reason):
    return {
        "output": {"message": {"role": "assistant", "content": content}},
        "stopReason": stop_reason,
        "usage": {"inputTokens": 100, "outputTokens": 20},
    }


class FakeBedrock:
    """Returns scripted Converse responses in order and records every request."""

    def __init__(self, *responses):
        self.responses = list(responses)
        self.requests = []

    def converse(self, **kwargs):
        # Deep copy: the handler appends to (and edits) the conversation later.
        self.requests.append(copy.deepcopy(kwargs))
        return self.responses.pop(0)


# ── Fixtures ────────────────────────────────────────────────

@pytest.fixture
def triage(aws, table, monkeypatch):
    topic_arn = boto3.client("sns").create_topic(Name=TOPIC_NAME)["TopicArn"]
    monkeypatch.setenv("AWS_REGION", REGION)
    monkeypatch.setenv("MODEL_ID", "eu.amazon.nova-2-lite-v1:0")
    monkeypatch.setenv("REPORT_TOPIC_ARN", topic_arn)
    monkeypatch.setenv("CLIPS_TABLE", TABLE)
    monkeypatch.setenv("CAMERAS", json.dumps(CAMERAS))
    monkeypatch.setenv("LOG_GROUPS", json.dumps(LOG_GROUPS))
    monkeypatch.setenv("OVERRIDE_PARAMETER_PREFIX", OVERRIDE_PREFIX)
    monkeypatch.setenv("SKIP_ALARMS", json.dumps([SELF_ALARM]))
    monkeypatch.setenv("MAX_TURNS", "3")
    handler = load_handler("triage")

    published = []
    monkeypatch.setattr(handler.sns, "publish", lambda **kw: published.append(kw))
    handler.published = published
    return handler


# ── Event filtering ─────────────────────────────────────────

def test_ok_transition_is_ignored(triage):
    triage.bedrock = FakeBedrock()  # would raise IndexError if called

    assert triage.lambda_handler(alarm_event(state="OK"), None) == {"handled": 0}
    assert triage.published == []


def test_own_errors_alarm_is_ignored(triage):
    triage.bedrock = FakeBedrock()

    assert triage.lambda_handler(alarm_event(name=SELF_ALARM), None) == {"handled": 0}
    assert triage.published == []


def test_non_alarm_record_is_ignored(triage):
    triage.bedrock = FakeBedrock()

    event = {"Records": [{"Sns": {"Message": "not json"}}]}
    assert triage.lambda_handler(event, None) == {"handled": 0}


# ── The loop ────────────────────────────────────────────────

def test_report_after_a_tool_call(triage):
    boto3.client("cloudwatch").put_metric_alarm(
        AlarmName="tapo-poller-errors-c325_porch", MetricName="PollCycleErrors", Namespace="Tapo/Camera",
        Statistic="Sum", Period=1800, EvaluationPeriods=2, Threshold=1, ComparisonOperator="GreaterThanOrEqualToThreshold",
    )
    fake = FakeBedrock(
        response([text_block("Checking alarms."), tool_block("list_alarms", {})], "tool_use"),
        response([text_block("Summary: the extender lost power.")], "end_turn"),
    )
    triage.bedrock = fake

    assert triage.lambda_handler(alarm_event(), None) == {"handled": 1}

    # The assistant turn went back unchanged, then the tool result in one user message, matched by id.
    second = fake.requests[1]["messages"]
    assert second[1] == {"role": "assistant", "content": [text_block("Checking alarms."), tool_block("list_alarms", {})]}
    [block] = second[2]["content"]
    result = block["toolResult"]
    assert second[2]["role"] == "user" and result["toolUseId"] == "tooluse_1" and result["status"] == "success"
    assert "tapo-poller-errors-c325_porch" in result["content"][0]["text"]

    [mail] = triage.published
    assert mail["Subject"] == "[triage] tapo-poller-errors-c660_street"
    assert "Summary: the extender lost power." in mail["Message"]
    assert "1 tool calls, 2 turns, 200+40 tokens" in mail["Message"]


def test_request_shape(triage):
    fake = FakeBedrock(response([text_block("Summary: ok")], "end_turn"))
    triage.bedrock = fake

    triage.lambda_handler(alarm_event(), None)

    req = fake.requests[0]
    assert req["modelId"] == "eu.amazon.nova-2-lite-v1:0"
    assert req["system"] == [{"text": triage.SYSTEM_PROMPT}]
    assert req["toolConfig"]["toolChoice"] == {"auto": {}}
    assert {t["toolSpec"]["name"] for t in req["toolConfig"]["tools"]} == set(triage.TOOL_FUNCTIONS)
    first = req["messages"][0]["content"][0]["text"]
    assert "tapo-poller-errors-c660_street" in first and "Current time (UTC): " in first


def test_bad_tool_input_goes_back_as_an_error(triage):
    fake = FakeBedrock(
        response([tool_block("recent_clips", {"camera": "c660_street"})], "tool_use"),  # hours_back missing
        response([text_block("Summary: ok")], "end_turn"),
    )
    triage.bedrock = fake

    triage.lambda_handler(alarm_event(), None)

    result = fake.requests[1]["messages"][-1]["content"][0]["toolResult"]
    assert result["status"] == "error" and "missing hours_back" in result["content"][0]["text"]


def test_turn_cap_asks_for_the_report_in_the_last_tool_result_message(triage):
    looping = [response([tool_block("list_alarms", {}, f"tooluse_{i}")], "tool_use") for i in range(3)]
    fake = FakeBedrock(*looping, response([text_block("Summary: unclear.")], "end_turn"))
    triage.bedrock = fake

    triage.lambda_handler(alarm_event(), None)

    assert len(fake.requests) == 4  # MAX_TURNS=3, plus the final one
    last = fake.requests[-1]["messages"]
    roles = [m["role"] for m in last]
    assert all(a != b for a, b in zip(roles, roles[1:]))  # Converse needs alternating roles
    assert "toolResult" in last[-1]["content"][0]
    assert "Turn limit reached" in last[-1]["content"][-1]["text"]
    assert "Summary: unclear." in triage.published[0]["Message"]


def test_tool_calls_after_the_turn_cap_are_a_failure(triage):
    triage.bedrock = FakeBedrock(*[response([tool_block("list_alarms", {}, f"tooluse_{i}")], "tool_use") for i in range(4)])

    with pytest.raises(triage.TriageError, match="kept calling tools"):
        triage.lambda_handler(alarm_event(), None)
    assert triage.published[0]["Subject"].startswith("[triage failed]")


@pytest.mark.parametrize("stop_reason", ["content_filtered", "guardrail_intervened"])
def test_blocked_output_sends_a_failure_notice_and_raises(triage, stop_reason):
    triage.bedrock = FakeBedrock(response([text_block("partial")], stop_reason))

    with pytest.raises(triage.TriageError, match=stop_reason):
        triage.lambda_handler(alarm_event(), None)

    [mail] = triage.published
    assert mail["Subject"] == "[triage failed] tapo-poller-errors-c660_street"
    assert "Investigate by hand" in mail["Message"]
    assert "Threshold Crossed" in mail["Message"]  # the raw alarm is still there


def test_bedrock_error_sends_a_failure_notice_and_raises(triage):
    class Broken:
        def converse(self, **kwargs):
            raise ConnectionError("bedrock unreachable")
    triage.bedrock = Broken()

    with pytest.raises(ConnectionError):
        triage.lambda_handler(alarm_event(), None)
    assert triage.published[0]["Subject"].startswith("[triage failed]")


def test_empty_report_is_a_failure(triage):
    triage.bedrock = FakeBedrock(response([], "end_turn"))

    with pytest.raises(triage.TriageError):
        triage.lambda_handler(alarm_event(), None)


def test_markdown_bold_is_stripped_from_the_email(triage):
    triage.bedrock = FakeBedrock(response([text_block("**Summary:** the porch socket.")], "end_turn"))

    triage.lambda_handler(alarm_event(), None)
    assert "Summary: the porch socket." in triage.published[0]["Message"]


def test_report_cut_off_at_max_tokens_is_still_sent(triage):
    triage.bedrock = FakeBedrock(response([text_block("Summary: the porch")], "max_tokens"))

    triage.lambda_handler(alarm_event(), None)
    assert "(Report cut off at the token limit.)" in triage.published[0]["Message"]


def test_long_subject_is_trimmed(triage):
    triage.bedrock = FakeBedrock(response([text_block("Summary: ok")], "end_turn"))

    triage.lambda_handler(alarm_event(name="tapo-" + "x" * 200), None)
    assert len(triage.published[0]["Subject"]) == 100


# ── Tools: allowlists and limits ────────────────────────────

def test_unknown_tool_is_an_error_result(triage):
    assert triage.run_tool("delete_everything", {}) == ("Unknown tool delete_everything", True)


@pytest.mark.parametrize("name, args, message", [
    ("get_metric_statistics", {"namespace": "AWS/EC2", "metric_name": "CPUUtilization", "dimensions": [],
                               "statistic": "Sum", "hours_back": 1, "period_minutes": 5}, "namespace must be"),
    ("get_metric_statistics", {"namespace": "Tapo/Camera", "metric_name": "PollCycleErrors", "dimensions": [],
                               "statistic": "Sum", "hours_back": 48, "period_minutes": 1}, "Too many datapoints"),
    ("get_metric_statistics", {"namespace": "Tapo/Camera", "metric_name": "PollCycleErrors", "dimensions": [],
                               "statistic": "Sum", "hours_back": 1, "period_minutes": 7}, "period_minutes must be"),
    ("query_logs", {"log_group": "/aws/lambda/other", "query": "fields @message", "hours_back": 1}, "log_group must be"),
    ("query_logs", {"log_group": "tapo-poller", "query": "fields @message", "hours_back": 500}, "hours_back must be"),
    ("get_camera_override", {"camera": "neighbours_cam"}, "camera must be"),
    ("recent_clips", {"camera": "c660_street", "hours_back": 0}, "hours_back must be"),
    ("get_alarm_history", {"alarm_name": "someone-elses-alarm", "hours_back": 1}, "Only alarms starting with"),
])
def test_tool_rejects_input_outside_its_allowlist(triage, name, args, message):
    result, is_error = triage.run_tool(name, args)
    assert is_error and message in result


def test_metric_statistics(triage):
    # Explicitly in the past: moto misses a datapoint stamped at "now".
    boto3.client("cloudwatch").put_metric_data(Namespace="Tapo/Camera", MetricData=[{
        "MetricName": "PollCycleErrors", "Dimensions": [{"Name": "CameraName", "Value": "c660_street"}], "Value": 2,
        "Timestamp": datetime.now(timezone.utc) - timedelta(minutes=10),
    }])

    result, is_error = triage.run_tool("get_metric_statistics", {
        "namespace": "Tapo/Camera", "metric_name": "PollCycleErrors",
        "dimensions": [{"name": "CameraName", "value": "c660_street"}],
        "statistic": "Sum", "hours_back": 1, "period_minutes": 60,
    })
    assert not is_error and "Sum=2" in result


def test_camera_override(triage):
    result, _ = triage.run_tool("get_camera_override", {"camera": "c660_street"})
    assert "No override set" in result

    boto3.client("ssm").put_parameter(Name=OVERRIDE_PREFIX + "c660_street", Type="String",
                                      Value='{"mode": "pause", "until": "2026-11-25T10:00:00+00:00"}')
    result, _ = triage.run_tool("get_camera_override", {"camera": "c660_street"})
    assert "mode 'pause'" in result


def test_recent_clips_newest_first(triage, table):
    now = int(time.time())
    for start, status in [(now - 7200, "complete"), (now - 600, "thumbnail_failed"), (now - 90000, "complete")]:
        table.put_item(Item={"camera_id": "c225_garage", "start_time": start, "uploaded_at": start + 300,
                             "processing_status": status, "date": "20261124"})

    result, is_error = triage.run_tool("recent_clips", {"camera": "c225_garage", "hours_back": 24})
    assert not is_error
    lines = result.splitlines()
    assert lines[0] == "2 clips:"
    assert "thumbnail_failed" in lines[1] and "complete" in lines[2]


def test_long_tool_result_is_truncated(triage, monkeypatch):
    monkeypatch.setitem(triage.TOOL_FUNCTIONS, "list_alarms", lambda args: "x" * 10000)

    result, is_error = triage.run_tool("list_alarms", {})
    assert not is_error
    assert len(result) < 6100 and result.endswith("narrow the query)")


def test_tool_exception_becomes_an_error_result(triage, monkeypatch):
    def boom(args):
        raise RuntimeError("throttled")
    monkeypatch.setitem(triage.TOOL_FUNCTIONS, "list_alarms", boom)

    assert triage.run_tool("list_alarms", {}) == ("Tool failed: RuntimeError: throttled", True)


def test_window_end_anchors_the_time_window_for_replays(triage, table):
    past = datetime(2026, 11, 17, 18, 0, tzinfo=timezone.utc)
    table.put_item(Item={"camera_id": "c225_garage", "start_time": int(past.timestamp()) - 600,
                         "uploaded_at": int(past.timestamp()), "processing_status": "complete", "date": "20261117"})

    result, _ = triage.run_tool("recent_clips", {"camera": "c225_garage", "hours_back": 1})
    assert result.startswith("No clips")  # a week ago is outside "the last hour" from now

    triage.WINDOW_END = past
    result, _ = triage.run_tool("recent_clips", {"camera": "c225_garage", "hours_back": 1})
    assert result.startswith("1 clips")


def _put(metric, value, dims=(), minutes_ago=10):
    boto3.client("cloudwatch").put_metric_data(Namespace="Tapo/Camera", MetricData=[{
        "MetricName": metric, "Dimensions": [{"Name": n, "Value": v} for n, v in dims], "Value": value,
        "Timestamp": datetime.now(timezone.utc) - timedelta(minutes=minutes_ago),
    }])


def test_repeated_camera_dimension_gives_one_series_per_camera(triage):
    # CloudWatch itself would silently use one of the values (the first live
    # run got the C660's series and took it for all four cameras).
    _put("PollCycleCompleted", 4, [("CameraName", "c225_garage")])
    _put("PollCycleCompleted", 1, [("CameraName", "c660_street")])

    result, is_error = triage.run_tool("get_metric_statistics", {
        "namespace": "Tapo/Camera", "metric_name": "PollCycleCompleted",
        "dimensions": [{"name": "CameraName", "value": "c225_garage"}, {"name": "CameraName", "value": "c660_street"},
                       {"name": "CameraName", "value": "c325_back"}],
        "statistic": "Sum", "hours_back": 1, "period_minutes": 60,
    })
    assert not is_error
    garage, street, back = result.split("== CameraName=")[1:]
    assert garage.startswith("c225_garage") and "Sum=4" in garage
    assert street.startswith("c660_street") and "Sum=1" in street
    assert back.startswith("c325_back") and "No datapoints" in back


def test_other_repeated_dimension_is_an_error(triage):
    result, is_error = triage.run_tool("get_metric_statistics", {
        "namespace": "AWS/Lambda", "metric_name": "Errors",
        "dimensions": [{"name": "FunctionName", "value": "a"}, {"name": "FunctionName", "value": "b"}],
        "statistic": "Sum", "hours_back": 1, "period_minutes": 60,
    })
    assert is_error and "only CameraName may repeat" in result


def no_uploads_alarm():
    return {
        "AlarmName": "tapo-no-uploads-6h", "NewStateValue": "ALARM", "NewStateReason": "testing the triage agent",
        "StateChangeTime": "2026-11-25T10:31:00.000+0000",
        "Trigger": {"MetricName": "ClipsProcessed", "Namespace": "Tapo/Camera", "Statistic": "SUM", "Dimensions": [],
                    "Period": 3600, "EvaluationPeriods": 6, "ComparisonOperator": "LessThanThreshold",
                    "Threshold": 1.0, "TreatMissingData": "breaching"},
    }


def test_first_message_carries_the_alarms_own_metric(triage):
    _put("ClipsProcessed", 7)
    fake = FakeBedrock(response([text_block("Summary: ok")], "end_turn"))
    triage.bedrock = fake

    triage.lambda_handler({"Records": [{"Sns": {"Message": json.dumps(no_uploads_alarm())}}]}, None)

    first = fake.requests[0]["messages"][0]["content"][0]["text"]
    assert "The alarm's own metric over the last 12 h (period 60 min, 6 periods evaluated" in first
    assert "missing data treated as breaching" in first
    assert "Tapo/Camera ClipsProcessed (Sum):" in first and "Sum=7" in first


def test_alarm_metric_for_a_metric_math_alarm(triage):
    _put("PollCycleErrors", 2, [("CameraName", "c660_street")])
    alarm = {"Trigger": {"Period": 3600, "EvaluationPeriods": 4, "Metrics": [
        {"Id": "e1", "Expression": "FILL(errors, 0)", "ReturnData": True},
        {"Id": "errors", "ReturnData": False, "MetricStat": {
            "Metric": {"Namespace": "Tapo/Camera", "MetricName": "PollCycleErrors",
                       "Dimensions": [{"name": "CameraName", "value": "c660_street"}]},
            "Period": 3600, "Stat": "Sum"}},
    ]}}

    context = triage.alarm_context(alarm)
    assert "Alarm expression: FILL(errors, 0)" in context
    assert "PollCycleErrors CameraName=c660_street (Sum):" in context and "Sum=2" in context


def test_metric_math_alarm_without_a_top_level_period(triage):
    # describe-alarms shows Period only inside MetricStat for these alarms.
    _put("PollCycleErrors", 3, [("CameraName", "c325_porch")])
    alarm = {"Trigger": {"EvaluationPeriods": 2, "Metrics": [
        {"Id": "errors", "ReturnData": False, "MetricStat": {
            "Metric": {"Namespace": "Tapo/Camera", "MetricName": "PollCycleErrors",
                       "Dimensions": [{"name": "CameraName", "value": "c325_porch"}]},
            "Period": 1800, "Stat": "Sum"}},
        {"Id": "errors_or_zero", "Expression": "FILL(errors, 0)", "ReturnData": True},
    ]}}

    context = triage.alarm_context(alarm)
    assert "over the last 3 h (period 30 min, 2 periods evaluated" in context and "Sum=3" in context


@pytest.mark.parametrize("alarm, message", [
    ({}, "couldn't fetch it"),  # no Trigger
    ({"Trigger": {"Period": 300, "Metrics": []}}, "no metric in the notification"),
    ({"Trigger": {"Period": 300, "MetricName": "CPUUtilization", "Namespace": "AWS/EC2", "Statistic": "AVERAGE"}},
     "not fetched"),
])
def test_alarm_metric_problems_become_a_note(triage, alarm, message):
    assert message in triage.alarm_context(alarm)


# ── Facts checked by code ───────────────────────────────────

def _aligned_window(triage, period):
    """Pin WINDOW_END mid-period and return the start of each of the last periods (oldest first)."""
    now = int(time.time()) // period * period
    triage.WINDOW_END = datetime.fromtimestamp(now + period // 3, timezone.utc)
    return lambda n: [datetime.fromtimestamp(now - period * (n - i), timezone.utc) for i in range(n)]


def _put_at(metric, value, ts, dims=()):
    boto3.client("cloudwatch").put_metric_data(Namespace="Tapo/Camera", MetricData=[{
        "MetricName": metric, "Dimensions": [{"Name": n, "Value": v} for n, v in dims], "Value": value,
        "Timestamp": ts + timedelta(minutes=5),
    }])


def test_free_text_reason_is_flagged_as_set_by_hand(triage):
    assert "NOT set by CloudWatch's metric evaluation" in triage.alarm_context(no_uploads_alarm())
    alarm = dict(no_uploads_alarm(), NewStateReason="Threshold Crossed: 6 datapoints were less than the threshold (1.0).")
    assert "State set by CloudWatch's own evaluation" in triage.alarm_context(alarm)


def test_no_uploads_condition_not_met_when_clips_were_processed(triage):
    # The second live run claimed ClipsProcessed was 0 next to hourly 8s and 12s.
    starts = _aligned_window(triage, 3600)(6)
    for ts, value in zip(starts, [11, 4, 4, 12, 8, 8]):
        _put_at("ClipsProcessed", value, ts)

    context = triage.alarm_context(no_uploads_alarm())
    assert ": 11, 4, 4, 12, 8, 8." in context
    assert "needs 6 of 6 periods < 1 (missing data: breaching); 0 breach. Condition NOT MET" in context


def test_no_uploads_condition_met_when_nothing_was_reported(triage):
    _aligned_window(triage, 3600)
    context = triage.alarm_context(no_uploads_alarm())
    assert "missing, missing, missing, missing, missing, missing" in context
    assert "6 breach. Condition MET." in context


def test_treat_missing_data_in_the_verbose_sns_format(triage):
    _aligned_window(triage, 3600)
    alarm = no_uploads_alarm()
    alarm["Trigger"]["TreatMissingData"] = "- TreatMissingData:                    Breaching"
    assert "6 breach. Condition MET." in triage.alarm_context(alarm)


def math_errors_alarm():
    return {"NewStateReason": "Threshold Crossed: 2 datapoints were greater than or equal to the threshold (1.0).",
            "Trigger": {"EvaluationPeriods": 2, "ComparisonOperator": "GreaterThanOrEqualToThreshold", "Threshold": 1.0,
                        "TreatMissingData": "notBreaching", "Metrics": [
                            {"Id": "errors", "ReturnData": False, "MetricStat": {
                                "Metric": {"Namespace": "Tapo/Camera", "MetricName": "PollCycleErrors",
                                           "Dimensions": [{"name": "CameraName", "value": "c325_porch"}]},
                                "Period": 1800, "Stat": "Sum"}},
                            {"Id": "errors_or_zero", "Expression": "FILL(errors, 0)", "ReturnData": True}]}}


@pytest.mark.parametrize("values, expected", [
    ([1, 2], "2 breach. Condition MET."),
    ([None, 2], "0, 2. The alarm needs 2 of 2 periods >= 1 (missing data: notBreaching); 1 breach. Condition NOT MET"),
])
def test_fill_metric_math_condition(triage, values, expected):
    starts = _aligned_window(triage, 1800)(2)
    for ts, value in zip(starts, values):
        if value is not None:
            _put_at("PollCycleErrors", value, ts, [("CameraName", "c325_porch")])

    assert expected in triage.alarm_context(math_errors_alarm())


def test_unknown_alarm_shapes_get_data_but_no_verdict(triage):
    alarm = math_errors_alarm()
    alarm["Trigger"]["Metrics"][1]["Expression"] = "errors * 2"
    context = triage.alarm_context(alarm)
    assert "Condition" not in context and "PollCycleErrors CameraName=c325_porch (Sum):" in context


@pytest.mark.parametrize("until, expected", [
    ("2026-11-06T10:16:51+00:00", "EXPIRED 19.1 days ago, NOT in effect"),
    ("2026-11-25T17:00:00+00:00", "ACTIVE for another 5.0 h"),
])
def test_camera_override_is_interpreted(triage, until, expected):
    triage.WINDOW_END = datetime(2026, 11, 25, 12, 0, tzinfo=timezone.utc)
    boto3.client("ssm").put_parameter(Name=OVERRIDE_PREFIX + "c660_street", Type="String",
                                      Value=json.dumps({"mode": "pause", "until": until, "set_by": "someone"}))
    result, _ = triage.run_tool("get_camera_override", {"camera": "c660_street"})
    assert "mode 'pause'" in result and expected in result


def test_unparseable_override_is_passed_through(triage):
    boto3.client("ssm").put_parameter(Name=OVERRIDE_PREFIX + "c660_street", Type="String", Value="pause please")
    result, _ = triage.run_tool("get_camera_override", {"camera": "c660_street"})
    assert "pause please" in result and "couldn't parse" in result
