locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
  eks_oidc_provider_hostpath = replace(var.eks_oidc_issuer_url, "https://", "")
}