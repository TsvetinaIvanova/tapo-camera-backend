# ── State moves for the modules/lambda refactor ─────────────
# Each Lambda's role, basic-execution attachment, log group and function
# moved into module.<name>. These make the refactor a zero-change plan.
# Safe to delete once an apply has run with them.

moved {
  from = aws_iam_role.lambda_processor
  to   = module.processor.aws_iam_role.this
}

moved {
  from = aws_iam_role_policy_attachment.lambda_basic
  to   = module.processor.aws_iam_role_policy_attachment.basic_execution
}

moved {
  from = aws_cloudwatch_log_group.clip_processor
  to   = module.processor.aws_cloudwatch_log_group.this
}

moved {
  from = aws_lambda_function.clip_processor
  to   = module.processor.aws_lambda_function.this
}

moved {
  from = aws_iam_role.lambda_query
  to   = module.query.aws_iam_role.this
}

moved {
  from = aws_iam_role_policy_attachment.lambda_query_basic
  to   = module.query.aws_iam_role_policy_attachment.basic_execution
}

moved {
  from = aws_cloudwatch_log_group.clip_query
  to   = module.query.aws_cloudwatch_log_group.this
}

moved {
  from = aws_lambda_function.clip_query
  to   = module.query.aws_lambda_function.this
}

moved {
  from = aws_iam_role.lambda_authorizer
  to   = module.authorizer.aws_iam_role.this
}

moved {
  from = aws_iam_role_policy_attachment.lambda_authorizer_basic
  to   = module.authorizer.aws_iam_role_policy_attachment.basic_execution
}

moved {
  from = aws_cloudwatch_log_group.api_authorizer
  to   = module.authorizer.aws_cloudwatch_log_group.this
}

moved {
  from = aws_lambda_function.api_authorizer
  to   = module.authorizer.aws_lambda_function.this
}
