# ── Variables ─────────────────────────────────────────────
variable "alert_email" {
  description = "Email address to receive CloudWatch alarm notifications"
  type        = string
}

# ── SNS Topic ─────────────────────────────────────────────
resource "aws_sns_topic" "alerts" {
  name = "tapo-camera-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ── Metric filter ──────────────────────────────────────────
# Counts successful clip uploads by looking for the log line
# the processor Lambda emits after a successful DynamoDB write.
resource "aws_cloudwatch_log_metric_filter" "clip_processed" {
  name           = "tapo-clip-processed"
  log_group_name = "/aws/lambda/tapo-clip-processor"
  pattern        = "\"Metadata written for\""

  metric_transformation {
    name          = "ClipsProcessed"
    namespace     = "Tapo/Camera"
    value         = "1"
    default_value = "0"   # emit 0 when no log matches — essential for the alarm to fire
  }
}

# ── Alarm ─────────────────────────────────────────────────
# Fires when fewer than 1 clip has been processed in 60 minutes.
# Uses a single 60-minute evaluation period so the alarm fires
# as soon as one full hour passes with no uploads.
resource "aws_cloudwatch_metric_alarm" "no_uploads" {
  alarm_name          = "tapo-no-uploads-1h"
  alarm_description   = "No camera clips processed in the last 60 minutes — poller or pipeline may be down"
  namespace           = "Tapo/Camera"
  metric_name         = "ClipsProcessed"
  statistic           = "Sum"
  period              = 3600   # 1 hour window
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"   # no data = alarm, not OK

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]   # also notify when it recovers
}

# ── Lambda error alarm ─────────────────────────────────────
# Secondary alarm: alert if the processor Lambda itself starts erroring.
# This catches issues like IAM permission failures, DynamoDB throttling,
# or code errors that prevent metadata from being written.
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "tapo-processor-errors"
  alarm_description   = "tapo-clip-processor Lambda error rate elevated"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions = {
    FunctionName = "tapo-clip-processor"
  }
  statistic           = "Sum"
  period              = 300    # check every 5 minutes
  evaluation_periods  = 3      # alarm after 15 minutes of errors
  threshold           = 3
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# ── Poller heartbeat + error alarms ────────────────────────
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
# process crashed, thread hung, systemd service down, etc.
resource "aws_cloudwatch_metric_alarm" "poller_heartbeat" {
  for_each = toset(local.tapo_camera_names)

  alarm_name          = "tapo-poller-heartbeat-${each.value}"
  alarm_description   = "No poll cycle reported for ${each.value} in 30 minutes — poller thread may be dead or hung"
  namespace           = "Tapo/Camera"
  metric_name         = "PollCycleCompleted"
  dimensions = {
    CameraName = each.value
  }
  statistic           = "Sum"
  period              = 1800   # 30 minutes — a few missed cycles even
                                # on the slowest (night_mode) interval
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"   # no data = the thread stopped reporting = alarm

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# Fires if a camera's poll cycles are running but erroring — connection
# failures, auth failures, download failures — even if zero clips would
# have been expected anyway. This is the case that ClipsProcessed alone
# can't catch: the poller runs, logs errors, uploads nothing.
resource "aws_cloudwatch_metric_alarm" "poller_errors" {
  for_each = toset(local.tapo_camera_names)

  alarm_name          = "tapo-poller-errors-${each.value}"
  alarm_description   = "${each.value} poller is reporting errors — connection, auth, or download failures"
  namespace           = "Tapo/Camera"
  metric_name         = "PollCycleErrors"
  dimensions = {
    CameraName = each.value
  }
  statistic           = "Sum"
  period              = 1800
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"  # no errors reported = healthy, not alarming

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# ── Outputs ───────────────────────────────────────────────
output "sns_topic_arn" {
  description = "SNS topic ARN for camera alerts"
  value       = aws_sns_topic.alerts.arn
}
