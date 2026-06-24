data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  region                      = data.aws_region.current.region
  account_id                  = data.aws_caller_identity.current.account_id
  terraform_state_bucket_name = "${var.prefix_slug}-terraform-state"
}
