# zt-cloud-tfm

Repositorio del TFM sobre un enfoque Zero Trust en entorno cloud.

## Stack

- API: FastAPI + SQLAlchemy + Alembic
- Web: React (Vite)
- Base de datos: PostgreSQL 16
- Almacenamiento de imagenes: MinIO (S3 compatible)
- Proceso batch: servicio `svc` en Python
- Orquestacion local: Docker Compose

## Ejecución local rápida

1. Copiar variables de entorno:

```bash
cp .env.example .env
```

2. Revisar `.env` y cambiar al menos `API_SECRET_KEY`.
3. Levantar servicios:

```bash
docker compose up --build
```

4. URLs útiles en local:
- API: `http://localhost:8000`
- Docs Swagger: `http://localhost:8000/docs`
- Web: `http://localhost:5173`
- MinIO API: `http://localhost:9000`
- MinIO Console: `http://localhost:9001`

Notas:
- La API aplica migraciones Alembic al arrancar (`alembic upgrade head`).
- El bucket de MinIO se crea automaticamente con el servicio `minio-init`.

## Seed de datos (opcional pero recomendado)

Carga el admin demo y un evento inicial.

En PowerShell:

```powershell
Get-Content app/db/seed.sql | docker compose exec -T db psql -U events_user -d events
```

En bash:

```bash
docker compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f /dev/stdin < app/db/seed.sql
```

## Publicar imagenes en AWS ECR (Windows)

Script disponible: `scripts/UpdateImages.ps1`

Prerequisitos:
- AWS CLI configurado (`aws configure`) con permisos sobre ECR.
- Docker Desktop en ejecucion.
- Repositorios ECR ya creados:
  - `zt/api`
  - `zt/web`
  - `zt/svc`

Uso basico (build + push de `api`, `web`, `svc` con tag automatico y `latest`):

```powershell
.\scripts\UpdateImages.ps1
```

Ejemplos utiles:

```powershell
# Tag manual
.\scripts\UpdateImages.ps1 -Tag v1.0.0

# Solo algunos servicios
.\scripts\UpdateImages.ps1 -Services api,svc

# Rebuild completo sin cache
.\scripts\UpdateImages.ps1 -NoCache

# Cambiar region o account id explicitamente
.\scripts\UpdateImages.ps1 -Region eu-south-2 -AccountId 296368270177
```

Notas:
- El script hace login en ECR automaticamente.
- Para `web` usa `VITE_API_URL=/api` por defecto (configurable con `-WebApiUrl`).
- Por defecto genera dos tags por imagen: `latest` y uno versionado (`yyyyMMdd-HHmmss`).

## Publicar imagenes en AWS ECR (Linux/Ubuntu)

Script disponible: `scripts/update-images.sh`

Prerequisitos:
- AWS CLI configurado (`aws configure`) con permisos sobre ECR.
- Docker instalado y en ejecucion.

Uso basico (build + push de `api`, `web`, `svc` con tag automatico y `latest`):

```bash
bash ./scripts/update-images.sh
```

Ejemplos utiles:

```bash
# Tag manual
bash ./scripts/update-images.sh --tag v1.0.0

# Solo algunos servicios
bash ./scripts/update-images.sh --services api,svc

# Rebuild completo sin cache
bash ./scripts/update-images.sh --no-cache

# Cambiar region o account id explicitamente
bash ./scripts/update-images.sh --region eu-south-2 --account-id 296368270177
```

Notas:
- El script hace login en ECR automaticamente.
- Para `web` usa `VITE_API_URL=/api` por defecto (configurable con `--web-api-url`).
- Por defecto genera dos tags por imagen: `latest` y uno versionado (`yyyyMMdd-HHmmss`).

## Despliegue base en AWS (ECR + EKS + ALB + RDS + S3)

Esta seccion describe el flujo recomendado para desplegar en AWS con:
- Imagenes en ECR (`api`, `web`, `svc`).
- Datos en RDS PostgreSQL.
- Objetos en S3.
- Kubernetes en EKS con Ingress ALB.

### 1) Prerequisitos

- AWS CLI v2 autenticado (`aws configure`).
- `kubectl`, `helm` y `eksctl` instalados.
- Docker instalado y en ejecucion.
- Permisos IAM para crear: VPC, NAT Gateway, EKS, NodeGroup, RDS, S3, ECR e IAM roles/policies.

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

### 2) Publicar imagenes en ECR

Explicado en [Linux](#publicar-imagenes-en-aws-ecr-linuxubuntu) y [Windows](#publicar-imagenes-en-aws-ecr-windows) más arriba

### 3) Crear S3

```bash
aws s3api create-bucket \
  --bucket "$S3_BUCKET_NAME" \
  --region "$AWS_REGION" \
  --create-bucket-configuration LocationConstraint="$AWS_REGION"
```

Validacion:

```bash
aws s3api head-bucket --bucket "$S3_BUCKET_NAME"
```

### 4) Crear VPC, NAT, EKS y NodeGroup

Opcion recomendada para entorno de TFM: `eksctl` (crea VPC, subnets, NAT, cluster y nodegroup).

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

Actualizar `kubeconfig`:

```bash
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME"
kubectl get nodes
```

### 5) Crear RDS PostgreSQL

Antes de crear RDS:
- Usa las subnets privadas de la VPC del cluster para el `DB Subnet Group`.
- Crea un Security Group para RDS permitiendo `5432` solo desde los nodos/pods de EKS (no abierto a internet).

Ejemplo (ajusta subnet IDs y SG):

```bash
aws rds create-db-subnet-group \
  --db-subnet-group-name tfm-app-rds-subnet-group \
  --db-subnet-group-description "Subnet group for tfm app rds" \
  --subnet-ids subnet-AAAA subnet-BBBB

aws rds create-db-instance \
  --db-instance-identifier tfm-app-rds \
  --engine postgres \
  --engine-version 16 \
  --db-instance-class db.t4g.micro \
  --allocated-storage 20 \
  --master-username "$DB_USER" \
  --master-user-password "$DB_PASSWORD" \
  --db-name "$DB_NAME" \
  --vpc-security-group-ids sg-XXXXXXXX \
  --db-subnet-group-name tfm-app-rds-subnet-group \
  --backup-retention-period 1 \
  --no-publicly-accessible
```

Endpoint de RDS:

```bash
aws rds describe-db-instances \
  --db-instance-identifier tfm-app-rds \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text
```

### 6) Instalar AWS Load Balancer Controller

1. Asociar OIDC al cluster:

```bash
eksctl utils associate-iam-oidc-provider \
  --region "$AWS_REGION" \
  --cluster "$CLUSTER_NAME" \
  --approve
```

2. Crear IAM policy del controller (si no existe):

```bash
curl -o iam_policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
aws iam create-policy --policy-name AWSLoadBalancerControllerIAMPolicy --policy-document file://iam_policy.json
```

3. Crear service account IAM con `eksctl` o usar el rol ya referenciado en `infra/k8s/aws-lbc-sa.yaml`.
4. Instalar controller con Helm:

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

### 7) Ajustar manifiestos k8s del repositorio

Revisar y editar antes de aplicar:
- `infra/k8s/configmap.yaml`
- `infra/k8s/secret.yaml` como plantilla de manifiesto
- `infra/k8s/secret.local.yaml` para pruebas/manual
- `infra/k8s/ingress.yaml`

Campos importantes:
- `POSTGRES_HOST`: endpoint de RDS.
- `S3_BUCKET`: bucket creado en S3.
- `VITE_API_URL`: recomendable `"/api"` en despliegue con ALB.
- `DATABASE_URL_API` y `DATABASE_URL_SVC`: conexion real a RDS.
- `S3_ACCESS_KEY` y `S3_SECRET_KEY`: si usas IAM roles en pods, no uses claves estaticas.

### 8) Aplicar componentes Kubernetes

Orden recomendado:

```bash
kubectl apply -f infra/k8s/namespace.yaml
kubectl apply -f infra/k8s/configmap.yaml
kubectl apply -f infra/k8s/secret.yaml
kubectl apply -f infra/k8s/api.yaml
kubectl apply -f infra/k8s/web.yaml
kubectl apply -f infra/k8s/svc.yaml
kubectl apply -f infra/k8s/ingress.yaml
```

Verificaciones:

```bash
kubectl -n tfm-app get pods,svc,ingress
kubectl -n tfm-app describe ingress tfm-app-ingress
```

Cuando el ALB este provisionado, prueba:
- `GET http://<ALB_DNS>/api/health`
- `GET http://<ALB_DNS>/` (web)

### 9) Consideraciones de rutas y healthcheck

- El Ingress expone API bajo prefijo `/api`.
- Se usa `alb.ingress.kubernetes.io/healthcheck-path: /api/health`.
- La API mantiene compatibilidad interna para rutas locales (`/health`) y rutas con prefijo (`/api/health`) en despliegue tras ALB.
- Si separas `web` y `api` en Ingress distintos, podras definir healthchecks especificos por servicio.

### 10) Seguridad recomendada

- No usar `infra/k8s/secret.local.yaml` en entornos compartidos.
- No subir credenciales reales a git.
- Sustituir secretos en `infra/k8s/secret.yaml` por valores reales en CI/CD o por un gestor de secretos.
- Restringir Security Groups de RDS y EKS al minimo necesario.

## Credenciales de prueba

- Email: `admin@example.com`
- Password: `admin123`

## Variables de entorno principales

- `API_SECRET_KEY`: clave para firmar y validar tokens de acceso.
- `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`: configuracion de PostgreSQL.
- `S3_ENDPOINT`: endpoint interno para API/svc (por defecto `http://minio:9000`).
- `S3_PUBLIC_ENDPOINT`: endpoint publico para URLs firmadas (por defecto `http://localhost:9000`).
- `S3_ACCESS_KEY`, `S3_SECRET_KEY`, `S3_BUCKET`, `S3_REGION`, `S3_USE_SSL`.
- `S3_URL_TTL_SECONDS`: expiracion de URLs firmadas.
- `SVC_POLL_SECONDS`: intervalo entre ejecuciones del batch.
- `SVC_RUN_ONCE`: si `true`, ejecuta una vez y termina.
- `SVC_FORCE_REPROCESS`: si `true`, reprocesa eventos ya procesados.

Consulta `.env.example` para valores de desarrollo.

## Endpoints principales

Auth:
- `POST /api/auth/register`
- `POST /api/auth/login`

Eventos:
- `GET /api/events`
- `GET /api/events/{event_id}`
- `POST /api/events`
- `PUT /api/events/{event_id}`
- `DELETE /api/events/{event_id}`

Imagenes:
- `POST /api/events/{event_id}/image` (solo creador del evento; `multipart/form-data`)
- `GET /api/events/{event_id}/image` (ultima imagen)
- `GET /api/events/{event_id}/images` (galeria)

Batch:
- `GET /api/batch/status`
- `GET /api/batch/executions`
- `GET /api/batch/executions/{batch_id}`

Health:
- `GET /api/health`

## Servicio batch (`svc`)

El servicio `svc`:
- Detecta eventos con imagenes.
- Lee metadatos de BD y de MinIO.
- Genera `generated_description`.
- Actualiza `events` (`processed_at`, `last_batch_execution_id`, `status`).
- Registra cada corrida en `batch_executions`.

Modos de ejecucion:
- Local continuo: `SVC_RUN_ONCE=false` y `SVC_POLL_SECONDS=<segundos>`
- Job unico (ideal para CronJob en Kubernetes): `SVC_RUN_ONCE=true`

## Seguridad minima aplicada

- `API_SECRET_KEY` no esta hardcodeada en `docker-compose.yml`.
- Los secretos se leen desde `.env` (ignorado por git).
- El repo incluye `.env.example` con placeholders de desarrollo.

## Limitaciones conocidas (estado base)

- CORS permitido para `http://localhost:5173` (orientado a desarrollo).
- No hay endpoint API para disparar batch manual; el disparo lo hace `svc` por planificacion.
- Para produccion faltaria endurecer gestion de secretos, observabilidad y politicas Zero Trust completas.
