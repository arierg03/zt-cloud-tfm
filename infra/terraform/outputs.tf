output "vpc_id" {
  description = "ID de la VPC principal"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "IDs de las subredes públicas"
  value = [
    aws_subnet.public_1.id,
    aws_subnet.public_2.id
  ]
}

output "private_subnet_ids" {
  description = "IDs de las subredes privadas"
  value = [
    aws_subnet.private_1.id,
    aws_subnet.private_2.id
  ]
}

output "internet_gateway_id" {
  description = "ID del Internet Gateway"
  value       = aws_internet_gateway.main.id
}

output "public_route_table_id" {
  description = "ID de la tabla de rutas pública"
  value       = aws_route_table.public.id
}

output "private_route_table_ids" {
  description = "IDs de las tablas de rutas privadas"
  value = [
    aws_route_table.private_1.id,
    aws_route_table.private_2.id
  ]
}

output "s3_vpc_endpoint_id" {
  description = "ID del VPC Endpoint Gateway para S3"
  value       = aws_vpc_endpoint.s3.id
}

output "s3_bucket_name" {
  description = "Nombre del bucket S3 de imágenes"
  value       = aws_s3_bucket.images.bucket
}

output "ecr_repository_urls" {
  description = "URLs de los repositorios ECR"
  value = {
    api = aws_ecr_repository.api.repository_url
    web = aws_ecr_repository.web.repository_url
    svc = aws_ecr_repository.svc.repository_url
  }
}

output "rds_endpoint" {
  description = "Endpoint de la instancia RDS, si está creada"
  value       = var.create_rds ? aws_db_instance.rds[0].endpoint : null
}

output "rds_address" {
  description = "Dirección DNS de la instancia RDS, si está creada"
  value       = var.create_rds ? aws_db_instance.rds[0].address : null
}

output "eks_cluster_name" {
  description = "Nombre del cluster EKS, si está creado"
  value       = var.create_eks ? aws_eks_cluster.main[0].name : null
}

output "eks_cluster_endpoint" {
  description = "Endpoint del cluster EKS, si está creado"
  value       = var.create_eks ? aws_eks_cluster.main[0].endpoint : null
}

output "eks_oidc_issuer_url" {
  description = "Issuer OIDC del cluster EKS configurado para Terraform"
  value       = var.eks_oidc_issuer_url
}

output "nat_gateway_id" {
  description = "ID de la NAT Gateway, si está creada"
  value       = var.create_nat ? aws_nat_gateway.main[0].id : null
}

output "admin_bastion_instance_id" {
  description = "ID de la instancia privada de administracion, si esta creada"
  value       = local.create_admin_bastion ? aws_instance.admin_bastion[0].id : null
}

output "admin_bastion_private_ip" {
  description = "IP privada de la instancia privada de administracion, si esta creada"
  value       = local.create_admin_bastion ? aws_instance.admin_bastion[0].private_ip : null
}

output "admin_bastion_role_name" {
  description = "Nombre del rol IAM asociado a la instancia privada de administracion"
  value       = local.create_admin_bastion ? aws_iam_role.admin_bastion[0].name : null
}

output "k8s_artifacts_bucket_name" {
  description = "Nombre del bucket S3 para artefactos temporales de Kubernetes"
  value       = aws_s3_bucket.k8s_artifacts.bucket
}