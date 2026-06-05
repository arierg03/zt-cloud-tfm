# Kubernetes - Manifiestos de la aplicacion

Este directorio contiene los manifiestos Kubernetes utilizados para desplegar la aplicacion del TFM sobre el cluster EKS `tfm-app-eks`.

Los manifiestos forman parte de la migracion Zero Trust y cubren identidad por workload, segmentacion interna, endurecimiento de contenedores y operacion privada del cluster.

## Relacion con Terraform

La infraestructura AWS necesaria para ejecutar el entorno se define en:

```text
infra/terraform
```

Terraform gestiona recursos como:

- VPC, subredes y tablas de rutas.
- VPC Endpoint para S3.
- Repositorios ECR.
- Buckets S3 de imagenes y artefactos Kubernetes.
- Roles y politicas IAM.
- OIDC Provider e IRSA.
- EKS, RDS, NAT Gateway y bastion privado de administracion.

Los manifiestos de este directorio se aplican sobre el cluster EKS una vez que la infraestructura esta disponible.

## Contenido

Este directorio incluye manifiestos para:

- Namespace `tfm-app`.
- ConfigMaps.
- Secrets de referencia y secret local no versionado.
- ServiceAccounts de workloads con anotaciones IRSA.
- Deployments de `api`, `web` y `svc`.
- Services internos de Kubernetes.
- Ingress para exponer la aplicacion mediante AWS Load Balancer Controller.
- NetworkPolicies para segmentacion interna.
- Recursos auxiliares necesarios para la ejecucion de la aplicacion.

## Bloques Zero Trust

### 1. Identidad y permisos por workload

Los workloads usan ServiceAccounts especificos asociados a roles IAM mediante IRSA. Esto permite reducir el uso de credenciales AWS estaticas dentro del cluster.

Manifiesto principal:

```text
serviceaccounts.yaml
```

### 2. Segmentacion interna

El namespace `tfm-app` aplica NetworkPolicies para restringir trafico de entrada:

- Denegacion por defecto de trafico ingress.
- Permiso desde el ALB hacia `web`.
- Permiso desde `web` hacia `api`.
- Permiso desde el ALB hacia `api` cuando sea necesario.

Manifiesto principal:

```text
networkpolicy.yaml
```

### 3. Endurecimiento de workloads

Los Deployments incorporan controles de seguridad como:

- `seccompProfile: RuntimeDefault`.
- `allowPrivilegeEscalation: false`.
- Eliminacion de Linux capabilities con `drop: ["ALL"]`.
- Requests y limits de CPU/memoria.
- Ejecucion no privilegiada siempre que el contenedor lo permite.

Manifiestos principales:

```text
api.yaml
web.yaml
svc.yaml
```

### 4. Administracion privada de EKS

El endpoint publico de EKS esta deshabilitado. Por tanto, las operaciones de Kubernetes no deben depender de `kubectl` local, sino del flujo remoto integrado en `Cloud.ps1`.

Documentacion especifica:

```text
ADMINISTRACION_PRIVADA_EKS.md
```

## Secrets

Los secretos reales no se versionan en Git.

Se mantiene un fichero de referencia:

```text
secret.yaml
```

El fichero con valores reales debe mantenerse en local:

```text
secret.local.yaml
```

Este fichero debe estar incluido en `.gitignore`.

## Aplicacion de manifiestos

Flujo recomendado para el entorno Zero Trust:

```powershell
.\scripts\Cloud.ps1 -Action deploy -RemoteKubernetes -EnvName zt
.\scripts\Cloud.ps1 -Action status -RemoteKubernetes -EnvName zt
.\scripts\Cloud.ps1 -Action stop -RemoteKubernetes -EnvName zt
```

En este modo, `Cloud.ps1` comprime los manifiestos de `infra/k8s`, publica el artefacto en S3 y ejecuta `kubectl` desde el bastion privado mediante SSM.

Para entornos donde el endpoint publico de EKS este habilitado o el operador este dentro de la red privada, se pueden aplicar manualmente:

```powershell
aws eks update-kubeconfig --region eu-south-2 --name tfm-app-eks
kubectl apply -f infra/k8s
```

O aplicar recursos concretos:

```powershell
kubectl apply -f infra/k8s/namespace.yaml
kubectl apply -f infra/k8s/secret.local.yaml
kubectl apply -f infra/k8s/configmap.yaml
kubectl apply -f infra/k8s/aws-lbc-sa.yaml
kubectl apply -f infra/k8s/serviceaccounts.yaml
kubectl apply -f infra/k8s/api.yaml
kubectl apply -f infra/k8s/svc.yaml
kubectl apply -f infra/k8s/web.yaml
kubectl apply -f infra/k8s/networkpolicy.yaml
kubectl apply -f infra/k8s/ingress.yaml
```

## AWS Load Balancer Controller

El Ingress de Kubernetes se utiliza junto con AWS Load Balancer Controller para crear y gestionar el Application Load Balancer en AWS.

El rol IAM asociado es:

```text
AmazonEKSLoadBalancerControllerRole
```

Este rol utiliza IRSA mediante el OIDC Provider de EKS y el ServiceAccount:

```text
kube-system/aws-load-balancer-controller
```

## Notas

- El Application Load Balancer y sus recursos asociados se generan desde Kubernetes, no directamente desde Terraform.
- Las imagenes de los contenedores se obtienen desde ECR.
- El ALB publico sigue siendo la entrada de usuario a la aplicacion.
- La administracion del plano de control de EKS se realiza desde red privada mediante bastion y SSM.
