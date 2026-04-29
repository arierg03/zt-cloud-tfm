resource "aws_iam_user" "s3_user" {
  name = "tfm-app-s3-user"

  tags = merge(local.common_tags, {
    Name = "tfm-app-s3-user"
  })
}

resource "aws_iam_policy" "s3_user" {
  name = "tfm-app-s3-user-policy"

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

  tags = merge(local.common_tags, {
    Name = "tfm-app-s3-user-policy"
  })
}

resource "aws_iam_user_policy_attachment" "s3_user" {
  user       = aws_iam_user.s3_user.name
  policy_arn = aws_iam_policy.s3_user.arn
}

resource "aws_iam_openid_connect_provider" "eks" {
  url = "https://oidc.eks.eu-south-2.amazonaws.com/id/AEEB296AFF3D3A228A7647FC3C1E89A1"

  client_id_list = [
    "sts.amazonaws.com"
  ]

  tags = merge(local.common_tags, {
    Name                           = "tfm-app-eks-oidc-provider"
    "alpha.eksctl.io/cluster-name" = "tfm-app-eks"
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
            "oidc.eks.eu-south-2.amazonaws.com/id/AEEB296AFF3D3A228A7647FC3C1E89A1:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
            "oidc.eks.eu-south-2.amazonaws.com/id/AEEB296AFF3D3A228A7647FC3C1E89A1:aud" = "sts.amazonaws.com"
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