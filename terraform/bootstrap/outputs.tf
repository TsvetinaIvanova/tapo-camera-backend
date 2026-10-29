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

output "image_pull_role_arn" {
  description = "Set as the AWS_IMAGE_PULL_ROLE_ARN GitHub secret (ci.yml, processor image job)"
  value       = aws_iam_role.github_actions_image_pull.arn
}

output "workload_boundary_arn" {
  description = "Permissions boundary the main stack sets on its roles and the poller user"
  value       = aws_iam_policy.workload_boundary.arn
}
