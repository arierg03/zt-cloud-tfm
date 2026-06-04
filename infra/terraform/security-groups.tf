resource "aws_security_group" "rds" {
  name        = "tfm-app-rds-sg"
  description = "Created by RDS management console"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "tfm-app-rds-sg"
  })
}

resource "aws_security_group" "admin_bastion" {
  count = local.create_admin_bastion ? 1 : 0

  name        = "tfm-app-admin-bastion-sg"
  description = "Private administration bastion for EKS via SSM"
  vpc_id      = aws_vpc.main.id

  egress {
    description = "HTTPS egress for SSM, AWS APIs and private EKS endpoint"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "DNS egress to VPC resolver"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = [format("%s/32", cidrhost(aws_vpc.main.cidr_block, 2))]
  }

  egress {
    description = "DNS TCP egress to VPC resolver"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = [format("%s/32", cidrhost(aws_vpc.main.cidr_block, 2))]
  }

  tags = merge(local.common_tags, {
    Name = "tfm-app-admin-bastion-sg"
  })
}

resource "aws_security_group_rule" "eks_control_plane_from_admin_bastion" {
  count = local.create_admin_bastion ? 1 : 0

  description              = "Allow private EKS API access from admin bastion"
  type                     = "ingress"
  security_group_id        = aws_eks_cluster.main[0].vpc_config[0].cluster_security_group_id
  source_security_group_id = aws_security_group.admin_bastion[0].id
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
}
