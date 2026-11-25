# ── Incident triage (alarm -> Bedrock model investigates -> e-mailed report) ──
#
# tapo-incident-triage is subscribed to the alerts topic. On each ALARM
# transition, a Bedrock model (Nova 2 Lite, EU inference profile) investigates
# with read-only tools and the report goes to a separate topic: publishing to
# the alerts topic would trigger the function again. Design and tradeoffs:
# docs/project-notes.md (agreed order, step 4).

locals {
  # Log groups the agent may query (Logs Insights), enforced in the handler
  # (tool allowlist) and in IAM (StartQuery on these ARNs only).
  triage_log_groups = [
    aws_cloudwatch_log_group.poller.name,
    module.processor.log_group_name,
    module.query.log_group_name,
    module.authorizer.log_group_name,
  ]

  triage_errors_alarm_name   = "tapo-incident-triage-errors"
  poller_override_ssm_prefix = "/tapo/poller/override/" # written by camera-override.yml

  # The EU inference profile and the foundation model it routes to (in any
  # EU region: Bedrock picks one per request). InvokeModel is checked on both.
  triage_profile_arn     = "arn:aws:bedrock:${var.aws_region}:${data.aws_caller_identity.current.account_id}:inference-profile/${var.triage_model_id}"
  triage_foundation_arns = "arn:aws:bedrock:eu-*::foundation-model/${trimprefix(var.triage_model_id, "eu.")}"
}

# ── Report topic ────────────────────────────────────────────

resource "aws_sns_topic" "incident_reports" {
  name = "tapo-incident-reports"
}

# A new subscription: AWS sends a confirmation e-mail, which must be
# clicked (check spam: an unconfirmed subscription once looked like an
# alarm that never fired).
resource "aws_sns_topic_subscription" "incident_reports_email" {
  topic_arn = aws_sns_topic.incident_reports.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ── Function ────────────────────────────────────────────────

# Single-file zip: Bedrock is called through boto3 (Converse API), which the
# Lambda runtime already includes.
module "triage" {
  source = "./modules/lambda"

  permissions_boundary = local.workload_boundary_arn

  function_name = "tapo-incident-triage"
  source_file   = "${path.module}/lambda/triage/handler.py"

  # A run is ~3-8 model turns plus tool calls (a Logs Insights query can
  # wait up to 25 s); 5 minutes leaves room for a slow Bedrock response.
  timeout     = 300
  memory_size = 256

  environment = {
    MODEL_ID                  = var.triage_model_id
    REPORT_TOPIC_ARN          = aws_sns_topic.incident_reports.arn
    CLIPS_TABLE               = aws_dynamodb_table.camera_clips.name
    CAMERAS                   = jsonencode(local.tapo_camera_names)
    LOG_GROUPS                = jsonencode(local.triage_log_groups)
    OVERRIDE_PARAMETER_PREFIX = local.poller_override_ssm_prefix
    ALARM_PREFIX              = "tapo-"
    SKIP_ALARMS               = jsonencode([local.triage_errors_alarm_name])
    MAX_TURNS                 = "12"
  }
}

# No async retries: a retry would re-run the whole investigation (tokens)
# and send a second report. A failed run already e-mails a failure notice.
resource "aws_lambda_function_event_invoke_config" "triage" {
  function_name          = module.triage.function_name
  maximum_retry_attempts = 0
}

# ── Trigger: alarm notifications ────────────────────────────

resource "aws_sns_topic_subscription" "alerts_to_triage" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "lambda"
  endpoint  = module.triage.arn
}

resource "aws_lambda_permission" "allow_alerts_sns" {
  statement_id  = "AllowAlertsTopicInvoke"
  action        = "lambda:InvokeFunction"
  function_name = module.triage.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.alerts.arn
}

# ── IAM (beyond logging, which the module provides) ─────────

resource "aws_iam_role_policy" "triage" {
  name = "tapo-incident-triage"
  role = module.triage.role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Through the EU profile only (Converse authorizes as InvokeModel).
        Sid      = "InvokeModelViaEuProfile"
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel"]
        Resource = local.triage_profile_arn
      },
      {
        # The profile routes each request to the model in one EU region; that
        # call is authorized on the foundation model too. The condition
        # allows it only as part of a call through the profile, never a
        # direct call to the model.
        Sid      = "InvokeFoundationModelViaEuProfile"
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel"]
        Resource = local.triage_foundation_arns
        Condition = {
          StringEquals = { "bedrock:InferenceProfileArn" = local.triage_profile_arn }
        }
      },
      {
        # GetMetricStatistics has no resource-level permissions. The handler
        # limits it to the Tapo/Camera, AWS/Lambda and AWS/Logs namespaces.
        Sid      = "ReadMetrics"
        Effect   = "Allow"
        Action   = ["cloudwatch:GetMetricStatistics"]
        Resource = "*"
      },
      {
        Sid      = "ReadAlarms"
        Effect   = "Allow"
        Action   = ["cloudwatch:DescribeAlarmHistory"]
        Resource = "arn:aws:cloudwatch:${var.aws_region}:${data.aws_caller_identity.current.account_id}:alarm:tapo-*"
      },
      {
        # DescribeAlarms with a name prefix is authorized against alarm:*, not
        # each alarm's ARN, so tapo-* denied it (the first triage run's list_alarms
        # failed). Alarm configurations aren't sensitive; the triage tool still
        # lists only tapo-* alarms.
        Sid      = "ReadAlarmsList"
        Effect   = "Allow"
        Action   = ["cloudwatch:DescribeAlarms"]
        Resource = "arn:aws:cloudwatch:${var.aws_region}:${data.aws_caller_identity.current.account_id}:alarm:*"
      },
      {
        Sid    = "QueryProjectLogs"
        Effect = "Allow"
        Action = ["logs:StartQuery"]
        Resource = flatten([
          for name in local.triage_log_groups : [
            "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:${name}",
            "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:${name}:*",
          ]
        ])
      },
      {
        # Query IDs aren't resources: these can't be scoped further.
        Sid      = "ReadQueryResults"
        Effect   = "Allow"
        Action   = ["logs:GetQueryResults", "logs:StopQuery"]
        Resource = "*"
      },
      {
        # The overrides only: not the API secret, which is also under /tapo/.
        Sid      = "ReadPollingOverrides"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${local.poller_override_ssm_prefix}*"
      },
      {
        Sid      = "ReadRecentClips"
        Effect   = "Allow"
        Action   = ["dynamodb:Query"]
        Resource = aws_dynamodb_table.camera_clips.arn
      },
      {
        Sid      = "PublishReports"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.incident_reports.arn
      },
    ]
  })
}

# ── Its own alarm ───────────────────────────────────────────

# A best-effort feature that fails silently needs its own alarm (see the
# poller log-shipping incident). A failed run normally e-mails a failure
# notice first; this catches the runs that can't (crash, timeout, SNS
# down). It notifies the alerts topic like every alarm, so the handler
# skips it by name rather than triaging its own failure. One alarm metric.
resource "aws_cloudwatch_metric_alarm" "triage_errors" {
  alarm_name        = local.triage_errors_alarm_name
  alarm_description = "tapo-incident-triage failed: an alarm was not triaged (check its log group)"
  namespace         = "AWS/Lambda"
  metric_name       = "Errors"
  dimensions = {
    FunctionName = module.triage.function_name
  }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching" # it runs only on alarms; no data is normal

  alarm_actions = [aws_sns_topic.alerts.arn]
}
