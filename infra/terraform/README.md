# Terraform - Infraestructura AWS

Este directorio contiene la definicion Terraform de la infraestructura AWS utilizada por el TFM, incluyendo la base cloud y los controles incorporados durante la migracion Zero Trust.

## Recursos gestionados

- VPC, subredes, Internet Gateway, tablas de rutas y VPC Endpoint para S3.
- Repositorios ECR para las imagenes `api`, `web` y `svc`.
- Bucket S3 de imagenes de la aplicacion.
- Bucket S3 privado para artefactos Kubernetes usados por la administracion remota desde bastion.
- Bucket S3 dedicado para logs de CloudTrail.
- Recursos IAM asociados a EKS, S3, AWS Load Balancer Controller, workloads con IRSA y bastion de administracion.
- Security Groups y reglas para RDS, EKS, node group y bastion.
- CloudTrail de auditoria Zero Trust.
- Definiciones opcionales de RDS, NAT Gateway, EKS y bastion privado.

## Recursos opcionales

Los siguientes recursos estan definidos pero pueden activarse o desactivarse para controlar el coste del entorno:

- RDS: `create_rds`.
- NAT Gateway: `create_nat`.
- EKS: `create_eks`.
- Bastion privado de administracion: `create_admin_bastion`.

El script `scripts/Cloud.ps1` actualiza `runtime.auto.tfvars` durante `deploy` y `stop` para encender o apagar los recursos con coste recurrente.

## EKS y plano de control

El cluster EKS se configura con administracion privada:

```hcl
endpoint_public_access  = false
endpoint_private_access = true
```

Con esta configuracion, el API server de Kubernetes no queda accesible desde Internet. Las operaciones administrativas se ejecutan desde un bastion EC2 desplegado en una subred privada y gestionado mediante SSM Session Manager.

Elementos relacionados:

- Instancia EC2 privada para administracion.
- IAM instance profile con permisos SSM, `eks:DescribeCluster` y lectura del bucket de artefactos Kubernetes.
- Asociacion EKS Access Entry para permitir administracion del cluster desde el rol del bastion.
- Security Group del bastion sin reglas de entrada.
- Regla de salida del bastion hacia el endpoint privado de EKS por HTTPS.
- Script de bootstrap `scripts/admin-bastion.sh` para instalar `kubectl` y `helm`.

## Bucket de artefactos Kubernetes

El bucket de artefactos Kubernetes se usa como canal controlado para que `Cloud.ps1` publique los manifiestos locales y el bastion pueda descargarlos durante `deploy` o `stop`.

Controles aplicados:

- Bloqueo de acceso publico.
- Cifrado en reposo SSE-S3.
- Ciclo de vida para expirar artefactos bajo `manifests/`.
- Permisos IAM limitados al rol del bastion para listar y leer objetos necesarios.

## Auditoria con CloudTrail

Terraform crea un CloudTrail de auditoria Zero Trust llamado:

```text
tfm-app-zt-audit-trail
```

El trail registra eventos de gestion de lectura y escritura, incluye eventos globales de servicios AWS, se configura como multi-region y activa la validacion de integridad de los ficheros de log.

Los logs se entregan en un bucket S3 dedicado con nombre derivado del proyecto, cuenta y region:

```text
tfm-app-cloudtrail-<account-id>-<region>
```

Controles aplicados al bucket:

- Bloqueo de acceso publico.
- Cifrado en reposo SSE-S3.
- Versionado habilitado.
- Ownership `BucketOwnerPreferred`.
- Politica de bucket limitada al servicio CloudTrail y al ARN del trail.
- Ciclo de vida para expirar logs bajo `AWSLogs/` y versiones no actuales a los 30 dias.

Terraform expone como outputs el nombre y ARN del trail, ademas del nombre del bucket de logs:

```text
cloudtrail_name
cloudtrail_arn
cloudtrail_logs_bucket_name
```

## Bloques Zero Trust reflejados en Terraform

- IRSA para workloads: roles IAM y trust policies asociados a ServiceAccounts de Kubernetes.
- Segmentacion: Security Groups y reglas que complementan las NetworkPolicies del cluster.
- Endurecimiento: soporte de infraestructura para ejecutar workloads con configuracion Kubernetes reforzada.
- Plano de control privado: endpoint publico de EKS deshabilitado y operacion por bastion privado via SSM.
- Auditoria: CloudTrail multi-region con validacion de logs y almacenamiento segregado en S3.

## Comandos habituales

```powershell
terraform fmt
terraform validate
terraform plan
terraform apply
terraform output
```

Para operar el entorno completo se recomienda usar `Cloud.ps1` desde la raiz del repositorio:

```powershell
.\scripts\Cloud.ps1 -Action deploy -RemoteKubernetes -EnvName zt
.\scripts\Cloud.ps1 -Action status -RemoteKubernetes -EnvName zt
.\scripts\Cloud.ps1 -Action stop -RemoteKubernetes -EnvName zt
```

## Notas

- Las access keys y secretos reales no se gestionan con Terraform para evitar almacenarlos en el estado.
- `runtime.auto.tfvars` representa estado operativo local generado por scripts y no debe versionarse.
- Si el endpoint publico de EKS esta deshabilitado, `kubectl` local no podra comunicarse con el cluster salvo que el equipo este conectado a la VPC o a una red privada equivalente.
