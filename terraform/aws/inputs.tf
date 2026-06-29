module "inputs" {
  source = "./modules/inputs"

  bucket_name = local.terraform_state_bucket_name

  repos = [
    "aws"
  ]
}

locals {
  inputs = module.inputs.data

  kms_key_arn = local.inputs.aws.kms_key_arn
}
