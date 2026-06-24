resource "aws_iam_user" "cert_manager" {
  name = "cert-manager"

  lifecycle {
    enabled = var.enable_iam_users
  }
}

data "aws_iam_policy_document" "cert_manager_assume_role" {
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
        "system:serviceaccount:cert-manager:cert-manager",
      ]
    }
  }

  lifecycle {
    enabled = var.enable_oidc_roles
  }
}

data "aws_iam_policy_document" "cert_manager_route53" {
  statement {
    sid    = "DenyNestedRootAcmeNames"
    effect = "Deny"

    actions = [
      "route53:ChangeResourceRecordSets",
    ]

    resources = [
      data.aws_route53_zone.root.arn,
    ]

    condition {
      test     = "ForAnyValue:StringLike"
      variable = "route53:ChangeResourceRecordSetsNormalizedRecordNames"

      values = [
        "_acme-challenge.*.*.${local.root_domain}",
      ]
    }
  }

  statement {
    sid    = "DenyUnexpectedRootZoneNames"
    effect = "Deny"

    actions = [
      "route53:ChangeResourceRecordSets",
    ]

    resources = [
      data.aws_route53_zone.root.arn,
    ]

    condition {
      test     = "ForAnyValue:StringNotLike"
      variable = "route53:ChangeResourceRecordSetsNormalizedRecordNames"

      values = [
        "_acme-challenge.${local.root_domain}",
        "_acme-challenge.*.${local.root_domain}",
      ]
    }
  }

  statement {
    sid    = "DenyNonTxtRootRecords"
    effect = "Deny"

    actions = [
      "route53:ChangeResourceRecordSets",
    ]

    resources = [
      data.aws_route53_zone.root.arn,
    ]

    condition {
      test     = "ForAnyValue:StringNotEquals"
      variable = "route53:ChangeResourceRecordSetsRecordTypes"

      values = [
        "TXT",
      ]
    }
  }

  statement {
    sid    = "ListHostedZones"
    effect = "Allow"

    actions = [
      "route53:ListHostedZones",
      "route53:ListHostedZonesByName",
    ]

    resources = ["*"]
  }

  statement {
    sid    = "ReadDnsZones"
    effect = "Allow"

    actions = [
      "route53:ListResourceRecordSets",
    ]

    resources = [
      data.aws_route53_zone.root.arn,
      data.aws_route53_zone.k8s.arn,
    ]
  }

  statement {
    sid    = "GetDnsChangeStatus"
    effect = "Allow"

    actions = [
      "route53:GetChange",
    ]

    resources = [
      "arn:aws:route53:::change/*",
    ]
  }

  statement {
    sid    = "ManageRootAcmeTxtRecords"
    effect = "Allow"

    actions = [
      "route53:ChangeResourceRecordSets",
    ]

    resources = [
      data.aws_route53_zone.root.arn,
    ]

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "route53:ChangeResourceRecordSetsActions"

      values = [
        "CREATE",
        "DELETE",
        "UPSERT",
      ]
    }

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "route53:ChangeResourceRecordSetsRecordTypes"

      values = [
        "TXT",
      ]
    }

    condition {
      test     = "ForAllValues:StringLike"
      variable = "route53:ChangeResourceRecordSetsNormalizedRecordNames"

      values = [
        "_acme-challenge.${local.root_domain}",
        "_acme-challenge.*.${local.root_domain}",
      ]
    }
  }

  statement {
    sid    = "ManageK8sZoneRecords"
    effect = "Allow"

    actions = [
      "route53:ChangeResourceRecordSets",
    ]

    resources = [
      data.aws_route53_zone.k8s.arn,
    ]
  }
}

resource "aws_iam_role" "cert_manager" {
  name               = "cert-manager"
  assume_role_policy = data.aws_iam_policy_document.cert_manager_assume_role.json

  lifecycle {
    enabled = var.enable_oidc_roles
  }
}

resource "aws_iam_policy" "cert_manager_route53" {
  name        = "CertManagerRoute53Policy"
  description = "Allow cert-manager to solve DNS01 challenges"
  policy      = data.aws_iam_policy_document.cert_manager_route53.json
}

resource "aws_iam_role_policy_attachment" "cert_manager_route53" {
  role       = aws_iam_role.cert_manager.name
  policy_arn = aws_iam_policy.cert_manager_route53.arn

  lifecycle {
    enabled = var.enable_oidc_roles
  }
}

resource "aws_iam_user_policy_attachment" "cert_manager_route53" {
  user       = aws_iam_user.cert_manager.name
  policy_arn = aws_iam_policy.cert_manager_route53.arn

  lifecycle {
    enabled = var.enable_iam_users
  }
}

resource "aws_iam_access_key" "cert_manager" {
  user    = aws_iam_user.cert_manager.name
  pgp_key = local.inputs.aws.pgp_key

  lifecycle {
    enabled = var.enable_iam_users
  }
}

output "cert_manager_access_key" {
  value = {
    id  = try(aws_iam_access_key.cert_manager.id, null)
    key = try(aws_iam_access_key.cert_manager.encrypted_secret, null)
  }
}

output "cert_manager_role_arn" {
  value = try(aws_iam_role.cert_manager.arn, null)
}
