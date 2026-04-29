# Inventario AWS - despliegue base

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
  - 0.0.0.0/0 -> nat-0f05d474d04b2e2f8
  - ruta hacia VPC Endpoint -> vpce-0751321a9d113c121

### Tabla de rutas privada 2
- ID: rtb-0bbd08a1834142062
- Nombre: tfm-app-rtb-private2-eu-south-2b
- Subredes asociadas:
  - subnet-0b2a59812663e59d2 (tfm-app-subnet-private2-eu-south-2b)
- Rutas:
  - 10.0.0.0/16 -> local
  - 0.0.0.0/0 -> nat-0f05d474d04b2e2f8
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

## EKS
- Cluster: tfm-app-eks
- Node group: tfm-app-ng
- Versión Kubernetes: 1.35

## RDS
- Identificador: tfm-app-rds
- Engine: PostgreSQL
- Versión: 16
- Subnet group: tfm-app-rds-subnet-group (2 privadas)
- Security group: sg-071fa586d4a011325 (tfm-app-rds-sg)

## S3
- Bucket imágenes: events-images-296368270177-eu-south-2-an

## ECR
- Repositorio API: 296368270177.dkr.ecr.eu-south-2.amazonaws.com/zt/api
- Repositorio WEB: 296368270177.dkr.ecr.eu-south-2.amazonaws.com/zt/web
- Repositorio SVC: 296368270177.dkr.ecr.eu-south-2.amazonaws.com/zt/svc