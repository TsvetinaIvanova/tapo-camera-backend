# ── Adopt resources previously managed by the main stack ──
import {
  to = aws_iam_openid_connect_provider.github
  id = "arn:aws:iam::${local.account_id}:oidc-provider/token.actions.githubusercontent.com"
}

import {
  to = aws_iam_role.github_actions
  id = "tapo-github-actions"
}

import {
  to = aws_iam_role_policy.github_actions_state
  id = "tapo-github-actions:tapo-github-actions-state"
}

import {
  to = aws_iam_role_policy.github_actions_deploy
  id = "tapo-github-actions:tapo-github-actions-deploy"
}

# ── GitHub OIDC provider ──────────────────────────────────
resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]

  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

locals {
  # OIDC "sub" claims GitHub issues for this repo
  sub_main = "repo:${var.github_repo}:ref:refs/heads/main"
  sub_pr   = "repo:${var.github_repo}:pull_request"

  main_state_arn = "arn:aws:s3:::${var.state_bucket}/${local.main_state_key}"
}

# ── Apply role: push to main only (deploy.yml) ────────────
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
          "token.actions.githubusercontent.com:sub" = local.sub_main
        }
      }
    }]
  })
}

# ── Plan role: PRs and main (ci.yml), read-only ───────────
resource "aws_iam_role" "github_actions_plan" {
  name = "tapo-github-actions-plan"

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
          "token.actions.githubusercontent.com:sub" = [local.sub_main, local.sub_pr]
        }
      }
    }]
  })
}

# Plan has to read every managed resource, including the SSM secret and
# state contents, so a narrower managed policy (e.g. ViewOnlyAccess) won't do.
resource "aws_iam_role_policy_attachment" "github_actions_plan_readonly" {
  role       = aws_iam_role.github_actions_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# Plan takes the state lock, which is an object next to the state file
resource "aws_iam_role_policy" "github_actions_plan_lock" {
  name = "tapo-github-actions-plan-lock"
  role = aws_iam_role.github_actions_plan.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "StateLock"
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:DeleteObject"]
      Resource = "${local.main_state_arn}.tflock"
    }]
  })
}

# ── Apply role permissions ────────────────────────────────

# Main stack state only — the bootstrap state is off limits
resource "aws_iam_role_policy" "github_actions_state" {
  name = "tapo-github-actions-state"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "StateList"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = "arn:aws:s3:::${var.state_bucket}"
      },
      {
        Sid    = "StateAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
        ]
        Resource = [
          local.main_state_arn,
          "${local.main_state_arn}.tflock",
        ]
      }
    ]
  })
}

# Everything the main stack manages, scoped to its resource names
resource "aws_iam_role_policy" "github_actions_deploy" {
  name = "tapo-github-actions-deploy"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3Buckets"
        Effect = "Allow"
        Action = "s3:*"
        Resource = [
          "arn:aws:s3:::${var.bucket_name}",
          "arn:aws:s3:::${var.bucket_name}/*",
          "arn:aws:s3:::${var.bucket_name}-frontend",
          "arn:aws:s3:::${var.bucket_name}-frontend/*",
        ]
      },
      {
        Sid    = "DynamoDB"
        Effect = "Allow"
        Action = "dynamodb:*"
        Resource = [
          "arn:aws:dynamodb:${local.region}:${local.account_id}:table/tapo-camera-clips",
          "arn:aws:dynamodb:${local.region}:${local.account_id}:table/tapo-camera-clips/index/*",
        ]
      },
      {
        Sid      = "Lambda"
        Effect   = "Allow"
        Action   = "lambda:*"
        Resource = "arn:aws:lambda:${local.region}:${local.account_id}:function:tapo-*"
      },
      {
        # Attaching the public ffmpeg layer (another account) to a function
        Sid      = "LambdaLayers"
        Effect   = "Allow"
        Action   = "lambda:GetLayerVersion"
        Resource = "arn:aws:lambda:${local.region}:*:layer:*:*"
      },
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = "logs:*"
        Resource = "arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/tapo-*"
      },
      {
        Sid      = "Alarms"
        Effect   = "Allow"
        Action   = "cloudwatch:*"
        Resource = "arn:aws:cloudwatch:${local.region}:${local.account_id}:alarm:tapo-*"
      },
      {
        Sid      = "SNS"
        Effect   = "Allow"
        Action   = "sns:*"
        Resource = "arn:aws:sns:${local.region}:${local.account_id}:tapo-*"
      },
      {
        Sid    = "SSM"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter*",
          "ssm:PutParameter",
          "ssm:DeleteParameter",
          "ssm:AddTagsToResource",
          "ssm:RemoveTagsFromResource",
          "ssm:ListTagsForResource",
        ]
        Resource = "arn:aws:ssm:${local.region}:${local.account_id}:parameter/tapo/*"
      },
      {
        Sid    = "ApiGateway"
        Effect = "Allow"
        Action = "apigateway:*"
        Resource = [
          "arn:aws:apigateway:${local.region}::/apis",
          "arn:aws:apigateway:${local.region}::/apis/*",
          "arn:aws:apigateway:${local.region}::/tags/*",
        ]
      },
      {
        # Describe/list calls that don't support resource-level permissions
        Sid    = "DescribeOnly"
        Effect = "Allow"
        Action = [
          "logs:DescribeLogGroups",
          "logs:DescribeMetricFilters",
          "cloudwatch:DescribeAlarms",
          "ssm:DescribeParameters",
        ]
        Resource = "*"
      },
      {
        Sid    = "IAM"
        Effect = "Allow"
        Action = [
          "iam:Get*",
          "iam:List*",
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:UpdateRole",
          "iam:UpdateAssumeRolePolicy",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:PutRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:DetachRolePolicy",
          "iam:CreatePolicy",
          "iam:DeletePolicy",
          "iam:CreatePolicyVersion",
          "iam:DeletePolicyVersion",
          "iam:TagPolicy",
          "iam:UntagPolicy",
          "iam:CreateUser",
          "iam:DeleteUser",
          "iam:TagUser",
          "iam:UntagUser",
          "iam:DetachUserPolicy",
          "iam:CreateAccessKey",
          "iam:DeleteAccessKey",
        ]
        Resource = [
          "arn:aws:iam::${local.account_id}:role/tapo-*",
          "arn:aws:iam::${local.account_id}:user/${var.poller_user_name}",
          "arn:aws:iam::${local.account_id}:policy/tapo-*",
        ]
      },
      {
        # Only our own policies and Lambda's basic execution policy can be attached
        Sid    = "IAMAttach"
        Effect = "Allow"
        Action = [
          "iam:AttachRolePolicy",
          "iam:AttachUserPolicy",
        ]
        Resource = [
          "arn:aws:iam::${local.account_id}:role/tapo-*",
          "arn:aws:iam::${local.account_id}:user/${var.poller_user_name}",
        ]
        Condition = {
          ArnLike = {
            "iam:PolicyARN" = [
              "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
              "arn:aws:iam::${local.account_id}:policy/tapo-*",
            ]
          }
        }
      },
      {
        Sid      = "ReadOIDCProvider"
        Effect   = "Allow"
        Action   = "iam:GetOpenIDConnectProvider"
        Resource = aws_iam_openid_connect_provider.github.arn
      },
      {
        Sid      = "PassLambdaRoles"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = "arn:aws:iam::${local.account_id}:role/tapo-*"
        Condition = {
          StringEquals = { "iam:PassedToService" = "lambda.amazonaws.com" }
        }
      },
      {
        # The CI roles match tapo-* above; never let CI modify or pass them
        Sid       = "ProtectCIRoles"
        Effect    = "Deny"
        NotAction = ["iam:Get*", "iam:List*"]
        Resource  = "arn:aws:iam::${local.account_id}:role/tapo-github-actions*"
      }
    ]
  })
}
