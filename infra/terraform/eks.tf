resource "aws_iam_role" "eks_cluster" {
  name = "tfm-app-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
        Action = [
          "sts:AssumeRole",
          "sts:TagSession"
        ]
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "tfm-app-eks-cluster-role"
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "main" {
  count = var.create_eks ? 1 : 0

  name     = "tfm-app-eks"
  role_arn = aws_iam_role.eks_cluster.name
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

resource "aws_iam_role" "eks_nodes" {
  name        = "tfm-app-eks-node-role"
  description = "Allows EC2 instances to call AWS services on your behalf."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "tfm-app-eks-node-role"
  })
}

resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "eks_ecr_readonly" {
  role       = aws_iam_role.eks_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy" "eks_nodes_s3" {
  name = "tfm-app-node-s3-policy"
  role = aws_iam_role.eks_nodes.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ListBucket"
        Effect = "Allow"
        Action = [
          "s3:ListBucket"
        ]
        Resource = aws_s3_bucket.images.arn
      },
      {
        Sid    = "ObjectAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = "${aws_s3_bucket.images.arn}/*"
      }
    ]
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
    aws_iam_role_policy.eks_nodes_s3
  ]

  tags = merge(local.common_tags, {
    Name = "tfm-app-ng"
  })
}