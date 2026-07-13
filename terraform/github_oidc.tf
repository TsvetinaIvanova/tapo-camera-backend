# ── GitHub OIDC provider ──────────────────────────────────
resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]

  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# ── IAM role for GitHub Actions ───────────────────────────
resource "aws_iam_role" "github_actions" {
  name = "tapo-github-actions"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:TsvetinaIvanova/tapo-camera-backend:*"
        }
      }
    }]
  })
}

# ── Permissions for the GitHub Actions role ───────────────

# S3 state bucket access
resource "aws_iam_role_policy" "github_actions_state" {
  name = "tapo-github-actions-state"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "StateAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
        ]
        Resource = [
          "arn:aws:s3:::your-name-tapo-tf-state",
          "arn:aws:s3:::your-name-tapo-tf-state/*",
        ]
      },
      {
        Sid    = "StateLock"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:DeleteItem",
        ]
        Resource = "arn:aws:dynamodb:eu-central-1:*:table/tapo-tf-state-lock"
      }
    ]
  })
}

# Terraform needs to read/write all the resources it manages
resource "aws_iam_role_policy" "github_actions_deploy" {
  name = "tapo-github-actions-deploy"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "LambdaUpdate"
        Effect = "Allow"
        Action = [
          "lambda:Get*",
          "lambda:List*",
          "lambda:UpdateFunctionCode",
          "lambda:UpdateFunctionConfiguration",
          "lambda:GetFunction",
          "lambda:GetFunctionConfiguration",
          "lambda:PublishVersion",
          "lambda:CreateFunction",
          "lambda:DeleteFunction",
          "lambda:AddPermission",
          "lambda:RemovePermission",
          "lambda:GetPolicy",
          "lambda:ListVersionsByFunction",
        ]
        Resource = "arn:aws:lambda:eu-central-1:*:function:tapo-*"
      },
      {
        Sid    = "IAMRead"
        Effect = "Allow"
        Action = [
          # Roles
          "iam:GetRole",
          "iam:GetRolePolicy",
          "iam:ListRolePolicies",
          "iam:ListAttachedRolePolicies",
          "iam:ListInstanceProfilesForRole",
          "iam:PassRole",
          # Users
          "iam:GetUser",
          "iam:GetUserPolicy",
          "iam:ListUserPolicies",
          "iam:ListAttachedUserPolicies",
          "iam:ListAccessKeys",
          "iam:ListGroupsForUser",
          # Policies
          "iam:GetPolicy",
          "iam:GetPolicyVersion",
          "iam:ListPolicies",
          "iam:ListPolicyVersions",
          "iam:ListEntitiesForPolicy",
          # OIDC
          "iam:GetOpenIDConnectProvider",
          "iam:ListOpenIDConnectProviders",
          # Tags
          "iam:ListRoleTags",
          "iam:ListUserTags",
          "iam:ListPolicyTags",
        ]
        Resource = "*"
      },
      {
        Sid    = "S3BucketManage"
        Effect = "Allow"
        Action = [
          "s3:Get*",
          "s3:List*",
          "s3:CreateBucket",
          "s3:DeleteBucket",
          "s3:GetBucketPolicy",
          "s3:PutBucketPolicy",
          "s3:DeleteBucketPolicy",
          "s3:GetBucketVersioning",
          "s3:PutBucketVersioning",
          "s3:GetBucketPublicAccessBlock",
          "s3:PutBucketPublicAccessBlock",
          "s3:GetEncryptionConfiguration",
          "s3:PutEncryptionConfiguration",
          "s3:GetLifecycleConfiguration",
          "s3:PutLifecycleConfiguration",
          "s3:DeleteLifecycleConfiguration",
          "s3:GetBucketNotification",
          "s3:PutBucketNotification",
          "s3:PutBucketWebsite",
          "s3:DeleteBucketWebsite",
          #"s3:GetBucketAcl",
          "s3:PutBucketAcl",
          #"s3:GetBucketCORS",
          "s3:PutBucketCORS",
          #"s3:GetAccelerateConfiguration",
          "s3:PutAccelerateConfiguration",
          #"s3:GetBucketObjectLockConfiguration",
          #"s3:GetBucketRequestPayment",
          #"s3:GetBucketTagging",
          "s3:PutBucketTagging",
          #"s3:GetBucketLogging",
          #"s3:GetBucketOwnershipControls",
          "s3:PutBucketOwnershipControls",
          #"s3:GetBucketReplicationConfiguration",
          "s3:PutBucketReplicationConfiguration",
          #"s3:GetBucketReplication",
          "s3:PutBucketReplication",
          "s3:ListBucket",
          "s3:PutObject",
          #"s3:GetObject",
          "s3:DeleteObject",
        ]
        Resource = [
          "arn:aws:s3:::*tapo*",
          "arn:aws:s3:::*tapo*/*",
        ]
      },
      {
        Sid    = "DynamoDBManage"
        Effect = "Allow"
        Action = [
          "dynamodb:List*",
          "dynamodb:CreateTable",
          "dynamodb:DeleteTable",
          "dynamodb:DescribeTable",
          "dynamodb:DescribeTimeToLive",
          "dynamodb:UpdateTimeToLive",
          "dynamodb:DescribeContinuousBackups",
          "dynamodb:ListTagsOfResource",
          "dynamodb:TagResource",
          "dynamodb:UntagResource",
          "dynamodb:UpdateTable",
        ]
        Resource = "arn:aws:dynamodb:eu-central-1:*:table/tapo-*"
      },
      {
        Sid    = "APIGatewayManage"
        Effect = "Allow"
        Action = ["apigateway:*"]
        Resource = "*"
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:DeleteLogGroup",
          "logs:DescribeLogGroups",
          "logs:ListTagsLogGroup",
          "logs:PutRetentionPolicy",
          "logs:DeleteRetentionPolicy",
          "logs:TagResource",
          "logs:UntagResource",
          "logs:ListTagsForResource",
        ]
        Resource = "*"
      }
    ]
  })
}

output "github_actions_role_arn" {
  description = "IAM role ARN to use in GitHub Actions workflows"
  value       = aws_iam_role.github_actions.arn
}