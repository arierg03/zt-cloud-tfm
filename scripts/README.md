# Scripts de operacion

Este directorio contiene scripts auxiliares para construir, publicar y operar el despliegue cloud de la aplicacion del TFM.

Actualmente incluye:

- `UpdateImages.ps1`: construye y publica imagenes Docker en AWS ECR.
- `Cloud.ps1`: despliega, consulta y detiene el entorno cloud en AWS.

## Requisitos generales

Antes de ejecutar los scripts se requiere:

- AWS CLI v2.
- Docker Desktop.
- Terraform.
- Credenciales AWS con permisos suficientes sobre ECR, EKS, RDS, EC2, IAM, S3, SSM y ELB.

Para el modo local de Kubernetes tambien se requiere:

- `kubectl`.
- Helm.

En el modo Zero Trust recomendado, `Cloud.ps1 -RemoteKubernetes` ejecuta `kubectl` y Helm desde el bastion privado, por lo que estas herramientas no tienen que estar instaladas en el equipo local.

Comprobacion basica:

```powershell
aws sts get-caller-identity
```

## UpdateImages.ps1

El script `UpdateImages.ps1` construye las imagenes Docker de los servicios de la aplicacion y las publica en AWS ECR.

Servicios soportados:

- `api`
- `web`
- `svc`

Repositorios ECR esperados:

- `zt/api`
- `zt/web`
- `zt/svc`

### Uso basico

Desde la raiz del repositorio:

```powershell
.\scripts\UpdateImages.ps1
```

Por defecto, el script:

- Resuelve automaticamente el Account ID de AWS.
- Usa la region `eu-south-2`.
- Construye las imagenes de `api`, `web` y `svc`.
- Genera un tag automatico con formato `yyyyMMdd-HHmmss`.
- Publica cada imagen con el tag generado.
- Publica tambien el tag `latest`.

### Parametros principales

| Parametro | Descripcion | Valor por defecto |
| --- | --- | --- |
| `-Region` | Region AWS donde se encuentran los repositorios ECR. | `eu-south-2` |
| `-AccountId` | ID de cuenta AWS. Si se omite, se obtiene con `aws sts get-caller-identity`. | vacio |
| `-RepositoryPrefix` | Prefijo de los repositorios ECR. | `zt` |
| `-Tag` | Tag de imagen a publicar. Si se omite, se genera automaticamente. | timestamp |
| `-Services` | Servicios a construir/publicar. Valores: `api`, `web`, `svc`. | todos |
| `-Platform` | Plataforma objetivo de la imagen Docker. | `linux/amd64` |
| `-WebApiUrl` | Valor del build arg `VITE_API_URL` para la imagen web. | `/api` |
| `-NoCache` | Fuerza build sin cache. | desactivado |
| `-SkipLatest` | Evita publicar el tag `latest`. | desactivado |

### Ejemplos

```powershell
.\scripts\UpdateImages.ps1
.\scripts\UpdateImages.ps1 -Tag v1.0.0
.\scripts\UpdateImages.ps1 -Services api,svc
.\scripts\UpdateImages.ps1 -NoCache
.\scripts\UpdateImages.ps1 -Region eu-south-2 -AccountId 296368270177
.\scripts\UpdateImages.ps1 -SkipLatest
.\scripts\UpdateImages.ps1 -WebApiUrl /api
```

## Cloud.ps1

El script `Cloud.ps1` automatiza la operacion del entorno cloud en AWS.

Permite:

- Desplegar la infraestructura y la aplicacion.
- Consultar el estado del entorno.
- Detener los recursos con coste para evitar cargos innecesarios.
- Ejecutar la administracion Kubernetes desde un bastion privado cuando el endpoint publico de EKS esta deshabilitado.

Acciones soportadas:

- `deploy`
- `status`
- `stop`

### Uso recomendado Zero Trust

Desde la raiz del repositorio:

```powershell
.\scripts\Cloud.ps1 -Action deploy -RemoteKubernetes -EnvName zt
.\scripts\Cloud.ps1 -Action status -RemoteKubernetes -EnvName zt
.\scripts\Cloud.ps1 -Action stop -RemoteKubernetes -EnvName zt
```

Este es el modo recomendado cuando EKS tiene:

```hcl
endpoint_public_access  = false
endpoint_private_access = true
```

En este escenario, `kubectl` local no puede acceder al API server de Kubernetes desde Internet. El script usa SSM para ejecutar los comandos dentro del bastion privado.

### Uso local o base

Si el endpoint publico de EKS esta habilitado, o si el equipo local tiene conectividad privada hacia la VPC, puede usarse el modo local:

```powershell
.\scripts\Cloud.ps1 -Action deploy
.\scripts\Cloud.ps1 -Action status
.\scripts\Cloud.ps1 -Action stop
```

Tambien se puede operar solo Terraform y omitir Kubernetes:

```powershell
.\scripts\Cloud.ps1 -Action deploy -SkipKubernetes
.\scripts\Cloud.ps1 -Action stop -SkipKubernetes
```

### Parametros principales

| Parametro | Descripcion | Valor por defecto |
| --- | --- | --- |
| `-Action` | Accion a ejecutar: `deploy`, `stop` o `status`. | obligatorio |
| `-Region` | Region AWS del despliegue. | `eu-south-2` |
| `-ClusterName` | Nombre del cluster EKS. | `tfm-app-eks` |
| `-EnvName` | Entorno asociado a evidencias (`base` o `zt`). | `base` |
| `-EvidenceDir` | Directorio base donde guardar evidencia de despliegue. | `evaluation/results` |
| `-AutoApprove` | Ejecuta `terraform apply -auto-approve`. | desactivado |
| `-SkipKubernetes` | Omite operaciones Kubernetes y ejecuta solo la parte Terraform/AWS. | desactivado |
| `-RemoteKubernetes` | Ejecuta operaciones Kubernetes en el bastion privado mediante SSM. | desactivado |
| `-CreateAdminBastion` | Fuerza la creacion del bastion de administracion. | `false` |

## Accion `deploy`

Despliega el entorno cloud completo.

Con `-RemoteKubernetes`, la accion realiza estas fases:

1. Activa recursos con coste en `runtime.auto.tfvars`:
   - `create_eks = true`
   - `create_rds = true`
   - `create_nat = true`
   - `create_admin_bastion = true`
2. Ejecuta Terraform:
   - `terraform init`
   - `terraform validate`
   - reparacion de rutas NAT en estado `blackhole`, si existen
   - `terraform apply`
3. Detecta el OIDC issuer del cluster EKS recien creado.
4. Actualiza `runtime.auto.tfvars` con el OIDC real.
5. Ejecuta un segundo `terraform apply` para actualizar recursos dependientes del OIDC.
6. Comprime los manifiestos de `infra/k8s`.
7. Publica el ZIP en el bucket S3 privado de artefactos Kubernetes.
8. Espera a que el bastion este registrado en SSM.
9. Ejecuta en el bastion:
   - descarga del artefacto desde S3
   - `aws eks update-kubeconfig`
   - aplicacion de ServiceAccounts
   - instalacion/actualizacion de AWS Load Balancer Controller con Helm
   - aplicacion de manifiestos de la aplicacion
   - espera del Ingress
   - estado final de Kubernetes
10. Genera evidencia del tiempo de despliegue en `evaluation/results/<env>/deployment_time_<env>.json`.

## Accion `status`

Consulta el estado actual del entorno.

Ejemplo recomendado:

```powershell
.\scripts\Cloud.ps1 -Action status -RemoteKubernetes -EnvName zt
```

Esta accion muestra:

- Recursos gestionados en el estado de Terraform.
- Resultado de `terraform plan`.
- Estado del cluster EKS, si existe.
- Estado de pods, services, ingress y NetworkPolicies en `tfm-app`.
- Estado de AWS Load Balancer Controller.
- Estado de la instancia RDS.
- Estado de las NAT Gateways.

Con `-RemoteKubernetes`, las consultas Kubernetes se ejecutan desde el bastion privado mediante SSM.

## Accion `stop`

Detiene el entorno cloud eliminando los recursos con coste.

Ejemplo recomendado:

```powershell
.\scripts\Cloud.ps1 -Action stop -RemoteKubernetes -EnvName zt
```

Con `-RemoteKubernetes`, la accion realiza estas fases:

1. Comprueba si existe el cluster EKS.
2. Espera a que el bastion este disponible en SSM.
3. Ejecuta en el bastion el borrado ordenado de recursos Kubernetes, empezando por el Ingress para permitir que AWS Load Balancer Controller elimine el ALB.
4. Actualiza `runtime.auto.tfvars`:
   - `create_eks = false`
   - `create_rds = false`
   - `create_nat = false`
   - `create_admin_bastion = false`
5. Ejecuta `terraform apply`.
6. Terraform destruye los recursos con coste definidos como opcionales.

Recursos que se eliminan con `stop`:

- Cluster EKS.
- Node group de EKS.
- Add-ons de EKS.
- Instancia RDS.
- DB subnet group de RDS.
- NAT Gateway.
- Elastic IP asociada a la NAT.
- Rutas privadas hacia NAT.
- Bastion privado de administracion.
- ALB creado por Kubernetes, si el Ingress se elimina correctamente antes.

Recursos que se mantienen:

- VPC.
- Subredes.
- Internet Gateway.
- Tablas de rutas base.
- VPC Endpoint para S3.
- Buckets S3.
- Repositorios ECR.
- IAM roles, policies y usuarios.
- Security Groups persistentes.
- OIDC Provider registrado en IAM, si aplica.

## Fichero runtime.auto.tfvars

El script `Cloud.ps1` genera o actualiza el fichero:

```text
infra/terraform/runtime.auto.tfvars
```

Este fichero contiene los flags de activacion de recursos opcionales:

```hcl
create_eks           = true
create_rds           = true
create_nat           = true
create_admin_bastion = true
```

O bien:

```hcl
create_eks           = false
create_rds           = false
create_nat           = false
create_admin_bastion = false
```

Tambien puede incluir el OIDC issuer del cluster EKS:

```hcl
eks_oidc_issuer_url = "https://oidc.eks.eu-south-2.amazonaws.com/id/..."
```

Este fichero no debe versionarse en Git, ya que representa estado operativo local generado por el script.

## Orden recomendado de operacion

### Desplegar entorno cloud Zero Trust

1. Publicar imagenes en ECR:

```powershell
.\scripts\UpdateImages.ps1
```

2. Desplegar infraestructura y aplicacion:

```powershell
.\scripts\Cloud.ps1 -Action deploy -RemoteKubernetes -EnvName zt
```

3. Consultar estado:

```powershell
.\scripts\Cloud.ps1 -Action status -RemoteKubernetes -EnvName zt
```

4. Probar la aplicacion mediante el DNS del ALB mostrado en el Ingress.

### Detener entorno cloud Zero Trust

1. Ejecutar stop:

```powershell
.\scripts\Cloud.ps1 -Action stop -RemoteKubernetes -EnvName zt
```

2. Verificar estado:

```powershell
.\scripts\Cloud.ps1 -Action status -RemoteKubernetes -EnvName zt
```

3. Comprobar que no quedan ALB asociados:

```powershell
aws elbv2 describe-load-balancers --region eu-south-2
```

## Consideraciones de coste

La accion `deploy` crea recursos con coste recurrente:

- EKS.
- EC2 del node group.
- EC2 del bastion privado.
- RDS.
- NAT Gateway.
- ALB.

La accion `stop` debe ejecutarse al finalizar las pruebas para evitar cargos innecesarios.

## Consideraciones de seguridad

- No se versionan secretos reales.
- `secret.local.yaml` debe permanecer fuera de Git.
- Las access keys reales no se gestionan con Terraform.
- El OIDC issuer de EKS se detecta dinamicamente porque cambia cuando se recrea el cluster.
- El modo `-RemoteKubernetes` evita depender del endpoint publico de EKS.
- El bastion no expone SSH ni reglas de entrada; se administra mediante SSM.
- El bucket de artefactos Kubernetes es privado, cifrado y con expiracion de objetos.
