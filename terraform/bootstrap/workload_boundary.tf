# ── Permissions boundary for the main stack's IAM identities ──
#
# The ceiling on what any role or user that CI creates or edits may ever do:
# the Lambda roles (modules/lambda) and the poller user. The apply role may
# only create or grant permissions to identities that carry this boundary
# (github_oidc.tf, IAMBoundedWrites), and may not remove it or edit this
# policy. Without it, the apply role could put an admin policy on the poller
# user, create a key for it, and use that key: an escalation to admin.
#
# Effective permissions = identity policies ∩ this boundary, so this lists
# what the workloads could plausibly need, scoped to this project's
# resources, not each function's exact grants (those stay least-privilege in
# the main stack). A new AWS service for a workload (e.g. Rekognition) needs
# a statement here first, applied locally, before the main stack can use it.
# Lives in bootstrap, applied by an admin, so CI can never raise its own
# ceiling.
resource "aws_iam_policy" "workload_boundary" {
  name        = "tapo-workload-boundary"
  description = "Permissions boundary for the Tapo Lambda roles and the poller user"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ClipsObjects"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = "arn:aws:s3:::${var.bucket_name}/*"
      },
      {
        Sid      = "ClipsList"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::${var.bucket_name}"
      },
      {
        Sid    = "ClipsTable"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:BatchGetItem",
          "dynamodb:Query",
          "dynamodb:Scan",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
        ]
        Resource = [
          "arn:aws:dynamodb:${local.region}:${local.account_id}:table/tapo-*",
          "arn:aws:dynamodb:${local.region}:${local.account_id}:table/tapo-*/index/*",
        ]
      },
      {
        Sid      = "ProjectParameters"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = "arn:aws:ssm:${local.region}:${local.account_id}:parameter/tapo/*"
      },
      {
        Sid    = "OwnLogGroups"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = [
          "arn:aws:logs:${local.region}:${local.account_id}:log-group:tapo-*",
          "arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/tapo-*",
        ]
      },
      {
        Sid      = "ProjectMetrics"
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
        Condition = {
          StringEquals = { "cloudwatch:namespace" = "Tapo/Camera" }
        }
      },
      # ── Incident triage (read-only investigation + report) ──
      {
        # Metric reads have no resource-level permissions.
        Sid      = "ReadMetrics"
        Effect   = "Allow"
        Action   = ["cloudwatch:GetMetricStatistics", "cloudwatch:GetMetricData"]
        Resource = "*"
      },
      {
        Sid      = "ReadProjectAlarms"
        Effect   = "Allow"
        Action   = ["cloudwatch:DescribeAlarmHistory"]
        Resource = "arn:aws:cloudwatch:${local.region}:${local.account_id}:alarm:tapo-*"
      },
      {
        # DescribeAlarms with a name prefix is authorized against alarm:*, not
        # each alarm's ARN, so tapo-* denied it (the first triage run's list_alarms
        # failed). Alarm configurations aren't sensitive; the triage tool still
        # lists only tapo-* alarms.
        Sid      = "ReadProjectAlarmsList"
        Effect   = "Allow"
        Action   = ["cloudwatch:DescribeAlarms"]
        Resource = "arn:aws:cloudwatch:${local.region}:${local.account_id}:alarm:*"
      },
      {
        Sid    = "QueryProjectLogs"
        Effect = "Allow"
        Action = ["logs:StartQuery"]
        Resource = [
          "arn:aws:logs:${local.region}:${local.account_id}:log-group:tapo-*",
          "arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/tapo-*",
        ]
      },
      {
        # Query IDs aren't IAM resources.
        Sid      = "ReadLogQueryResults"
        Effect   = "Allow"
        Action   = ["logs:GetQueryResults", "logs:StopQuery"]
        Resource = "*"
      },
      {
        Sid      = "PublishProjectTopics"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = "arn:aws:sns:${local.region}:${local.account_id}:tapo-*"
      },
      {
        # Bedrock models through EU inference profiles only (requests stay in
        # the EU). Any model: the main stack names the one each function uses.
        Sid      = "InvokeModelsViaEuProfiles"
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel"]
        Resource = "arn:aws:bedrock:${local.region}:${local.account_id}:inference-profile/eu.*"
      },
      {
        # The routed call to the model in whichever EU region serves it, and
        # only as part of an EU-profile call (no direct model calls).
        Sid      = "InvokeFoundationModelsViaEuProfiles"
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel"]
        Resource = "arn:aws:bedrock:eu-*::foundation-model/*"
        Condition = {
          ArnLike = { "bedrock:InferenceProfileArn" = "arn:aws:bedrock:${local.region}:${local.account_id}:inference-profile/eu.*" }
        }
      },
    ]
  })
}
