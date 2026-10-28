output "apply_role_arn" {
  description = "Set as the AWS_ROLE_ARN GitHub secret (deploy.yml)"
  value       = aws_iam_role.github_actions.arn
}

output "plan_role_arn" {
  description = "Set as the AWS_PLAN_ROLE_ARN GitHub secret (ci.yml)"
  value       = aws_iam_role.github_actions_plan.arn
}

output "camera_control_role_arn" {
  description = "Set as the AWS_CAMERA_CONTROL_ROLE_ARN secret of the camera-control environment (camera-override.yml)"
  value       = aws_iam_role.github_actions_camera_control.arn
}
