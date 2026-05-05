# Despliegue automático en AWS

Este documento describe el procedimiento automatizado recomendado para desplegar, consultar y detener el entorno cloud base del TFM.

El flujo automático se apoya en:

- Terraform para la infraestructura AWS.
- Manifiestos Kubernetes para desplegar la aplicación sobre EKS.
- Scripts de operación para publicar imágenes, desplegar, consultar estado y detener recursos con coste.

## Estructura relacionada

```text
infra/
  terraform/    Definición Terraform de la infraestructura AWS
  k8s/          Manifiestos Kubernetes
  docs/         Documentación de despliegue

scripts/
  Cloud.ps1         Operación cloud: deploy, status y stop
  cloud.sh          Variante Linux para operación cloud
  UpdateImages.ps1  Build y push de imágenes Docker a ECR
  update-images.sh  Variante Linux para build y push de imágenes
```

## Objetivo

Automatizar el ciclo completo de operación del entorno cloud:

```text
publicar imágenes -> desplegar cloud -> consultar estado -> probar app -> detener recursos con coste
```

El objetivo principal es reducir errores manuales, mejorar la reproducibilidad y evitar costes innecesarios durante el desarrollo experimental.

## Componentes gestionados

El despliegue automático utiliza los siguientes componentes AWS:

- ECR para imágenes Docker.
- S3 para imágenes de eventos.
- VPC con subredes públicas y privadas.
- VPC Endpoint Gateway para S3.
- NAT Gateway para salida desde subredes privadas.
- RDS PostgreSQL.
- EKS y Managed Node Group.
- AWS Load Balancer Controller.
- Application Load Balancer generado desde el Ingress de Kubernetes.
- IAM roles, policies y OIDC Provider.

## Recursos persistentes y recursos opcionales

La infraestructura diferencia entre recursos persistentes y recursos con coste recurrente.

### Recursos persistentes

Estos recursos permanecen creados tras ejecutar `stop`:

- VPC.
- Subredes.
- Internet Gateway.
- Tablas de rutas base.
- VPC Endpoint Gateway para S3.
- Bucket S3.
- Repositorios ECR.
- IAM roles, policies y usuarios.
- Security Group de RDS.
- OIDC Provider registrado en IAM.

### Recursos opcionales con coste

Estos recursos se activan con `deploy` y se destruyen con `stop`:

- EKS.
- Managed Node Group.
- Add-ons de EKS.
- RDS PostgreSQL.
- DB Subnet Group de RDS.
- NAT Gateway.
- Elastic IP asociada a NAT.
- Rutas privadas hacia NAT.
- ALB creado por Kubernetes.

## Prerrequisitos

Herramientas necesarias:

- AWS CLI v2.
- Docker Desktop.
- Terraform.
- kubectl.
- Helm.

Comprobar autenticación en AWS:

```powershell
aws sts get-caller-identity
```

Comprobar herramientas:

```powershell
aws --version
docker --version
terraform version
kubectl version --client
helm version
```

La cuenta o perfil AWS utilizado debe tener permisos para operar sobre:

- ECR.
- EC2/VPC.
- S3.
- RDS.
- EKS.
- IAM.
- ELBv2.

## 1. Publicar imágenes en ECR

Antes de desplegar en EKS, las imágenes Docker deben estar publicadas en ECR.

En Windows:

```powershell
.\scripts\UpdateImages.ps1
```

Por defecto publica:

- `zt/api`
- `zt/web`
- `zt/svc`

con dos tags:

- un tag temporal con formato `yyyyMMdd-HHmmss`;
- `latest`.

Ejemplos:

```powershell
.\scripts\UpdateImages.ps1 -Tag v1.0.0
.\scripts\UpdateImages.ps1 -Services api,svc
.\scripts\UpdateImages.ps1 -NoCache
.\scripts\UpdateImages.ps1 -SkipLatest
```

En Linux:

```bash
bash ./scripts/update-images.sh
```

La documentación completa de scripts está en:

```text
scripts/README.md
```

## 2. Configurar variables locales de Terraform

El fichero `terraform.tfvars` debe existir en:

```text
infra/terraform/terraform.tfvars
```

Este fichero no debe versionarse en Git.

Debe contener, al menos, la contraseña de RDS cuando se vaya a desplegar la base de datos:

```hcl
db_password = "REEMPLAZAR_PASSWORD"
```

Opcionalmente:

```hcl
db_name     = "events"
db_username = "events_user"
```

El script `Cloud.ps1` genera automáticamente:

```text
infra/terraform/runtime.auto.tfvars
```

Este fichero contiene los flags operativos:

```hcl
create_eks = true
create_rds = true
create_nat = true
```

o:

```hcl
create_eks = false
create_rds = false
create_nat = false
```

También incluye el OIDC issuer real del cluster EKS cuando existe:

```hcl
eks_oidc_issuer_url = "https://oidc.eks.eu-south-2.amazonaws.com/id/..."
```

`runtime.auto.tfvars` no debe versionarse en Git.

## 3. Desplegar el entorno cloud

Ejecutar desde la raíz del repositorio:

```powershell
.\scripts\Cloud.ps1 deploy
```

Por defecto, Terraform pedirá confirmación manual antes de aplicar cambios.

Para ejecución no interactiva:

```powershell
.\scripts\Cloud.ps1 deploy -AutoApprove
```

Se recomienda usar `-AutoApprove` solo cuando el flujo ya haya sido validado previamente.

## 4. Fases internas del deploy

La acción `deploy` realiza las siguientes fases:

1. Genera `runtime.auto.tfvars` activando:
   - `create_eks = true`
   - `create_rds = true`
   - `create_nat = true`

2. Ejecuta:
   - `terraform init`
   - `terraform validate`

3. Repara rutas NAT antiguas en estado `blackhole`, si existen.

4. Ejecuta un primer `terraform apply` para crear:
   - EKS.
   - Node Group.
   - RDS.
   - NAT Gateway.
   - Rutas NAT.
   - Add-ons de EKS.

5. Actualiza `kubeconfig`.

6. Detecta dinámicamente el OIDC issuer del cluster EKS.

7. Reescribe `runtime.auto.tfvars` incluyendo el OIDC issuer real.

8. Ejecuta un segundo `terraform apply` para actualizar:
   - IAM OIDC Provider.
   - Trust policy del rol `AmazonEKSLoadBalancerControllerRole`.

9. Aplica el ServiceAccount del AWS Load Balancer Controller.

10. Instala o actualiza AWS Load Balancer Controller con Helm.

11. Espera a que AWS Load Balancer Controller esté listo.

12. Aplica los manifiestos Kubernetes:
    - namespace.
    - secret local.
    - configmap.
    - deployment API.
    - cronjob `svc`.
    - deployment web.
    - services.
    - ingress.

13. Espera a que el Ingress tenga un `ADDRESS`.

14. Muestra el estado final de Kubernetes.

## 5. Consultar estado

Ejecutar:

```powershell
.\scripts\Cloud.ps1 status
```

Esta acción muestra:

- Recursos del estado Terraform.
- Resultado de `terraform plan`.
- Estado del cluster EKS.
- Estado de pods, services e ingress en `tfm-app`.
- Estado de RDS.
- Estado de NAT Gateways.

Un estado correcto con el entorno desplegado debería incluir:

```text
Terraform plan: No changes
EKS: ACTIVE
Pods: Running
Ingress: ADDRESS asignado
RDS: available
NAT Gateway: available
```

## 6. Probar aplicación

Cuando el Ingress tenga `ADDRESS`, probar healthcheck:

```powershell
curl.exe http://<ALB_DNS>/api/health
```

Abrir frontend:

```text
http://<ALB_DNS>/
```

El DNS del ALB puede tardar unos minutos en resolver tras la creación.

## 7. Detener recursos con coste

Al terminar las pruebas:

```powershell
.\scripts\Cloud.ps1 stop
```

Para ejecución no interactiva:

```powershell
.\scripts\Cloud.ps1 stop -AutoApprove
```

La acción `stop` realiza:

1. Comprueba si existe EKS.
2. Actualiza `kubeconfig`.
3. Detecta el OIDC issuer actual.
4. Borra los recursos Kubernetes, empezando por el Ingress.
5. Espera para permitir que AWS Load Balancer Controller elimine el ALB.
6. Genera `runtime.auto.tfvars` con:
   - `create_eks = false`
   - `create_rds = false`
   - `create_nat = false`
7. Ejecuta `terraform apply`.
8. Destruye recursos con coste.

Un plan correcto de `stop` debe mostrar destrucción de recursos como:

- `aws_eks_cluster.main[0]`
- `aws_eks_node_group.main[0]`
- `aws_eks_addon.*`
- `aws_db_instance.rds[0]`
- `aws_nat_gateway.main[0]`
- `aws_eip.nat[0]`
- `aws_route.private_*_nat[0]`

No debe destruir recursos persistentes como:

- VPC.
- S3.
- ECR.
- IAM.
- VPC Endpoint.
- Security Groups base.

## 8. Verificación tras stop

Ejecutar:

```powershell
.\scripts\Cloud.ps1 status
```

El resultado esperado es:

```text
Cluster EKS no existe.
Instancia RDS no existe.
No hay NAT Gateways activas en la VPC.
Terraform plan: No changes.
```

Comprobar que no quedan ALB:

```powershell
aws elbv2 describe-load-balancers `
  --region eu-south-2 `
  --query "LoadBalancers[?contains(LoadBalancerName, 'k8s')].{Name:LoadBalancerName,DNS:DNSName,State:State.Code}" `
  --output table
```

Si no aparece ningún ALB asociado a `tfm-app`, el entorno cloud con coste queda detenido correctamente.

## 9. Consideraciones sobre OIDC

EKS genera un OIDC issuer distinto cada vez que se recrea el cluster.

Por este motivo, el script:

1. Crea el cluster.
2. Consulta el issuer real con AWS CLI.
3. Actualiza `runtime.auto.tfvars`.
4. Ejecuta un segundo `terraform apply`.

Esto permite mantener actualizado:

- `aws_iam_openid_connect_provider.eks`
- trust policy de `AmazonEKSLoadBalancerControllerRole`

Sin esta fase, AWS Load Balancer Controller no podría asumir correctamente su rol mediante IRSA.

## 10. Consideraciones sobre NAT

Los nodos EKS se ejecutan en subredes privadas. Para que puedan descargar imágenes, comunicarse con servicios AWS y unirse correctamente al cluster, el despliegue base utiliza NAT Gateway.

Si una NAT anterior se elimina sin limpiar las rutas, las tablas privadas pueden conservar rutas `0.0.0.0/0` en estado `blackhole`.

El script detecta y elimina esas rutas antes del `terraform apply`, permitiendo que Terraform cree rutas limpias hacia la NAT nueva.

## 11. Consideraciones sobre AWS Load Balancer Controller

El Ingress de Kubernetes requiere que AWS Load Balancer Controller esté instalado y listo.

El script:

1. Aplica el ServiceAccount `aws-lbc-sa.yaml`.
2. Instala el controller con Helm.
3. Espera a que el deployment esté listo.
4. Aplica los manifiestos de la aplicación.

Esto evita errores de webhook como:

```text
no endpoints available for service "aws-load-balancer-webhook-service"
```

## 12. Consideraciones de coste

La acción `deploy` crea recursos con coste recurrente:

- EKS.
- EC2 del node group.
- RDS.
- NAT Gateway.
- ALB.

La acción `stop` debe ejecutarse al finalizar las pruebas.

## 13. Consideraciones de seguridad

- No se versionan secretos reales.
- `secret.local.yaml` debe permanecer fuera de Git.
- `terraform.tfvars` debe permanecer fuera de Git.
- `runtime.auto.tfvars` debe permanecer fuera de Git.
- Las access keys reales no se gestionan con Terraform.
- El acceso a S3 en la arquitectura base usa credenciales configuradas como Secret de Kubernetes.
- En una evolución Zero Trust, el acceso a S3 puede sustituirse por IRSA.
