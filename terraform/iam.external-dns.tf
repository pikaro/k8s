resource "aws_iam_user" "external_dns" {
  name = "external-dns"

  lifecycle {
    enabled = var.enable_iam_users
  }
}

data "aws_iam_policy_document" "external_dns_assume_role" {
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
        "system:serviceaccount:external-dns:external-dns",
      ]
    }
  }

  lifecycle {
    enabled = var.enable_oidc_roles
  }
}

resource "aws_dynamodb_table" "external_dns_registry" {
  name         = "external-dns"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "k"

  attribute {
    name = "k"
    type = "S"
  }
}

data "aws_iam_policy_document" "external_dns_route53" {
  statement {
    sid    = "DenyNestedRootZoneNames"
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
        "*.*.${local.root_domain}",
      ]
    }
  }

  statement {
    sid    = "DenyNonCnameRootRecords"
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
        "CNAME",
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
    sid    = "ManageRootServiceCnames"
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
        "CNAME",
      ]
    }

    condition {
      test     = "ForAllValues:StringLike"
      variable = "route53:ChangeResourceRecordSetsNormalizedRecordNames"

      values = [
        "*.${local.root_domain}",
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

resource "aws_iam_role" "external_dns" {
  name               = "external-dns"
  assume_role_policy = data.aws_iam_policy_document.external_dns_assume_role.json

  lifecycle {
    enabled = var.enable_oidc_roles
  }
}

data "aws_iam_policy_document" "external_dns_registry" {
  statement {
    sid    = "ManageDynamoDbRegistry"
    effect = "Allow"

    actions = [
      "dynamodb:DescribeTable",
      "dynamodb:PartiQLDelete",
      "dynamodb:PartiQLInsert",
      "dynamodb:PartiQLUpdate",
      "dynamodb:Scan",
    ]

    resources = [
      aws_dynamodb_table.external_dns_registry.arn,
    ]
  }
}

resource "aws_iam_policy" "external_dns_route53" {
  name        = "ExternalDNSRoute53Policy"
  description = "Allow external-dns to manage cluster DNS records"
  policy      = data.aws_iam_policy_document.external_dns_route53.json
}

resource "aws_iam_policy" "external_dns_registry" {
  name        = "ExternalDNSRegistryPolicy"
  description = "Allow external-dns to manage its DynamoDB registry"
  policy      = data.aws_iam_policy_document.external_dns_registry.json
}

resource "aws_iam_role_policy_attachment" "external_dns_route53" {
  role       = aws_iam_role.external_dns.name
  policy_arn = aws_iam_policy.external_dns_route53.arn

  lifecycle {
    enabled = var.enable_oidc_roles
  }
}

resource "aws_iam_role_policy_attachment" "external_dns_registry" {
  role       = aws_iam_role.external_dns.name
  policy_arn = aws_iam_policy.external_dns_registry.arn

  lifecycle {
    enabled = var.enable_oidc_roles
  }
}

resource "aws_iam_user_policy_attachment" "external_dns_route53" {
  user       = aws_iam_user.external_dns.name
  policy_arn = aws_iam_policy.external_dns_route53.arn

  lifecycle {
    enabled = var.enable_iam_users
  }
}

resource "aws_iam_user_policy_attachment" "external_dns_registry" {
  user       = aws_iam_user.external_dns.name
  policy_arn = aws_iam_policy.external_dns_registry.arn

  lifecycle {
    enabled = var.enable_iam_users
  }
}

resource "aws_iam_access_key" "external_dns" {
  user    = aws_iam_user.external_dns.name
  pgp_key = local.inputs.aws.pgp_key

  lifecycle {
    enabled = var.enable_iam_users
  }
}

output "external_dns_access_key" {
  value = {
    id  = try(aws_iam_access_key.external_dns.id, null)
    key = try(aws_iam_access_key.external_dns.encrypted_secret, null)
  }
}

output "external_dns_role_arn" {
  value = try(aws_iam_role.external_dns.arn, null)
}
