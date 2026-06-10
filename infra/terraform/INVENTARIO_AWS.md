# Inventario AWS - despliegue Zero Trust

## Región
eu-south-2

## VPC
- ID: vpc-036af3ec3778f5b1c
- CIDR: 10.0.0.0/16
- Nombre: tfm-app-vpc

## Subredes públicas
- subnet-0e9695e3939061ce1 (tfm-app-subnet-public1-eu-south-2a)
- subnet-049f0b27d6340fc0f (tfm-app-subnet-public2-eu-south-2b)

## Subredes privadas
- subnet-0bf6264b0a0ff6873 (tfm-app-subnet-private1-eu-south-2a)
- subnet-0b2a59812663e59d2 (tfm-app-subnet-private2-eu-south-2b)

## Internet Gateway
- ID: igw-086a641052a78ebae
- Nombre: tfm-app-igw
- VPC asociada: vpc-036af3ec3778f5b1c

## Tablas de rutas

### Tabla de rutas pública
- ID: rtb-083cfc4c5a689b3f6
- Nombre: tfm-app-rtb-public
- Subredes asociadas:
  - subnet-0e9695e3939061ce1 (tfm-app-subnet-public1-eu-south-2a)
  - subnet-049f0b27d6340fc0f (tfm-app-subnet-public2-eu-south-2b)
- Rutas:
  - 10.0.0.0/16 -> local
  - 0.0.0.0/0 -> igw-086a641052a78ebae (tfm-app-igw)

### Tabla de rutas privada 1
- ID: rtb-027d0f5547df67cd5
- Nombre: tfm-app-rtb-private1-eu-south-2a
- Subredes asociadas:
  - subnet-0bf6264b0a0ff6873 (tfm-app-subnet-private1-eu-south-2a)
- Rutas:
  - 10.0.0.0/16 -> local
  - ruta hacia VPC Endpoint -> vpce-0751321a9d113c121

### Tabla de rutas privada 2
- ID: rtb-0bbd08a1834142062
- Nombre: tfm-app-rtb-private2-eu-south-2b
- Subredes asociadas:
  - subnet-0b2a59812663e59d2 (tfm-app-subnet-private2-eu-south-2b)
- Rutas:
  - 10.0.0.0/16 -> local
  - ruta hacia VPC Endpoint -> vpce-0751321a9d113c121

### Tabla de rutas principal sin uso explícito
- ID: rtb-051a6eb79acfca406
- Nombre: sin etiqueta Name
- Subredes asociadas: ninguna
- Rutas:
  - 10.0.0.0/16 -> local
- Observación: tabla de rutas principal/default de la VPC, sin asociaciones explícitas.

## Security Groups

### RDS Security Group
- ID: sg-071fa586d4a011325
- Nombre: tfm-app-rds-sg
- Descripción: Created by RDS management console
- Uso: controla el acceso a la base de datos PostgreSQL en RDS.
- Reglas de entrada:
  - TCP 5432 desde sg-04dd3b5cd364fa434 (eks-cluster-sg-tfm-app-eks-20428623)
- Reglas de salida:
  - Todo el tráfico hacia 0.0.0.0/0

### EKS Cluster Security Group
- ID: sg-04dd3b5cd364fa434
- Nombre: eks-cluster-sg-tfm-app-eks-20428623
- Descripción: creado automáticamente por EKS para el plano de control y workloads gestionados.
- Reglas de entrada:
  - TCP 8000-8080 desde sg-087a5a2460bd28898
  - TCP 443 desde tfm-app-admin-bastion-sg
- Reglas de salida:
  - Todo el tráfico hacia 0.0.0.0/0
- Observación: recurso gestionado por EKS. No se modifica manualmente por ahora.

### Load Balancer Managed Security Group
- ID: sg-05f5e2720548ca488
- Nombre: k8s-tfmapp-tfmappin-635e7e9814
- Descripción: [k8s] Managed SecurityGroup for LoadBalancer
- Reglas de entrada:
  - TCP 80 desde 0.0.0.0/0
- Reglas de salida:
  - Todo el tráfico hacia 0.0.0.0/0
- Observación: creado por AWS Load Balancer Controller a partir del Ingress de Kubernetes.

### Load Balancer Backend Security Group
- ID: sg-087a5a2460bd28898
- Nombre: k8s-traffic-tfmappeks-7dd757b3ae
- Descripción: [k8s] Shared Backend SecurityGroup for LoadBalancer
- Reglas de entrada:
  - Ninguna regla explícita de entrada.
- Reglas de salida:
  - Todo el tráfico hacia 0.0.0.0/0
- Observación: creado por AWS Load Balancer Controller para tráfico hacia backends de Kubernetes.

### Default Security Group
- ID: sg-035050643441a5609
- Nombre: default
- Descripción: default VPC security group
- Reglas de entrada:
  - Todo el tráfico desde el propio default security group.
- Reglas de salida:
  - Todo el tráfico hacia 0.0.0.0/0
- Observación: security group por defecto de la VPC. No se utiliza explícitamente para la aplicación.

### Admin Bastion Security Group
- ID: sg-08aadfd87dc8b273e
- Nombre: tfm-app-admin-bastion-sg
- Descripción: Private administration bastion for EKS via SSM
- Uso: controlar la salida de la instancia privada de administración usada para operar EKS.
- Reglas de entrada:
  - Ninguna regla de entrada.
- Reglas de salida:
  - TCP 443 hacia 0.0.0.0/0 para SSM, APIs de AWS y endpoint privado de EKS.
  - UDP 53 hacia el resolver DNS de la VPC.
  - TCP 53 hacia el resolver DNS de la VPC.
- Regla asociada en el security group del cluster EKS:
  - TCP 443 desde tfm-app-admin-bastion-sg hacia el plano de control privado de EKS.

## NAT Gateway

### NAT Gateway para subredes privadas
- Nombre: tfm-app-nat
- Elastic IP: tfm-app-nat-eip
- Subred pública asociada:
  - subnet-0e9695e3939061ce1 (tfm-app-subnet-public1-eu-south-2a)
- Uso:
  - Permitir salida a Internet desde las subredes privadas cuando sea necesario.
- Tablas de rutas privadas asociadas:
  - rtb-027d0f5547df67cd5 (tfm-app-rtb-private1-eu-south-2a)
  - rtb-0bbd08a1834142062 (tfm-app-rtb-private2-eu-south-2b)
- Rutas activables:
  - 0.0.0.0/0 -> NAT Gateway desde tabla privada 1
  - 0.0.0.0/0 -> NAT Gateway desde tabla privada 2

## VPC Endpoint

### Endpoint privado para S3
- ID: vpce-0751321a9d113c121
- Tipo: Gateway Endpoint
- Servicio: com.amazonaws.eu-south-2.s3
- Tablas de rutas asociadas:
  - rtb-027d0f5547df67cd5 (tfm-app-rtb-private1-eu-south-2a)
  - rtb-0bbd08a1834142062 (tfm-app-rtb-private2-eu-south-2b)
- Uso:
  - Permitir acceso privado desde las subredes privadas a S3 sin requerir salida directa a Internet mediante NAT Gateway.

## ECR

### Repositorio WEB
- Nombre: zt/web
- URI: 296368270177.dkr.ecr.eu-south-2.amazonaws.com/zt/web
- Cifrado: AES256
- Scan on push: false

### Repositorio API
- Nombre: zt/api
- URI: 296368270177.dkr.ecr.eu-south-2.amazonaws.com/zt/api
- Cifrado: AES256
- Scan on push: false

### Repositorio SVC
- Nombre: zt/svc
- URI: 296368270177.dkr.ecr.eu-south-2.amazonaws.com/zt/svc
- Cifrado: AES256
- Scan on push: false

## S3

### Bucket de imágenes
- Nombre: events-images-296368270177-eu-south-2-an
- Región: eu-south-2
- Uso: almacenamiento de imágenes asociadas a eventos.
- Bloqueo de acceso público:
  - BlockPublicAcls: true
  - IgnorePublicAcls: true
  - BlockPublicPolicy: true
  - RestrictPublicBuckets: true
- Cifrado:
  - SSE-S3 / AES256
- Versionado:
  - No configurado
- Observación:
  - El bucket no es público. El acceso desde los workloads se realiza mediante roles IAM asociados a ServiceAccounts (IRSA).

### Bucket de artefactos Kubernetes
- Nombre: tfm-app-k8s-artifacts-296368270177-eu-south-2
- Región: eu-south-2
- Uso: almacenamiento temporal de paquetes de manifiestos Kubernetes usados por `Cloud.ps1` para operar el cluster desde el bastion privado.
- Bloqueo de acceso público:
  - BlockPublicAcls: true
  - IgnorePublicAcls: true
  - BlockPublicPolicy: true
  - RestrictPublicBuckets: true
- Cifrado:
  - SSE-S3 / AES256
- Ciclo de vida:
  - Expiración de objetos bajo `manifests/` a los 7 días.
- Acceso:
  - Lectura limitada al rol `tfm-app-admin-bastion-role`.
- Observación:
  - Se usa como canal controlado para transferir manifiestos al bastion sin exponer el endpoint público de EKS.

### Bucket de logs de CloudTrail
- Nombre: tfm-app-cloudtrail-296368270177-eu-south-2
- Región: eu-south-2
- Uso: almacenamiento de logs de auditoría generados por CloudTrail.
- Bloqueo de acceso público:
  - BlockPublicAcls: true
  - IgnorePublicAcls: true
  - BlockPublicPolicy: true
  - RestrictPublicBuckets: true
- Cifrado:
  - SSE-S3 / AES256
- Ownership:
  - BucketOwnerPreferred
- Versionado:
  - Habilitado
- Ciclo de vida:
  - Expiración de logs bajo `AWSLogs/` a los 30 días.
  - Expiración de versiones no actuales a los 30 días.
- Política de bucket:
  - Permite `s3:GetBucketAcl` al servicio `cloudtrail.amazonaws.com`.
  - Permite `s3:PutObject` al servicio `cloudtrail.amazonaws.com` bajo `AWSLogs/296368270177/*`.
  - Restringe ambas acciones mediante `aws:SourceArn` del trail `tfm-app-zt-audit-trail`.
  - Exige ACL `bucket-owner-full-control` en escritura.

## RDS

### Instancia PostgreSQL
- Identificador: tfm-app-rds
- Engine: PostgreSQL
- Versión: 16
- Clase de instancia: db.t4g.micro
- Almacenamiento asignado: 20 GB
- Tipo de almacenamiento: gp3
- Cifrado en reposo: true
- Nombre de base de datos: events
- Usuario administrador: events_user
- Puerto: 5432
- Acceso público: false
- Multi-AZ: false
- Backups automáticos: desactivados
- Protección frente a borrado: desactivada
- Subnet group: tfm-app-rds-subnet-group
- Subredes del subnet group:
  - subnet-0bf6264b0a0ff6873 (tfm-app-subnet-private1-eu-south-2a)
  - subnet-0b2a59812663e59d2 (tfm-app-subnet-private2-eu-south-2b)
- Security group:
  - sg-071fa586d4a011325 (tfm-app-rds-sg)
- Regla de acceso:
  - Entrada TCP 5432 únicamente desde sg-04dd3b5cd364fa434 (eks-cluster-sg-tfm-app-eks-20428623)

## EKS

### Cluster Kubernetes
- Nombre del cluster: tfm-app-eks
- Versión Kubernetes: 1.35
- Modo automático de EKS: desactivado
- Política de actualización: soporte estándar
- Rol IAM del cluster: arn:aws:iam::296368270177:role/tfm-app-eks-cluster-role
- Política asociada al rol del cluster:
  - AmazonEKSClusterPolicy
- Modo de autenticación: API de EKS y ConfigMap
- Acceso de administrador del cluster de Kubernetes: habilitado
- Nivel de escalado del plano de control: estándar
- Protección contra eliminaciones: desactivada
- VPC:
  - vpc-036af3ec3778f5b1c (tfm-app-vpc)
- Familia de direcciones IP del cluster: IPv4
- Subredes asociadas:
  - subnet-0bf6264b0a0ff6873 (tfm-app-subnet-private1-eu-south-2a)
  - subnet-0b2a59812663e59d2 (tfm-app-subnet-private2-eu-south-2b)
- Acceso al endpoint del cluster:
  - Público: deshabilitado
  - Privado: habilitado
- Métricas:
  - Desactivadas
- Registros del plano de control:
  - API server
  - Audit
  - Authenticator
- Complementos:
  - kube-proxy: v1.35.3-eksbuild.2
  - CoreDNS: v1.13.2-eksbuild.4
  - Amazon VPC CNI: v1.21.1-eksbuild.1
    - NetworkPolicy: habilitado
- Uso:
  - Orquestación de los contenedores de la aplicación en el entorno Zero Trust.

### Node group
- Nombre: tfm-app-ng
- Tipo: Managed Node Group
- Versión Kubernetes: 1.35
- Tipo de capacidad: On-Demand
- Tipo de AMI: Amazon Linux 2023 (x86_64) estándar
- AMI type: AL2023_x86_64_STANDARD
- Tipo de instancia: t3.medium
- Tamaño de disco: 20 GiB
- Tamaño deseado: 1 nodo
- Tamaño mínimo: 1 nodo
- Tamaño máximo: 1 nodo
- Grupo en caliente del ASG: desactivado
- Máximo no disponible durante actualización: 1 nodo
- Reparación automática de nodos: desactivada
- Acceso remoto a los nodos: desactivado
- Subredes asociadas:
  - subnet-0bf6264b0a0ff6873 (tfm-app-subnet-private1-eu-south-2a)
  - subnet-0b2a59812663e59d2 (tfm-app-subnet-private2-eu-south-2b)
- Rol IAM de los nodos:
  - arn:aws:iam::296368270177:role/tfm-app-eks-node-role
- Políticas administradas asociadas al rol de nodos:
  - AmazonEC2ContainerRegistryReadOnly
  - AmazonEKS_CNI_Policy
  - AmazonEKSWorkerNodePolicy
- Uso:
  - Ejecución de los pods de la aplicación.
- Observación:
  - Los permisos S3 de los workloads ya no se concentran en el rol de nodos. Se asignan mediante IRSA a los ServiceAccounts correspondientes.

### Access Entry para bastion de administración
- Principal: arn:aws:iam::296368270177:role/tfm-app-admin-bastion-role
- Tipo: STANDARD
- Política asociada:
  - AmazonEKSClusterAdminPolicy
- Alcance:
  - Cluster completo
- Uso:
  - Permitir que el bastion privado administre el cluster EKS mediante el modo de autenticación API de EKS.

## EC2

### Bastion privado de administración
- ID: i-0af024aa0937d2fbd (ejemplo, el id es variable)
- Nombre: tfm-app-admin-bastion
- Tipo de instancia: t3.micro
- AMI: Amazon Linux 2023 x86_64
- AMI ID: ami-02b090dacc60230c9
- AMI name: al2023-ami-2023.12.20260608.0-kernel-6.1-x86_64
- Subred asociada:
  - subnet-0bf6264b0a0ff6873 (tfm-app-subnet-private1-eu-south-2a)
- IP privada: 10.0.129.41
- IP pública asociada: no
- Security group:
  - tfm-app-admin-bastion-sg
- IAM instance profile:
  - tfm-app-admin-bastion-profile
- Metadata options:
  - IMDS habilitado
  - IMDSv2 obligatorio
- Bootstrap:
  - `infra/terraform/scripts/admin-bastion.sh`
- Uso:
  - Ejecutar operaciones administrativas de Kubernetes desde red privada mediante SSM Session Manager.
  - Descargar artefactos Kubernetes desde el bucket S3 privado `tfm-app-k8s-artifacts-296368270177-eu-south-2`.
- Observación:
  - No expone SSH ni reglas de entrada. La administración se realiza mediante SSM.

## CloudTrail

### Trail de auditoría Zero Trust
- Nombre: tfm-app-zt-audit-trail
- ARN: arn:aws:cloudtrail:eu-south-2:296368270177:trail/tfm-app-zt-audit-trail
- Bucket de destino:
  - tfm-app-cloudtrail-296368270177-eu-south-2
- Eventos globales de servicios AWS:
  - Incluidos
- Trail multi-región:
  - Habilitado
- Validación de integridad de logs:
  - Habilitada
- Event selector:
  - Eventos de gestión: incluidos
  - Tipo lectura/escritura: All
- Uso:
  - Registrar actividad de gestión sobre la cuenta AWS como control de auditoría del entorno Zero Trust.

## IAM

### Rol IRSA para API
- Nombre: tfm-app-api-irsa-role
- ARN: arn:aws:iam::296368270177:role/tfm-app-api-irsa-role
- Uso:
  - Permitir que el ServiceAccount `tfm-app/api` acceda al bucket de imágenes sin credenciales AWS estáticas.
- Mecanismo de confianza:
  - IRSA mediante OIDC provider de EKS.
- ServiceAccount autorizado:
  - tfm-app/api
- Política asociada:
  - tfm-app-api-s3-images-policy
- Permisos de la política:
  - s3:ListBucket sobre arn:aws:s3:::events-images-296368270177-eu-south-2-an
  - s3:GetObject, s3:PutObject, s3:DeleteObject sobre arn:aws:s3:::events-images-296368270177-eu-south-2-an/*

### Rol IRSA para SVC
- Nombre: tfm-app-svc-irsa-role
- ARN: arn:aws:iam::296368270177:role/tfm-app-svc-irsa-role
- Uso:
  - Permitir que el ServiceAccount `tfm-app/svc` acceda al bucket de imágenes sin credenciales AWS estáticas.
- Mecanismo de confianza:
  - IRSA mediante OIDC provider de EKS.
- ServiceAccount autorizado:
  - tfm-app/svc
- Política asociada:
  - tfm-app-svc-s3-images-policy
- Permisos de la política:
  - s3:ListBucket sobre arn:aws:s3:::events-images-296368270177-eu-south-2-an
  - s3:GetObject, s3:PutObject sobre arn:aws:s3:::events-images-296368270177-eu-south-2-an/*

### Rol IAM para bastion privado de administración
- Nombre: tfm-app-admin-bastion-role
- ARN: arn:aws:iam::296368270177:role/tfm-app-admin-bastion-role
- Uso:
  - Permitir administración privada de EKS desde una instancia EC2 gestionada por SSM.
- Trust policy:
  - Servicio EC2 (`ec2.amazonaws.com`).
- Instance profile:
  - tfm-app-admin-bastion-profile
- Políticas asociadas:
  - AmazonSSMManagedInstanceCore
  - tfm-app-admin-bastion-eks-policy
  - tfm-app-admin-bastion-k8s-artifacts-policy
- Permisos EKS:
  - eks:DescribeCluster sobre el cluster `tfm-app-eks`.
- Permisos S3:
  - s3:ListBucket sobre arn:aws:s3:::tfm-app-k8s-artifacts-296368270177-eu-south-2 limitado al prefijo `manifests/*`.
  - s3:GetObject sobre arn:aws:s3:::tfm-app-k8s-artifacts-296368270177-eu-south-2/manifests/*
- Acceso Kubernetes:
  - Asociado al cluster mediante EKS Access Entry y AmazonEKSClusterAdminPolicy.

### OIDC Provider de EKS
- ARN: arn:aws:iam::296368270177:oidc-provider/oidc.eks.eu-south-2.amazonaws.com/id/AEEB296AFF3D3A228A7647FC3C1E89A1
- URL: https://oidc.eks.eu-south-2.amazonaws.com/id/AEEB296AFF3D3A228A7647FC3C1E89A1
- Client ID:
  - sts.amazonaws.com
- Tags de origen:
  - alpha.eksctl.io/cluster-name: tfm-app-eks
  - alpha.eksctl.io/eksctl-version: 0.225.0
- Uso:
  - Habilitar federación OIDC entre EKS e IAM.
  - Permitir el uso de IRSA para asociar permisos IAM a service accounts de Kubernetes.
  - Dar soporte al rol `AmazonEKSLoadBalancerControllerRole`, usado por el service account `kube-system/aws-load-balancer-controller`.

### Rol IAM para AWS Load Balancer Controller
- Nombre: AmazonEKSLoadBalancerControllerRole
- ARN: arn:aws:iam::296368270177:role/AmazonEKSLoadBalancerControllerRole
- Uso:
  - Permitir que el AWS Load Balancer Controller gestione recursos de balanceo de carga en AWS desde Kubernetes.
  - Creación y gestión de Application Load Balancers, listeners, target groups y reglas asociadas al Ingress de Kubernetes.
- Mecanismo de confianza:
  - IRSA mediante OIDC provider de EKS.
- OIDC provider:
  - arn:aws:iam::296368270177:oidc-provider/oidc.eks.eu-south-2.amazonaws.com/id/AEEB296AFF3D3A228A7647FC3C1E89A1
- ServiceAccount autorizado:
  - kube-system/aws-load-balancer-controller
- Política asociada:
  - AWSLoadBalancerControllerIAMPolicy
- ARN de la política:
  - arn:aws:iam::296368270177:policy/AWSLoadBalancerControllerIAMPolicy
- Descripción de la política:
  - Policy descargada de raw.githubusercontent.com aws-load-balancer-controller.
- Observación:
  - Este rol permite que el controlador desplegado en Kubernetes interactúe con servicios de AWS mediante federación OIDC, evitando el uso de credenciales estáticas dentro del cluster.

