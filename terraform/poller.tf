# ── Poller IAM user (Raspberry Pi) ──────────────────────────

# Dedicated IAM user for the poller on the Raspberry Pi. Long-lived key by
# design (see docs/project-notes.md). Least privilege: PutObject and a
# prefix-scoped ListBucket on clips/ of this one bucket, PutMetricData in
# the Tapo/Camera namespace, and log writes to the tapo-poller log group.
# No GetObject, no delete, nothing else in the account.
resource "aws_iam_user" "poller" {
  name = var.poller_user_name
}

resource "aws_iam_policy" "poller_upload" {
  name        = "${var.poller_user_name}-upload-policy"
  description = "Least-privilege upload access for the Tapo camera poller"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowPutObjectOnClipsPrefix"
        Effect = "Allow"
        Action = [
          "s3:PutObject"
        ]
        Resource = "${aws_s3_bucket.camera_clips.arn}/clips/*"
      },
      {
        Sid    = "AllowListBucketScopedToClipsPrefix"
        Effect = "Allow"
        Action = [
          "s3:ListBucket"
        ]
        Resource = aws_s3_bucket.camera_clips.arn
        Condition = {
          StringLike = {
            "s3:prefix" = "clips/*"
          }
        }
      },
      {
        Sid    = "AllowPutMetricDataForPollerMetrics"
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "cloudwatch:namespace" = "Tapo/Camera"
          }
        }
      }
    ]
  })
}

resource "aws_iam_user_policy_attachment" "poller_upload" {
  user       = aws_iam_user.poller.name
  policy_arn = aws_iam_policy.poller_upload.arn
}

# The poller's log group. It was originally created by the poller itself
# (watchtower, create_log_group=True), with its retention set by hand.
# Imported so Terraform owns both, and so the IAM policy below can be
# scoped to its ARN.
import {
  to = aws_cloudwatch_log_group.poller
  id = "tapo-poller"
}

resource "aws_cloudwatch_log_group" "poller" {
  name              = "tapo-poller"
  retention_in_days = 14
}

# Scoped to only the poller's log group — same least-privilege pattern as
# the PutObject-only S3 policy already on this user.
resource "aws_iam_policy" "poller_logs" {
  name = "tapo-poller-cloudwatch-logs"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ShipPollerLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "${aws_cloudwatch_log_group.poller.arn}:*"
      },
      {
        # Only because the deployed poller still calls CreateLogGroup at
        # startup (the group exists, so the call is a no-op). Without it,
        # watchtower fails and log shipping is silently disabled. Remove once
        # the poller runs with create_log_group=False.
        Sid      = "PollerStartupCreateLogGroup"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup"]
        Resource = aws_cloudwatch_log_group.poller.arn
      },
    ]
  })
}

resource "aws_iam_user_policy_attachment" "poller_logs" {
  user       = aws_iam_user.poller.name
  policy_arn = aws_iam_policy.poller_logs.arn
}

resource "aws_iam_access_key" "poller" {
  user = aws_iam_user.poller.name
}

# Read-only access to the per-camera polling overrides that
# camera-override.yml writes (pause, or poll even while auto-paused).
# The parameters are runtime state, not Terraform resources: Terraform only
# grants access to the path. Inline, since it is 1:1 with this user (see
# the IAM policies decision in docs/project-notes.md).
resource "aws_iam_user_policy" "poller_overrides" {
  name = "tapo-poller-read-overrides"
  user = aws_iam_user.poller.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadPollingOverrides"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/tapo/poller/override/*"
      }
    ]
  })
}
