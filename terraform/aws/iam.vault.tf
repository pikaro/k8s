data "aws_iam_policy_document" "vault_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.k8s.arn]
    }

    actions = ["sts:AssumeRoleWithWebIdentity"]

    condition {
      test     = "StringEquals"
      variable = local.oidc_sub_claim

      values = [
        "system:serviceaccount:vault:vault",
      ]
    }
  }

  lifecycle {
    enabled = var.enable_oidc_roles
  }
}

resource "aws_iam_role" "vault" {
  name               = "vault"
  assume_role_policy = data.aws_iam_policy_document.vault_assume_role.json

  lifecycle {
    enabled = var.enable_oidc_roles
  }
}

data "aws_iam_policy_document" "vault" {
  statement {
    effect = "Allow"

    actions = [
      "kms:Decrypt",
      "kms:Encrypt",
      "kms:DescribeKey",
    ]

    resources = [
      local.kms_key_arn
    ]
  }
}

resource "aws_iam_policy" "vault" {
  name        = "VaultPolicy"
  description = "Policy to allow Vault to access KMS key for auto-unseal"
  policy      = data.aws_iam_policy_document.vault.json
}

resource "aws_iam_role_policy_attachment" "vault" {
  role       = aws_iam_role.vault.name
  policy_arn = aws_iam_policy.vault.arn

  lifecycle {
    enabled = var.enable_oidc_roles
  }
}
