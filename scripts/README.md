# Scripts de operación

Este directorio contiene scripts auxiliares para construir, publicar y operar el despliegue cloud de la aplicación base del TFM.

Actualmente incluye:

- `UpdateImages.ps1`: construye y publica imágenes Docker en AWS ECR.
- `Cloud.ps1`: despliega, consulta y detiene el entorno cloud en AWS.

## Requisitos generales

Antes de ejecutar los scripts, se requiere tener instaladas y configuradas las siguientes herramientas:

- AWS CLI v2
- Docker Desktop
- Terraform
- kubectl
- Helm

Además, la AWS CLI debe estar autenticada con una cuenta/perfil que tenga permisos suficientes sobre ECR, EKS, RDS, EC2, IAM, S3 y ELB.

Comprobación básica:

```
aws sts get-caller-identity
```

## UpdateImages.ps1

El script `UpdateImages.ps1` construye las imágenes Docker de los servicios de la aplicación y las publica en AWS ECR.

Servicios soportados:

- `api`
- `web`
- `svc`

Repositorios ECR esperados:

- `zt/api`
- `zt/web`
- `zt/svc`

### Uso básico

Desde la raíz del repositorio:

```
.\scripts\UpdateImages.ps1
```

Por defecto, el script:

- Resuelve automáticamente el Account ID de AWS.
- Usa la región `eu-south-2`.
- Construye las imágenes de `api`, `web` y `svc`.
- Genera un tag automático con formato `yyyyMMdd-HHmmss`.
- Publica cada imagen con el tag generado.
- Publica también el tag `latest`.

### Parámetros principales

|Parámetro|Descripción|Valor por defecto|
|---|---|---|
|`-Region`|Región AWS donde se encuentran los repositorios ECR.|`eu-south-2`|
|`-AccountId`|ID de cuenta AWS. Si se omite, se obtiene con `aws sts get-caller-identity`.|vacío|
|`-RepositoryPrefix`|Prefijo de los repositorios ECR.|`zt`|
|`-Tag`|Tag de imagen a publicar. Si se omite, se genera automáticamente.|timestamp|
|`-Services`|Servicios a construir/publicar. Valores: `api`, `web`, `svc`.|todos|
|`-Platform`|Plataforma objetivo de la imagen Docker.|`linux/amd64`|
|`-WebApiUrl`|Valor del build arg `VITE_API_URL` para la imagen web.|`/api`|
|`-NoCache`|Fuerza build sin caché.|desactivado|
|`-SkipLatest`|Evita publicar el tag `latest`.|desactivado|

### Ejemplos

Construir y publicar todos los servicios:

```
.\scripts\UpdateImages.ps1
```

Usar un tag manual:

```
.\scripts\UpdateImages.ps1 -Tag v1.0.0
```

Publicar solo API y servicio batch:

```
.\scripts\UpdateImages.ps1 -Services api,svc
```

Construir sin caché:

```
.\scripts\UpdateImages.ps1 -NoCache
```

Cambiar región y Account ID explícitamente:

```
.\scripts\UpdateImages.ps1 -Region eu-south-2 -AccountId 296368270177
```

Publicar sin actualizar `latest`:

```
.\scripts\UpdateImages.ps1 -SkipLatest
```

Cambiar la URL de API usada por el frontend:

```
.\scripts\UpdateImages.ps1 -WebApiUrl /api
```

### Funcionamiento interno

El script realiza los siguientes pasos:

1. Comprueba que existen los comandos `aws` y `docker`.
2. Obtiene el Account ID si no se proporciona manualmente.
3. Hace login en ECR mediante `aws ecr get-login-password`.
4. Comprueba que existe el repositorio ECR correspondiente a cada servicio.
5. Construye la imagen Docker usando `docker buildx build`.
6. Etiqueta la imagen con el tag indicado y, salvo que se indique `-SkipLatest`, también con `latest`.
7. Publica las imágenes en ECR mediante `docker push`.
8. Muestra un resumen final con las imágenes publicadas.

## Cloud.ps1

El script `Cloud.ps1` automatiza la operación del entorno cloud base en AWS.

Permite:

- Desplegar la infraestructura y la aplicación.
- Consultar el estado del entorno.
- Detener los recursos con coste para evitar cargos innecesarios.

Acciones soportadas:

- `deploy`
- `status`
- `stop`

### Uso básico

Desde la raíz del repositorio:

```
.\scripts\Cloud.ps1 -Action status
.\scripts\Cloud.ps1 -Action deploy
.\scripts\Cloud.ps1 -Action stop
```

### Parámetros principales

|Parámetro|Descripción|Valor por defecto|
|---|---|---|
|`-Action`|Acción a ejecutar: `deploy`, `stop` o `status`.|obligatorio|
|`-Region`|Región AWS del despliegue.|`eu-south-2`|
|`-ClusterName`|Nombre del cluster EKS.|`tfm-app-eks`|
|`-EnvName`|Entorno asociado a evidencias (`base` o `zt`).|`base`|
|`-EvidenceDir`|Directorio base donde guardar evidencia de despliegue.|`evaluation/results`|
|`-AutoApprove`|Ejecuta `terraform apply -auto-approve`.|desactivado|

### Acción `status`

Consulta el estado actual del entorno.

Ejemplo:

```
.\scripts\Cloud.ps1 -Action status
```

Esta acción muestra:

- Recursos gestionados en el estado de Terraform.
- Resultado de `terraform plan`.
- Estado del cluster EKS, si existe.
- Estado de pods, services e ingress en el namespace `tfm-app`, si el cluster existe.
- Estado de la instancia RDS.
- Estado de las NAT Gateways.

Uso recomendado antes y después de `deploy` o `stop`.

### Acción `deploy`

Despliega el entorno cloud base completo.

Ejemplo:

```
.\scripts\Cloud.ps1 -Action deploy
```

Esta acción realiza las siguientes fases:

1. Activa los recursos con coste en `runtime.auto.tfvars`:
    - `create_eks = true`
    - `create_rds = true`
    - `create_nat = true`
2. Ejecuta Terraform:
    - `terraform init`
    - `terraform validate`
    - reparación de rutas NAT en estado `blackhole`, si existen
    - `terraform apply`
3. Actualiza el kubeconfig local para apuntar al cluster EKS.
4. Detecta dinámicamente el OIDC issuer del cluster EKS recién creado.
5. Actualiza `runtime.auto.tfvars` con el OIDC real del cluster.
6. Ejecuta un segundo `terraform apply` para actualizar:
    - IAM OIDC Provider
    - trust policy del rol `AmazonEKSLoadBalancerControllerRole`
7. Aplica el ServiceAccount del AWS Load Balancer Controller.
8. Instala o actualiza AWS Load Balancer Controller mediante Helm.
9. Espera a que el controller esté listo.
10. Aplica los manifiestos Kubernetes de la aplicación:
    - namespace
    - secret local
    - configmap
    - deployments
    - services
    - ingress
11. Espera a que el Ingress tenga un `ADDRESS` asignado por el ALB.
12. Muestra el estado final de Kubernetes.
13. Genera evidencia del tiempo de despliegue en:
    - `evaluation/results/<env>/deployment_time_<env>.json`
    - ejemplo: `evaluation/results/base/deployment_time_base.json`

### Acción `stop`

Detiene el entorno cloud eliminando los recursos con coste.

Ejemplo:

```
.\scripts\Cloud.ps1 -Action stop
```

Esta acción realiza las siguientes fases:

1. Comprueba si existe el cluster EKS.
2. Actualiza kubeconfig si el cluster existe.
3. Detecta el OIDC issuer actual del cluster.
4. Borra recursos Kubernetes, empezando por el Ingress para permitir que AWS Load Balancer Controller elimine el ALB.
5. Espera un tiempo prudencial para que se eliminen recursos externos asociados.
6. Actualiza `runtime.auto.tfvars`:
    - `create_eks = false`
    - `create_rds = false`
    - `create_nat = false`
    - conserva el OIDC issuer actual si existe
7. Ejecuta `terraform apply`.
8. Terraform destruye los recursos con coste definidos como opcionales.

Recursos que se eliminan con `stop`:

- Cluster EKS
- Node group de EKS
- Add-ons de EKS
- Instancia RDS
- DB subnet group de RDS
- NAT Gateway
- Elastic IP asociada a la NAT
- Rutas privadas hacia NAT
- ALB creado por Kubernetes, si el Ingress se elimina correctamente antes

Recursos que se mantienen:

- VPC
- Subredes
- Internet Gateway
- Tablas de rutas base
- VPC Endpoint para S3
- Bucket S3
- Repositorios ECR
- IAM roles, policies y usuarios
- Security Group de RDS
- OIDC Provider registrado en IAM

### Uso con `-AutoApprove`

Por defecto, el script deja que Terraform pida confirmación manual.

Ejemplo:

```
.\scripts\Cloud.ps1 -Action deploy
```

Para automatizar completamente el proceso:

```
.\scripts\Cloud.ps1 -Action deploy -AutoApprove
.\scripts\Cloud.ps1 -Action stop -AutoApprove
```

Se recomienda usar `-AutoApprove` únicamente cuando el flujo ya haya sido validado previamente.

## Fichero runtime.auto.tfvars

El script `Cloud.ps1` genera o actualiza el fichero:

```
infra/terraform/runtime.auto.tfvars
```

Este fichero contiene los flags de activación de recursos opcionales:

```
create_eks = truecreate_rds = truecreate_nat = true
```

o bien:

```
create_eks = falsecreate_rds = falsecreate_nat = false
```

También puede incluir el OIDC issuer del cluster EKS:

```
eks_oidc_issuer_url = "https://oidc.eks.eu-south-2.amazonaws.com/id/..."
```

Este fichero no debe versionarse en Git, ya que representa estado operativo local generado por el script.

Debe estar incluido en `.gitignore`:

```
infra/terraform/*.auto.tfvars
```

## Orden recomendado de operación

### Desplegar entorno cloud

1. Publicar imágenes en ECR:
    
    ```
    .\scripts\UpdateImages.ps1
    ```
    
2. Desplegar infraestructura y aplicación:
    
    ```
    .\scripts\Cloud.ps1 -Action deploy
    ```
    
3. Consultar estado:
    
    ```
    .\scripts\Cloud.ps1 -Action status
    ```
    
4. Probar la aplicación mediante el DNS del ALB mostrado en el Ingress.

### Detener entorno cloud

1. Ejecutar stop:
    
    ```
    .\scripts\Cloud.ps1 -Action stop
    ```
    
2. Verificar estado:
    
    ```
    .\scripts\Cloud.ps1 -Action status
    ```
    
3. Comprobar que no quedan ALB asociados:
    
    ```
    aws elbv2 describe-load-balancers --region eu-south-2
    ```
    

## Consideraciones de coste

La acción `deploy` crea recursos con coste recurrente:

- EKS
- EC2 del node group
- RDS
- NAT Gateway
- ALB

La acción `stop` debe ejecutarse al finalizar las pruebas para evitar cargos innecesarios.

## Consideraciones de seguridad

- No se versionan secretos reales.
- `secret.local.yaml` debe permanecer fuera de Git.
- Las access keys reales no se gestionan con Terraform.
- El OIDC issuer de EKS se detecta dinámicamente porque cambia cuando se recrea el cluster.
- El acceso a S3 en la arquitectura base usa credenciales configuradas como Secret de Kubernetes; en una evolución Zero Trust puede sustituirse por IRSA.

