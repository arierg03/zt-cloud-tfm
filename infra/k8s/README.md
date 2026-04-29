# Kubernetes - Manifiestos de la aplicación base

Este directorio contiene los manifiestos Kubernetes utilizados para desplegar la aplicación base del TFM sobre el cluster EKS `tfm-app-eks`.

## Relación con Terraform

La infraestructura AWS necesaria para ejecutar el entorno se define en:

```text
infra/terraform
```

Terraform gestiona recursos como:

- VPC, subredes y tablas de rutas
- VPC Endpoint para S3
- repositorios ECR
- bucket S3
- roles y políticas IAM
- definición opcional de EKS, RDS y NAT Gateway

Los manifiestos de este directorio se aplican sobre el cluster EKS una vez que la infraestructura base está disponible.

## Contenido

Este directorio incluye manifiestos para:

- Deployments de los servicios de la aplicación
- Services internos de Kubernetes
- Ingress para exponer la aplicación mediante AWS Load Balancer Controller
- ConfigMaps
- Secrets de referencia
- recursos auxiliares necesarios para la ejecución de la aplicación

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

Ejemplo de uso:

```bash
kubectl apply -f secret.local.yaml
```

## Aplicación de manifiestos

Antes de aplicar los manifiestos, comprobar que `kubectl` apunta al cluster correcto:

```bash
kubectl config current-context
```

Actualizar kubeconfig si es necesario:

```bash
aws eks update-kubeconfig --region eu-south-2 --name tfm-app-eks
```

Aplicar los manifiestos:

```bash
kubectl apply -f infra/k8s
```

O aplicar recursos concretos:

```bash
kubectl apply -f infra/k8s/namespace.yaml
kubectl apply -f infra/k8s/secret.local.yaml
kubectl apply -f infra/k8s/configmap.yaml
kubectl apply -f infra/k8s/aws-lbc-sa.yaml
kubectl apply -f infra/k8s/api.yaml
kubectl apply -f infra/k8s/svc.yaml
kubectl apply -f infra/k8s/web.yaml
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
- Las imágenes de los contenedores se obtienen desde ECR.
- El acceso a S3 se realiza mediante credenciales configuradas como Secret de Kubernetes en la arquitectura base.
- En una evolución Zero Trust, este acceso puede sustituirse por IRSA para evitar credenciales estáticas dentro del cluster.