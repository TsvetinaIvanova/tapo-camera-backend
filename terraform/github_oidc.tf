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
        Sid    = "TerraformAccess"
        Effect = "Allow"
        Action = [
          "s3:*",
          "dynamodb:*",
          "cloudwatch:*",
          "apigateway:*",
          "lambda:*",
          "sns:*",
          "logs:*",
          "ssm:GetParameter",
          "iam:Get*",
          "iam:List*",
          "iam:PassRole",
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:PutRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:CreatePolicy",
          "iam:DeletePolicy",
          "iam:CreatePolicyVersion",
          "iam:DeletePolicyVersion",
          "iam:CreateUser",
          "iam:DeleteUser",
          "iam:PutUserPolicy",
          "iam:DeleteUserPolicy",
          "iam:AttachUserPolicy",
          "iam:DetachUserPolicy",
          "iam:CreateAccessKey",
          "iam:DeleteAccessKey",
          "iam:CreateOpenIDConnectProvider",
          "iam:DeleteOpenIDConnectProvider",
          "iam:UpdateOpenIDConnectProvider",
          "iam:TagOpenIDConnectProvider"
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