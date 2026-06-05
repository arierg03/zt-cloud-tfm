# Administracion privada de Kubernetes en EKS

Esta guia documenta la operacion de Kubernetes cuando el plano de control de EKS se administra desde un bastion privado mediante AWS Systems Manager Session Manager.

El equipo local mantiene Terraform y AWS CLI. Las operaciones `kubectl` y `helm` se ejecutan en el bastion mediante SSM.

## Flujo recomendado

Desplegar infraestructura y Kubernetes:

```powershell
.\scripts\Cloud.ps1 -Action deploy -RemoteKubernetes -EnvName zt
```

Consultar estado:

```powershell
.\scripts\Cloud.ps1 -Action status -RemoteKubernetes -EnvName zt
```

Parar el entorno:

```powershell
.\scripts\Cloud.ps1 -Action stop -RemoteKubernetes -EnvName zt
```

## Que hace `-RemoteKubernetes`

En `deploy`:

- levanta la infraestructura con Terraform desde el equipo local;
- crea el bastion privado si EKS esta activo;
- comprime `infra/k8s`;
- sube el paquete al bucket S3 de artefactos Kubernetes;
- espera a que el bastion este registrado en SSM;
- ejecuta en el bastion `aws eks update-kubeconfig`, `kubectl apply` y `helm upgrade --install`;
- no requiere `kubectl`, `helm`, SSH ni Git en el equipo local o en el bastion.

En `status`:

- consulta Terraform, EKS, RDS y NAT desde el equipo local;
- consulta nodos, pods, servicios, ingress, NetworkPolicies y AWS Load Balancer Controller desde el bastion.

En `stop`:

- borra el Ingress desde el bastion;
- espera a que el Ingress desaparezca;
- borra los recursos Kubernetes restantes por tipo y nombre;
- cambia las variables runtime a `false`;
- destruye con Terraform la infraestructura con coste.

## Canal de artefactos

Los manifiestos se transfieren al bastion mediante S3:

```text
s3://tfm-app-k8s-artifacts-296368270177-eu-south-2/manifests/
```

El bucket es privado, tiene bloqueo de acceso publico, cifrado SSE-S3 y ciclo de vida para expirar artefactos temporales.

El bastion solo necesita permisos de lectura sobre el prefijo `manifests/*`.

## Validacion manual

Obtener el ID del bastion:

```powershell
$instanceId = terraform -chdir=infra/terraform output -raw admin_bastion_instance_id
```

Abrir sesion SSM:

```powershell
aws ssm start-session --region eu-south-2 --target $instanceId
```

Dentro del bastion:

```bash
aws eks update-kubeconfig --region eu-south-2 --name tfm-app-eks
kubectl get nodes
kubectl -n tfm-app get pods,svc,ingress,networkpolicy
kubectl -n kube-system get deployment aws-load-balancer-controller
```

## Fallback de parada

Si falla el modo remoto durante la parada, entrar al bastion por SSM y ejecutar:

```bash
aws eks update-kubeconfig --region eu-south-2 --name tfm-app-eks

kubectl -n tfm-app delete ingress tfm-app-ingress --ignore-not-found=true
kubectl -n tfm-app delete networkpolicy --all --ignore-not-found=true
kubectl -n tfm-app delete deployment api web --ignore-not-found=true
kubectl -n tfm-app delete service api web svc --ignore-not-found=true
kubectl -n tfm-app delete serviceaccount api svc --ignore-not-found=true
kubectl -n tfm-app delete configmap --all --ignore-not-found=true
kubectl -n tfm-app delete secret --all --ignore-not-found=true
kubectl -n kube-system delete serviceaccount aws-load-balancer-controller --ignore-not-found=true
```

Despues, desde el equipo local:

```powershell
.\scripts\Cloud.ps1 -Action stop -SkipKubernetes -EnvName zt
```

## Notas Zero Trust

- No se expone SSH en el bastion.
- No se necesita clonar el repositorio en el bastion.
- No se necesita `kubectl` local cuando se usa `-RemoteKubernetes`.
- La administracion Kubernetes queda mediada por IAM, SSM y el rol del bastion.
- Cuando el endpoint publico de EKS se deshabilite, la operacion seguira funcionando desde el bastion mediante el endpoint privado.
