resource "aws_iam_openid_connect_provider" "eks" {
  url = var.eks_oidc_issuer_url

  client_id_list = [
    "sts.amazonaws.com"
  ]

  tags = merge(local.common_tags, {
    Name                             = "tfm-app-eks-oidc-provider"
    "alpha.eksctl.io/cluster-name"   = "tfm-app-eks"
    "alpha.eksctl.io/eksctl-version" = "0.225.0"
  })
}

resource "aws_iam_role" "load_balancer_controller" {
  name        = "AmazonEKSLoadBalancerControllerRole"
  description = "IAM role for AWS Load Balancer Controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.eks.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${local.eks_oidc_provider_hostpath}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
            "${local.eks_oidc_provider_hostpath}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "AmazonEKSLoadBalancerControllerRole"
  })
}

resource "aws_iam_policy" "load_balancer_controller" {
  name        = "AWSLoadBalancerControllerIAMPolicy"
  description = "Policy descargada de raw.githubusercontent.com aws-load-balancer-controller"

  policy = file("${path.module}/policies/aws-load-balancer-controller-policy.json")

  tags = merge(local.common_tags, {
    Name = "AWSLoadBalancerControllerIAMPolicy"
  })
}

resource "aws_iam_role_policy_attachment" "load_balancer_controller" {
  role       = aws_iam_role.load_balancer_controller.name
  policy_arn = aws_iam_policy.load_balancer_controller.arn
}

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

resource "aws_iam_policy" "api_s3_images" {
  name        = "tfm-app-api-s3-images-policy"
  description = "S3 permissions for API workload using IRSA"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListImagesBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.images.arn
      },
      {
        Sid    = "ApiImageObjectAccess"
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

  tags = merge(local.common_tags, {
    Name = "tfm-app-api-s3-images-policy"
  })
}

resource "aws_iam_policy" "svc_s3_images" {
  name        = "tfm-app-svc-s3-images-policy"
  description = "S3 permissions for batch service using IRSA"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListImagesBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.images.arn
      },
      {
        Sid    = "SvcImageObjectAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject"
        ]
        Resource = "${aws_s3_bucket.images.arn}/*"
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "tfm-app-svc-s3-images-policy"
  })
}

resource "aws_iam_role" "api_irsa" {
  name        = "tfm-app-api-irsa-role"
  description = "IRSA role for api service account"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.eks.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${local.eks_oidc_provider_hostpath}:aud" = "sts.amazonaws.com"
            "${local.eks_oidc_provider_hostpath}:sub" = "system:serviceaccount:tfm-app:api"
          }
        }
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "tfm-app-api-irsa-role"
  })
}

resource "aws_iam_role_policy_attachment" "api_s3_images" {
  role       = aws_iam_role.api_irsa.name
  policy_arn = aws_iam_policy.api_s3_images.arn
}

resource "aws_iam_role" "svc_irsa" {
  name        = "tfm-app-svc-irsa-role"
  description = "IRSA role for svc service account"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.eks.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${local.eks_oidc_provider_hostpath}:aud" = "sts.amazonaws.com"
            "${local.eks_oidc_provider_hostpath}:sub" = "system:serviceaccount:tfm-app:svc"
          }
        }
      }
    ]
  })

  tags = merge(local.common_tags, {
    Name = "tfm-app-svc-irsa-role"
  })
}

resource "aws_iam_role_policy_attachment" "svc_s3_images" {
  role       = aws_iam_role.svc_irsa.name
  policy_arn = aws_iam_policy.svc_s3_images.arn
}

resource "aws_iam_role" "admin_bastion" {
  count = local.create_admin_bastion ? 1 : 0

  name        = "tfm-app-admin-bastion-role"
  description = "IAM role for the private EKS administration bastion"

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
    Name = "tfm-app-admin-bastion-role"
  })
}

resource "aws_iam_role_policy_attachment" "admin_bastion_ssm" {
  count = local.create_admin_bastion ? 1 : 0

  role       = aws_iam_role.admin_bastion[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "admin_bastion_eks" {
  count = local.create_admin_bastion ? 1 : 0

  name = "tfm-app-admin-bastion-eks-policy"
  role = aws_iam_role.admin_bastion[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DescribeEksCluster"
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster"
        ]
        Resource = aws_eks_cluster.main[0].arn
      }
    ]
  })
}

resource "aws_iam_role_policy" "admin_bastion_k8s_artifacts" {
  count = local.create_admin_bastion ? 1 : 0

  name = "tfm-app-admin-bastion-k8s-artifacts-policy"
  role = aws_iam_role.admin_bastion[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ListK8sArtifacts"
        Effect = "Allow"
        Action = [
          "s3:ListBucket"
        ]
        Resource = aws_s3_bucket.k8s_artifacts.arn
        Condition = {
          StringLike = {
            "s3:prefix" = [
              "manifests/*"
            ]
          }
        }
      },
      {
        Sid    = "ReadK8sArtifacts"
        Effect = "Allow"
        Action = [
          "s3:GetObject"
        ]
        Resource = "${aws_s3_bucket.k8s_artifacts.arn}/manifests/*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "admin_bastion" {
  count = local.create_admin_bastion ? 1 : 0

  name = "tfm-app-admin-bastion-profile"
  role = aws_iam_role.admin_bastion[0].name
}