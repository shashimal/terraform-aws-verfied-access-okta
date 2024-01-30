locals {
  app_name   = "ava-okta-demo"
  app_domain = "hr.duleendra.com"

  azs              = ["ap-southeast-1a", "ap-southeast-1b"]
  cidr             = "20.0.0.0/16"
  private_subnets  = ["20.0.0.0/19", "20.0.32.0/19"]
  public_subnets   = ["20.0.64.0/19", "20.0.96.0/19"]
  database_subnets = ["20.0.128.0/19", "20.0.160.0/19"]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~>5.0"

  name = local.app_name
  cidr = local.cidr

  azs                                = local.azs
  private_subnets                    = local.private_subnets
  public_subnets                     = local.public_subnets
  database_subnets                   = local.database_subnets
  create_database_subnet_group       = true
  create_database_subnet_route_table = true

  enable_nat_gateway     = true
  single_nat_gateway     = true
  one_nat_gateway_per_az = false

  enable_dns_hostnames = true
  enable_dns_support   = true


  tags = {
    Environment = local.app_name
  }
}

module "acm" {
  source  = "terraform-aws-modules/acm/aws"
  version = "~> 4.0"

  create_certificate = true
  domain_name = "duleendra.com"
  zone_id     = "Z02856453H6MK9M8LOE3C"

  validation_method = "DNS"

  subject_alternative_names = [
    "*.duleendra.com"
  ]

  wait_for_validation  = false
  validate_certificate = false
}

module "application" {
  source = "./modules/ecs"

  app_name         = local.app_name
  vpc_id           = module.vpc.vpc_id
  private_subnets  = module.vpc.private_subnets
  public_subnets   = module.vpc.public_subnets
  environment_list = []
  acm_certificate  = module.acm.acm_certificate_arn
}

module "verified_access_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.1"

  name   = "${local.app_name}-verified-access-okta-sg"
  vpc_id = module.vpc.vpc_id

  ingress_cidr_blocks = ["0.0.0.0/0"]

  ingress_rules = [
    "https-443-tcp"
  ]

  egress_rules = ["all-all"]
}

resource "aws_verifiedaccess_trust_provider" "oidc_trust_provider" {
  description = "Okta OIDC trust provider"
  policy_reference_name = "okta"
  trust_provider_type   = "user"
  user_trust_provider_type = "oidc"

  oidc_options   {
      issuer = "https://dev-71497868.okta.com"
      authorization_endpoint = "https://dev-71497868.okta.com/oauth2/v1/authorize"
      token_endpoint = "https://dev-71497868.okta.com/oauth2/v1/token"
      user_info_endpoint = "https://dev-71497868.okta.com/oauth2/v1/userinfo"
      client_id = ""
      client_secret = ""
      scope = "openid profile groups"
  }

  tags = {
    Name = "Okta OIDC Trust Provider"
  }
}

resource "aws_verifiedaccess_instance" "instance" {
  description = "OIDC Verified Access Instance"
  tags = {
    Name = "AVA Instance"
  }
}

resource "aws_verifiedaccess_instance_trust_provider_attachment" "attachment" {
  verifiedaccess_instance_id       = aws_verifiedaccess_instance.instance.id
  verifiedaccess_trust_provider_id = aws_verifiedaccess_trust_provider.oidc_trust_provider.id
}

resource "aws_verifiedaccess_group" "group" {
  verifiedaccess_instance_id = aws_verifiedaccess_instance.instance.id
  policy_document            = <<EOT
      permit(principal, action, resource)
      when {
      context.okta.groups.contains("HR")
      };
    EOT
  tags = {
    Name = "AVA Group"
  }

  depends_on = [
    aws_verifiedaccess_instance_trust_provider_attachment.attachment
  ]
}

resource "aws_verifiedaccess_endpoint" "access_endpoint" {
  description            = "AVA HR App Endpoint"
  application_domain     = "hr.duleendra.com"

  verified_access_group_id = aws_verifiedaccess_group.group.id

  attachment_type        = "vpc"
  domain_certificate_arn = module.acm.acm_certificate_arn
  endpoint_domain_prefix = "hr"
  endpoint_type          = "load-balancer"

  load_balancer_options {
    load_balancer_arn = module.application.alb_arn
    port              = 443
    protocol          = "https"
    subnet_ids        = module.vpc.private_subnets
  }

  security_group_ids       = [ module.verified_access_sg.security_group_id]

  tags = {
    Name = "AVA HR App Endpoint"
  }
}


module "route53_records" {
  source  = "terraform-aws-modules/route53/aws//modules/records"
  version = "~> 2.0"

  zone_id = ""

  records = [
    {
      name           = "app"
      type           = "CNAME"
      ttl            = 5
      records        = [aws_verifiedaccess_endpoint.access_endpoint]
    }
  ]
}