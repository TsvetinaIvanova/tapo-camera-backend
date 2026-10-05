# ── Moved to the bootstrap stack (./bootstrap) ────────────
# Drop these from this stack's state without destroying them.
# Safe to delete this file once an apply has run with it.

removed {
  from = aws_iam_openid_connect_provider.github
  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role.github_actions
  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role_policy.github_actions_state
  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role_policy.github_actions_deploy
  lifecycle {
    destroy = false
  }
}
