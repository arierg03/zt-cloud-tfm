resource "aws_eks_cluster" "main" {
  count = var.create_eks ? 1 : 0

  name     = "tfm-app-eks"
  role_arn = aws_iam_role.eks_cluster.arn
  version  = "1.35"

  enabled_cluster_log_types = [
    "api",
    "audit",
    "authenticator"
  ]

  vpc_config {
    subnet_ids = [
      aws_subnet.private_1.id,
      aws_subnet.private_2.id
    ]

    endpoint_public_access  = true
    endpoint_private_access = true
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  upgrade_policy {
    support_type = "STANDARD"
  }

  deletion_protection = false

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy
  ]

  tags = merge(local.common_tags, {
    Name = "tfm-app-eks"
  })
}

resource "aws_eks_addon" "vpc_cni" {
  count = var.create_eks ? 1 : 0

  cluster_name  = aws_eks_cluster.main[0].name
  addon_name    = "vpc-cni"
  addon_version = "v1.21.1-eksbuild.1"

  configuration_values = jsonencode({
    enableNetworkPolicy = "true"
  })

  depends_on = [
    aws_eks_cluster.main
  ]

  tags = merge(local.common_tags, {
    Name = "tfm-app-eks-vpc-cni"
  })
}

resource "aws_eks_addon" "kube_proxy" {
  count = var.create_eks ? 1 : 0

  cluster_name  = aws_eks_cluster.main[0].name
  addon_name    = "kube-proxy"
  addon_version = "v1.35.3-eksbuild.2"

  depends_on = [
    aws_eks_cluster.main
  ]

  tags = merge(local.common_tags, {
    Name = "tfm-app-eks-kube-proxy"
  })
}

resource "aws_eks_addon" "coredns" {
  count = var.create_eks ? 1 : 0

  cluster_name  = aws_eks_cluster.main[0].name
  addon_name    = "coredns"
  addon_version = "v1.13.2-eksbuild.4"

  depends_on = [
    aws_eks_node_group.main
  ]

  tags = merge(local.common_tags, {
    Name = "tfm-app-eks-coredns"
  })
}

resource "aws_eks_node_group" "main" {
  count = var.create_eks ? 1 : 0

  cluster_name    = aws_eks_cluster.main[0].name
  node_group_name = "tfm-app-ng"
  node_role_arn   = aws_iam_role.eks_nodes.arn

  subnet_ids = [
    aws_subnet.private_1.id,
    aws_subnet.private_2.id
  ]

  ami_type      = "AL2023_x86_64_STANDARD"
  capacity_type = "ON_DEMAND"

  instance_types = [
    "t3.medium"
  ]

  disk_size = 20

  scaling_config {
    desired_size = 1
    min_size     = 1
    max_size     = 1
  }

  update_config {
    max_unavailable = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_ecr_readonly,
  ]

  tags = merge(local.common_tags, {
    Name = "tfm-app-ng"
  })
}

resource "aws_eks_access_entry" "admin_bastion" {
  count = local.create_admin_bastion ? 1 : 0

  cluster_name  = aws_eks_cluster.main[0].name
  principal_arn = aws_iam_role.admin_bastion[0].arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "admin_bastion_admin" {
  count = local.create_admin_bastion ? 1 : 0

  cluster_name  = aws_eks_cluster.main[0].name
  principal_arn = aws_iam_role.admin_bastion[0].arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [
    aws_eks_access_entry.admin_bastion
  ]
}