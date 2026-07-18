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

# ── Outputs ───────────────────────────────────────────────
output "sns_topic_arn" {
  description = "SNS topic ARN for camera alerts"
  value       = aws_sns_topic.alerts.arn
}
