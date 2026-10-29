# ── Alert topic ─────────────────────────────────────────────

resource "aws_sns_topic" "alerts" {
  name = "tapo-camera-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ── Pipeline alarms ─────────────────────────────────────────

# Counts successful clip uploads by looking for the log line
# the processor Lambda emits after a successful DynamoDB write.
resource "aws_cloudwatch_log_metric_filter" "clip_processed" {
  name           = "tapo-clip-processed"
  log_group_name = module.processor.log_group_name
  pattern        = "\"Metadata written for\""

  metric_transformation {
    name          = "ClipsProcessed"
    namespace     = "Tapo/Camera"
    value         = "1"
    default_value = "0" # emit 0 when no log matches — essential for the alarm to fire
  }
}

# Fires when fewer than 1 clip has been processed in 60 minutes.
# Uses a single 60-minute evaluation period so the alarm fires
# as soon as one full hour passes with no uploads.
resource "aws_cloudwatch_metric_alarm" "no_uploads" {
  alarm_name          = "tapo-no-uploads-1h"
  alarm_description   = "No camera clips processed in the last 60 minutes — poller or pipeline may be down"
  namespace           = "Tapo/Camera"
  metric_name         = "ClipsProcessed"
  statistic           = "Sum"
  period              = 3600 # 1 hour window
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching" # no data = alarm, not OK

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn] # also notify when it recovers
}

# Secondary alarm: alert if the processor Lambda itself starts erroring.
# This catches issues like IAM permission failures, DynamoDB throttling,
# or code errors that prevent metadata from being written.
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name        = "tapo-processor-errors"
  alarm_description = "tapo-clip-processor Lambda error rate elevated"
  namespace         = "AWS/Lambda"
  metric_name       = "Errors"
  dimensions = {
    FunctionName = module.processor.function_name
  }
  statistic           = "Sum"
  period              = 300 # check every 5 minutes
  evaluation_periods  = 3   # alarm after 15 minutes of errors
  threshold           = 3
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# ── Poller heartbeat + error alarms ─────────────────────────

# These come directly from the poller (via boto3 put_metric_data), not
# from downstream log lines — so they detect the poller itself being
# dead/hung or erroring, independent of whether any camera actually
# saw motion. Complements the existing ClipsProcessed alarm, which
# can't distinguish "poller down" from "quiet night, no clips."
locals {
  # Keep this in sync with the "name" fields in poller/config.yaml.
  tapo_camera_names = [
    "c225_garage",
    "c325_back",
    "c325_porch",
    "c660_street",
  ]
}

# Fires if a given camera's poller thread stops reporting entirely —
# process crashed, thread hung, systemd service down, etc. A cycle skipped
# on purpose (manual pause, or auto-paused on low battery) still emits
# PollCycleCompleted (plus PollCyclePaused, not alarmed on), so a pause
# doesn't page. Kept to one metric on purpose: metric math would bill each
# metric in the expression as a separate alarm metric.
resource "aws_cloudwatch_metric_alarm" "poller_heartbeat" {
  for_each = toset(local.tapo_camera_names)

  alarm_name        = "tapo-poller-heartbeat-${each.value}"
  alarm_description = "No poll cycle reported for ${each.value} in 30 minutes — poller thread may be dead or hung"
  namespace         = "Tapo/Camera"
  metric_name       = "PollCycleCompleted"
  dimensions = {
    CameraName = each.value
  }
  statistic = "Sum"
  period    = 1800 # 30 minutes — a few missed cycles even
  # on the slowest (night_mode) interval
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching" # no data = the thread stopped reporting = alarm

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# Fires if a camera's poll cycles are running but erroring — connection
# failures, auth failures, download failures — even if zero clips would
# have been expected anyway. This is the case that ClipsProcessed alone
# can't catch: the poller runs, logs errors, uploads nothing.
resource "aws_cloudwatch_metric_alarm" "poller_errors" {
  for_each = toset(local.tapo_camera_names)

  alarm_name        = "tapo-poller-errors-${each.value}"
  alarm_description = "${each.value} poller is reporting errors — connection, auth, or download failures"
  namespace         = "Tapo/Camera"
  metric_name       = "PollCycleErrors"
  dimensions = {
    CameraName = each.value
  }
  statistic           = "Sum"
  period              = 1800
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching" # no errors reported = healthy, not alarming

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# ── Battery alarm ───────────────────────────────────────────

locals {
  # Cameras with battery_powered: true in poller/config.yaml.
  tapo_battery_camera_names = ["c660_street"]
}

# Fires when a battery camera's charge drops low, so there's time to pause
# polling or slow it down before the camera dies. The poller reads the
# battery in the session it already opens, so this metric arrives once per
# poll cycle. Gaps (thread dead, connection failed) are the heartbeat and
# error alarms' job, so missing data keeps the current state instead of
# flapping to OK.
resource "aws_cloudwatch_metric_alarm" "battery_low" {
  for_each = toset(local.tapo_battery_camera_names)

  alarm_name        = "tapo-battery-low-${each.value}"
  alarm_description = "${each.value} battery below ${var.battery_low_threshold_percent}% — consider pausing or slowing its polling"
  namespace         = "Tapo/Camera"
  metric_name       = "BatteryPercent"
  dimensions = {
    CameraName = each.value
  }
  statistic           = "Minimum"
  period              = 3600 # longer than the slowest night_mode interval
  evaluation_periods  = 1
  threshold           = var.battery_low_threshold_percent
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "missing"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# ── Poller log shipping alarm ───────────────────────────────

# Fires when the poller's log group stops receiving events. Metrics and logs
# reach AWS separately, so the poller can keep polling (heartbeats fine)
# while its logs silently stop: this happened twice, after the Pi booted
# before the internet was back. The poller logs every poll cycle, so an
# hour without events means shipping is broken (or the whole poller is
# down, which the heartbeat alarms also report). IncomingLogEvents is a
# free vended metric; the alarm is one alarm metric.
resource "aws_cloudwatch_metric_alarm" "poller_logs_silent" {
  alarm_name        = "tapo-poller-logs-silent"
  alarm_description = "No log events from the poller in 60 minutes: log shipping is broken, or the poller is down (check the heartbeat alarms)"
  namespace         = "AWS/Logs"
  metric_name       = "IncomingLogEvents"
  dimensions = {
    LogGroupName = aws_cloudwatch_log_group.poller.name
  }
  statistic           = "Sum"
  period              = 3600 # longer than the slowest night_mode interval
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching" # vended metric has no datapoint when nothing arrives

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}
