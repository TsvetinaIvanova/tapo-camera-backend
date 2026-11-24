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

# Fires when no clip has been processed for 6 hours in a row, across all
# cameras. A 1-hour window fired about 5 times a week on quiet nights
# (replayed 2026-11-06..20: 6 hours fired only during a real outage). The
# poller's own heartbeat and error alarms catch a broken poller sooner;
# this one is for the pipeline after it, e.g. the processor's S3 trigger
# silently gone, which nothing else alarms on.
resource "aws_cloudwatch_metric_alarm" "no_uploads" {
  alarm_name          = "tapo-no-uploads-6h"
  alarm_description   = "No camera clips processed for 6 hours: the poller's uploads or the processor's S3 trigger may be broken"
  namespace           = "Tapo/Camera"
  metric_name         = "ClipsProcessed"
  statistic           = "Sum"
  period              = 3600
  evaluation_periods  = 6
  datapoints_to_alarm = 6
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
#
# Only persistent errors, with a window per kind of camera (replayed against
# 2026-11-06..20, when "any error in 30 minutes" fired 61 times for the C660):
# - Battery cameras: an error in each of the last 4 hours. The C660 loses
#   ~10-15% of polls to Wi-Fi drops between wakes and self-heals on the next
#   poll. Replayed: 4 alarms (3 evenings with 4+ hours of errors, plus the
#   11-17..19 outage as one alarm). Hourly periods because it polls only once
#   an hour at night; shorter periods would have gaps there (missing = not
#   breaching) and miss a night outage.
# - Wired cameras: errors in two 30-minute periods in a row (~1 hour). They
#   poll every 15 minutes and almost never error (1 error in 14 days, a Pi
#   network blip). Replayed: only the 11-17..19 porch outage.
#
# "In a row" needs FILL(errors, 0). The poller emits PollCycleErrors only
# when a poll fails, so a clean period has no datapoint at all, and for
# M-of-N alarms CloudWatch skips missing periods and looks further back for
# N datapoints (treat_missing_data only applies when it can't find them).
# Without the fill, "4 of 4" meant any 4 error hours over a longer window:
# 7 C660 alarms in the first 4 days (2026-11-20..24), most with clean hours
# in between. With it, a clean period is a real 0 and breaks the streak.
# FILL of one metric is still one alarm metric, so the cost is unchanged.
locals {
  poller_error_alarm = {
    for name in local.tapo_camera_names : name => (
      contains(local.tapo_battery_camera_names, name)
      ? { period = 3600, periods = 4, window = "every hour for 4 hours" }
      : { period = 1800, periods = 2, window = "for 1 hour" }
    )
  }
}

resource "aws_cloudwatch_metric_alarm" "poller_errors" {
  for_each = local.poller_error_alarm

  alarm_name        = "tapo-poller-errors-${each.key}"
  alarm_description = "${each.key} poller has reported errors ${each.value.window}: camera unreachable, auth or download failures"

  evaluation_periods  = each.value.periods
  datapoints_to_alarm = each.value.periods
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  # With the fill, data is only missing if the metric itself has no data in
  # the whole query window (poller down: the heartbeat alarms' job).
  treat_missing_data = "notBreaching"

  metric_query {
    id          = "errors_or_zero"
    expression  = "FILL(errors, 0)"
    label       = "PollCycleErrors, 0 when none reported"
    return_data = true
  }

  metric_query {
    id = "errors"
    metric {
      namespace   = "Tapo/Camera"
      metric_name = "PollCycleErrors"
      dimensions = {
        CameraName = each.key
      }
      stat   = "Sum"
      period = each.value.period
    }
  }

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
