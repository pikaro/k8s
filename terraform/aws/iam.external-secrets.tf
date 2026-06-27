data "aws_iam_policy_document" "external_secrets_assume_role" {
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
        "system:serviceaccount:external-secrets:external-secrets",
      ]
    }
  }

  lifecycle {
    enabled = var.enable_oidc_roles
  }
}

resource "aws_iam_role" "external_secrets" {
  name               = "external-secrets"
  assume_role_policy = data.aws_iam_policy_document.external_secrets_assume_role.json

  lifecycle {
    enabled = var.enable_oidc_roles
  }
}

locals {
  external_secrets_ssm_arn_prefix = "arn:aws:ssm:${local.region}:${local.account_id}:parameter/${var.external_secrets_ssm_prefix}/*"
}

data "aws_iam_policy_document" "ssm_external_secrets" {
  statement {
    effect = "Allow"

    actions = [
      "ssm:GetParameters",
      "ssm:GetParameter",
    ]

    resources = [
      local.external_secrets_ssm_arn_prefix
    ]
  }

  statement {
    effect = "Allow"

    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:GenerateDataKey",
    ]

    resources = [
      local.inputs.aws.kms_key_arn
    ]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"

      values = [
        "ssm.${local.region}.amazonaws.com",
      ]
    }

    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:PARAMETER_ARN"
      values = [
        local.external_secrets_ssm_arn_prefix,
      ]
    }
  }
}

resource "aws_iam_policy" "ssm_external_secrets" {
  name        = "SSMExternalSecretsPolicy"
  description = "Policy to allow External Secrets to read from SSM Parameter Store"
  policy      = data.aws_iam_policy_document.ssm_external_secrets.json
}

resource "aws_iam_role_policy_attachment" "external_secrets_ssm" {
  role       = aws_iam_role.external_secrets.name
  policy_arn = aws_iam_policy.ssm_external_secrets.arn

  lifecycle {
    enabled = var.enable_oidc_roles
  }
}
