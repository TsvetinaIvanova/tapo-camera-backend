# Dedicated IAM user for the local poller script (Raspberry Pi / VM).
# Scoped to upload-only access on the clips/ prefix of this one bucket —
# no read, no delete, no access to anything else in the account.

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

# ── Poller CloudWatch Logs permission ──────────────────────
# Scoped to only the tapo-poller log group — same least-privilege
# pattern as the PutObject-only S3 policy already on this user.
#
# NOTE: assumes your existing IAM user resource is named
# `aws_iam_user.poller` in iam.tf — adjust the reference below if
# it's actually named something else there.

resource "aws_iam_policy" "poller_logs" {
  name = "tapo-poller-cloudwatch-logs"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "ShipPollerLogs"
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
      ]
      Resource = "arn:aws:logs:${var.aws_region}:*:log-group:tapo-poller:*"
    }]
  })
}

resource "aws_iam_user_policy_attachment" "poller_logs" {
  user       = aws_iam_user.poller.name
  policy_arn = aws_iam_policy.poller_logs.arn
}
resource "aws_iam_access_key" "poller" {
  user = aws_iam_user.poller.name
}
