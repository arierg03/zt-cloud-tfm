data "aws_ami" "admin_bastion" {
  count = local.create_admin_bastion ? 1 : 0

  most_recent = true
  owners      = ["amazon"]

  filter {
    name = "name"
    values = [
      "al2023-ami-2023.*-kernel-*-x86_64"
    ]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "admin_bastion" {
  count = local.create_admin_bastion ? 1 : 0

  ami                         = data.aws_ami.admin_bastion[0].id
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.private_1.id
  associate_public_ip_address = false
  iam_instance_profile        = aws_iam_instance_profile.admin_bastion[0].name
  vpc_security_group_ids      = [aws_security_group.admin_bastion[0].id]

  user_data                   = file("${path.module}/scripts/admin-bastion.sh")
  user_data_replace_on_change = true

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  tags = merge(local.common_tags, {
    Name = "tfm-app-admin-bastion"
  })

  depends_on = [
    aws_iam_role_policy_attachment.admin_bastion_ssm,
    aws_iam_role_policy.admin_bastion_eks,
    aws_iam_role_policy.admin_bastion_k8s_artifacts,
    aws_eks_access_policy_association.admin_bastion_admin
  ]
}
