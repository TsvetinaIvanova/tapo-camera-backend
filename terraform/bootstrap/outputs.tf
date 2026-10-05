output "apply_role_arn" {
  description = "Set as the AWS_ROLE_ARN GitHub secret (deploy.yml)"
  value       = aws_iam_role.github_actions.arn
}

output "plan_role_arn" {
  description = "Set as the AWS_PLAN_ROLE_ARN GitHub secret (ci.yml)"
  value       = aws_iam_role.github_actions_plan.arn
}
