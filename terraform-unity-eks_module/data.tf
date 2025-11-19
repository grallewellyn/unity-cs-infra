data "aws_caller_identity" "current" {}

data "aws_ssm_parameter" "vpc_id" {
  name = "/unity/account/network/vpc_id"
}

data "aws_ssm_parameter" "subnet_list" {
  name = "/unity/account/network/subnet_list"
}

data "aws_ssm_parameter" "eks_ami_1_33" {
  name = "/smce/amis/aml2023-eks-1-33"
}

data "aws_ssm_parameter" "eks_ami_1_32" {
  name = "/smce/amis/aml2023-eks-1-32"
}

data "aws_ssm_parameter" "eks_ami_1_31" {
  name = "/smce/amis/aml2023-eks-1-31"
}

data "aws_ssm_parameter" "eks_ami_1_30" {
  name = "/smce/amis/aml2023-eks-1-30"
}

data "aws_iam_policy" "smce_operator_policy" {
  name = "zsmce-tenantOperator-AMI-APIG"
}

data "aws_iam_policy" "ebs_csi_policy" {
  name = "U-CS_Service_Policy"
}

data "aws_iam_policy" "aws-managed-load-balancer-policy" {
  arn = "arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess"
}

data "aws_ebs_default_kms_key" "current" {}

data "aws_kms_key" "current" {
  key_id = data.aws_ebs_default_kms_key.current.key_arn
}

# Find the MC's ALB's security group so we can allow connections to the cluster
data "aws_security_groups" "mc_sg" {
  filter {
    name   = "tag:Name"
    values = ["Unity Management Console Instance SG"]
  }
  filter {
    name   = "tag:Venue"
    values = [var.venue]
  }
  filter {
    name   = "tag:Proj"
    values = [var.project]
  }
  tags = {
    ServiceArea = "cs"
  }
}