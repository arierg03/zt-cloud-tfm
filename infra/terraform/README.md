# Terraform - Infraestructura AWS base

Este directorio contiene la definición Terraform de la infraestructura AWS utilizada para el despliegue base del TFM.

## Recursos gestionados

- VPC, subredes, Internet Gateway, tablas de rutas y VPC Endpoint para S3
- Repositorios ECR
- Bucket S3 de imágenes
- Recursos IAM asociados a EKS, S3 y AWS Load Balancer Controller
- Security Group de RDS
- Definiciones opcionales de RDS, NAT Gateway y EKS

## Recursos opcionales

Los siguientes recursos están definidos pero desactivados por defecto para evitar costes recurrentes:

- RDS: `create_rds = false`
- NAT Gateway: `create_nat = false`
- EKS: `create_eks = false`

Para activarlos, modificar `terraform.tfvars`.

## Comandos habituales

```powershell
terraform fmt
terraform validate
terraform plan
terraform apply
terraform output
```

## Notas

Las access keys y secretos reales no se gestionan con Terraform para evitar almacenarlos en el estado.