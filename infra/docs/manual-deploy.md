# Despliegue manual en AWS

Este documento recoge el procedimiento manual utilizado como referencia inicial para desplegar la aplicación base en AWS.

> Estado del documento: referencia histórica / procedimiento manual.
>
> El flujo recomendado actualmente para operar el entorno cloud es utilizar Terraform y los scripts del directorio `scripts`, especialmente `Cloud.ps1` y `UpdateImages.ps1`.

## Objetivo

Desplegar la aplicación base del TFM en AWS usando:

- ECR para almacenar imágenes Docker.
- S3 para almacenar imágenes de eventos.
- RDS PostgreSQL para persistencia.
- EKS para ejecutar los contenedores.
- AWS Load Balancer Controller para crear un ALB a partir del Ingress de Kubernetes.
- IAM, OIDC e IRSA para permisos asociados a EKS y al Load Balancer Controller.

## Prerrequisitos

Herramientas necesarias:

- AWS CLI v2
- Docker
- kubectl
- Helm
- eksctl
- curl

La AWS CLI debe estar autenticada:

```bash
aws sts get-caller-identity
```

Variables sugeridas:

```bash
export AWS_REGION=eu-south-2
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export CLUSTER_NAME=tfm-app-eks
export DB_NAME=events
export DB_USER=events_user
export DB_PASSWORD='REEMPLAZAR_PASSWORD'
export S3_BUCKET_NAME="events-images-${AWS_ACCOUNT_ID}-${AWS_REGION}"
```

## 1. Publicar imágenes en ECR

Antes de desplegar en EKS, las imágenes deben estar publicadas en ECR.

Repositorios esperados:

- `zt/api`
- `zt/web`
- `zt/svc`

En Windows:

```powershell
.\scripts\UpdateImages.ps1
```

En Linux:

```bash
bash ./scripts/update-images.sh
```

También puede hacerse manualmente con Docker y AWS CLI, pero se recomienda usar los scripts del repositorio.

## 2. Crear bucket S3

Crear el bucket:

```bash
aws s3api create-bucket \
  --bucket "$S3_BUCKET_NAME" \
  --region "$AWS_REGION" \
  --create-bucket-configuration LocationConstraint="$AWS_REGION"
```

Validar existencia:

```bash
aws s3api head-bucket --bucket "$S3_BUCKET_NAME"
```

Bloquear acceso público:

```bash
aws s3api put-public-access-block \
  --bucket "$S3_BUCKET_NAME" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

Configurar cifrado SSE-S3:

```bash
aws s3api put-bucket-encryption \
  --bucket "$S3_BUCKET_NAME" \
  --server-side-encryption-configuration '{
    "Rules": [
      {
        "ApplyServerSideEncryptionByDefault": {
          "SSEAlgorithm": "AES256"
        }
      }
    ]
  }'
```

## 3. Crear VPC, EKS y Node Group

Una opción sencilla para una primera validación es `eksctl`.

```bash
eksctl create cluster \
  --name "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --version 1.35 \
  --nodegroup-name tfm-app-ng \
  --node-type t3.medium \
  --nodes 1 \
  --nodes-min 1 \
  --nodes-max 1 \
  --managed
```

Actualizar kubeconfig:

```bash
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME"
```

Comprobar nodos:

```bash
kubectl get nodes
```

## 4. Crear RDS PostgreSQL

Crear un DB Subnet Group usando subredes privadas de la VPC:

```bash
aws rds create-db-subnet-group \
  --db-subnet-group-name tfm-app-rds-subnet-group \
  --db-subnet-group-description "Subred para RDS con redes privadas unicamente" \
  --subnet-ids subnet-AAAA subnet-BBBB
```

Crear una instancia PostgreSQL:

```bash
aws rds create-db-instance \
  --db-instance-identifier tfm-app-rds \
  --engine postgres \
  --engine-version 16 \
  --db-instance-class db.t4g.micro \
  --allocated-storage 20 \
  --storage-type gp3 \
  --master-username "$DB_USER" \
  --master-user-password "$DB_PASSWORD" \
  --db-name "$DB_NAME" \
  --vpc-security-group-ids sg-XXXXXXXX \
  --db-subnet-group-name tfm-app-rds-subnet-group \
  --backup-retention-period 0 \
  --storage-encrypted \
  --no-publicly-accessible
```

Obtener endpoint:

```bash
aws rds describe-db-instances \
  --db-instance-identifier tfm-app-rds \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text
```

## 5. Configurar IAM para acceso a S3

En la arquitectura base se utilizó un usuario IAM con access keys para que la aplicación accediese al bucket S3.

Usuario:

```text
tfm-app-s3-user
```

Política asociada:

```text
tfm-app-s3-user-policy
```

Permisos requeridos:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListBucket",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket"
      ],
      "Resource": "arn:aws:s3:::events-images-296368270177-eu-south-2-an"
    },
    {
      "Sid": "ObjectAccess",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject"
      ],
      "Resource": "arn:aws:s3:::events-images-296368270177-eu-south-2-an/*"
    }
  ]
}
```

Las access keys generadas se introducen en el Secret de Kubernetes local:

```text
infra/k8s/secret.local.yaml
```

No deben versionarse en Git.

## 6. Asociar OIDC al cluster EKS

Para permitir IRSA:

```bash
eksctl utils associate-iam-oidc-provider \
  --region "$AWS_REGION" \
  --cluster "$CLUSTER_NAME" \
  --approve
```

Comprobar issuer OIDC:

```bash
aws eks describe-cluster \
  --region "$AWS_REGION" \
  --name "$CLUSTER_NAME" \
  --query "cluster.identity.oidc.issuer" \
  --output text
```

> Nota: el issuer OIDC cambia si el cluster EKS se destruye y se vuelve a crear.

## 7. Configurar AWS Load Balancer Controller

Descargar la política oficial:

```bash
curl -o iam_policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
```

Crear la política IAM:

```bash
aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json
```

Crear o asociar el rol IAM del Load Balancer Controller. En este proyecto se utilizó:

```text
AmazonEKSLoadBalancerControllerRole
```

El rol debe confiar en el OIDC provider del cluster y permitir al ServiceAccount:

```text
system:serviceaccount:kube-system:aws-load-balancer-controller
```

Aplicar el ServiceAccount:

```bash
kubectl apply -f infra/k8s/aws-lbc-sa.yaml
```

Instalar el controller con Helm:

```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName="$CLUSTER_NAME" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region="$AWS_REGION" \
  --set vpcId=<VPC_ID>
```

Comprobar estado:

```bash
kubectl -n kube-system rollout status deployment/aws-load-balancer-controller --timeout=300s
kubectl -n kube-system get pods
```

## 8. Preparar manifiestos Kubernetes

Revisar:

```text
infra/k8s/configmap.yaml
infra/k8s/secret.yaml
infra/k8s/secret.local.yaml
infra/k8s/ingress.yaml
```

Campos relevantes:

- `POSTGRES_HOST`: endpoint de RDS.
- `POSTGRES_DB`: nombre de base de datos.
- `POSTGRES_USER`: usuario de base de datos.
- `POSTGRES_PASSWORD`: contraseña de base de datos.
- `S3_BUCKET`: bucket S3.
- `S3_REGION`: región S3.
- `S3_ACCESS_KEY`: access key del usuario IAM.
- `S3_SECRET_KEY`: secret key del usuario IAM.
- `VITE_API_URL`: normalmente `/api` para despliegue tras ALB.

## 9. Aplicar manifiestos Kubernetes

Orden recomendado:

```bash
kubectl apply -f infra/k8s/namespace.yaml
kubectl apply -f infra/k8s/secret.local.yaml
kubectl apply -f infra/k8s/configmap.yaml
kubectl apply -f infra/k8s/api.yaml
kubectl apply -f infra/k8s/svc.yaml
kubectl apply -f infra/k8s/web.yaml
kubectl apply -f infra/k8s/ingress.yaml
```

Comprobar estado:

```bash
kubectl -n tfm-app get pods,svc,ingress
kubectl -n tfm-app describe ingress tfm-app-ingress
```

Cuando el Ingress tenga `ADDRESS`, probar:

```bash
curl http://<ALB_DNS>/api/health
```

Y en navegador:

```text
http://<ALB_DNS>/
```

## 10. Consideraciones de red

En el despliegue base:

- Las subredes públicas tienen ruta a Internet Gateway.
- Las subredes privadas no tienen exposición directa a Internet.
- La salida desde subredes privadas puede realizarse mediante NAT Gateway.
- El acceso privado a S3 puede realizarse mediante VPC Endpoint Gateway.
- RDS se despliega sin acceso público.
- El Security Group de RDS permite entrada TCP 5432 desde el Security Group del cluster EKS.

## 11. Health checks

El Ingress utiliza:

```text
alb.ingress.kubernetes.io/healthcheck-path: /api/health
```

La API debe responder correctamente en:

```text
/api/health
```

## 12. Limpieza manual de recursos con coste

Al terminar las pruebas, se deben eliminar o detener los recursos con coste:

- EKS
- Node Group / EC2
- RDS
- NAT Gateway
- Elastic IP asociada a NAT
- ALB creado por Kubernetes

Primero eliminar el Ingress para permitir que AWS Load Balancer Controller borre el ALB:

```bash
kubectl delete -f infra/k8s/ingress.yaml --ignore-not-found=true
```

Después eliminar el resto de recursos Kubernetes:

```bash
kubectl delete -f infra/k8s/web.yaml --ignore-not-found=true
kubectl delete -f infra/k8s/api.yaml --ignore-not-found=true
kubectl delete -f infra/k8s/svc.yaml --ignore-not-found=true
kubectl delete -f infra/k8s/configmap.yaml --ignore-not-found=true
kubectl delete -f infra/k8s/secret.local.yaml --ignore-not-found=true
```

Comprobar que no quedan ALB:

```bash
aws elbv2 describe-load-balancers \
  --region "$AWS_REGION" \
  --query "LoadBalancers[?contains(LoadBalancerName, 'k8s')].{Name:LoadBalancerName,DNS:DNSName,State:State.Code}" \
  --output table
```

Eliminar EKS con `eksctl` si fue creado de esta forma:

```bash
eksctl delete cluster \
  --region "$AWS_REGION" \
  --name "$CLUSTER_NAME"
```

Eliminar RDS:

```bash
aws rds delete-db-instance \
  --db-instance-identifier tfm-app-rds \
  --skip-final-snapshot
```

Eliminar NAT Gateway:

```bash
aws ec2 delete-nat-gateway \
  --nat-gateway-id nat-XXXXXXXX
```

Liberar Elastic IP:

```bash
aws ec2 release-address \
  --allocation-id eipalloc-XXXXXXXX
```

## 13. Limitaciones del procedimiento manual

Este procedimiento es útil como referencia, pero presenta limitaciones:

- Mayor probabilidad de errores manuales.
- Menor reproducibilidad.
- Mayor riesgo de dejar recursos con coste activos.
- El OIDC issuer cambia si se recrea EKS.
- La eliminación del Ingress debe hacerse antes de destruir EKS para evitar ALB colgados.
- Las rutas NAT pueden quedar en estado `blackhole` si se elimina una NAT Gateway sin limpiar rutas.
- La configuración de IAM/OIDC es sensible al orden de creación.

Por estos motivos, el flujo recomendado actualmente es utilizar:

```powershell
.\scripts\Cloud.ps1 deploy
.\scripts\Cloud.ps1 status
.\scripts\Cloud.ps1 stop
```

y consultar:

```text
infra/terraform/README.md
infra/k8s/README.md
scripts/README.md
```
