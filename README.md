# zt-cloud-tfm

Repositorio del TFM sobre un enfoque Zero Trust en entorno cloud.

## Stack

- API: FastAPI + SQLAlchemy + Alembic
- Web: React + Vite
- Base de datos: PostgreSQL 16
- Almacenamiento local de imágenes: MinIO, compatible con S3
- Almacenamiento cloud de imágenes: Amazon S3
- Proceso batch: servicio `svc` en Python
- Orquestación local: Docker Compose
- Orquestación cloud: Amazon EKS
- Infraestructura cloud: Terraform
- Balanceo cloud: AWS Load Balancer Controller + ALB

## Estructura principal

```text
app/
  api/        API FastAPI
  web/        Frontend React
  svc/        Servicio batch
  db/         Migraciones, seed y configuración de base de datos

docs/
  img/        Imagenes del proyecto
  pdf/        Documentos pdf relacionados con el proyecto

infra/
  terraform/ Infraestructura AWS base
  k8s/       Manifiestos Kubernetes
  docs/      Documentación de despliegue

scripts/
  Cloud.ps1           Operación cloud: deploy, status y stop
  UpdateImages.ps1    Build y push de imágenes Docker a ECR
  update-images.sh    Variante Linux para build y push de imágenes
```

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
- Swagger: `http://localhost:8000/docs`
- Web: `http://localhost:5173`
- MinIO API: `http://localhost:9000`
- MinIO Console: `http://localhost:9001`

Notas:

- La API aplica migraciones Alembic al arrancar mediante `alembic upgrade head`.
- El bucket de MinIO se crea automáticamente con el servicio `minio-init`.

## Seed de datos

Carga el usuario administrador demo y un evento inicial.

En PowerShell:

```powershell
Get-Content app/db/seed.sql | docker compose exec -T db psql -U events_user -d events
```

En bash:

```bash
docker compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f /dev/stdin < app/db/seed.sql
```

## Credenciales de prueba

- Email: `admin@example.com`
- Password: `admin123`

## Publicación de imágenes en AWS ECR

Las imágenes Docker de `api`, `web` y `svc` se publican en Amazon ECR mediante los scripts del directorio `scripts`.

En Windows:

```powershell
.\scripts\UpdateImages.ps1
```

En Linux:

```bash
bash ./scripts/update-images.sh
```

Repositorios ECR esperados:

- `zt/api`
- `zt/web`
- `zt/svc`

La documentación completa de parámetros y ejemplos está en:

- [`scripts/README.md`](scripts/README.md)

## Despliegue cloud en AWS

El despliegue cloud base se apoya en:

- Terraform para la infraestructura AWS.
- Kubernetes para los workloads sobre EKS.
- Scripts de operación para automatizar despliegue, consulta de estado y parada de recursos con coste.

Flujo recomendado en Windows:

```powershell
.\scripts\Cloud.ps1 deploy
.\scripts\Cloud.ps1 status
.\scripts\Cloud.ps1 stop
```

La acción `deploy` crea y configura los recursos necesarios para ejecutar la aplicación en AWS:

- EKS
- Node Group
- RDS PostgreSQL
- NAT Gateway
- AWS Load Balancer Controller
- ALB generado desde el Ingress de Kubernetes

La acción `stop` elimina los recursos con coste recurrente y mantiene los recursos persistentes de base, como VPC, subredes, S3, ECR, IAM y VPC Endpoint.

Documentación específica:

- [Despliegue automático](infra/docs/automatic-deploy.md)
- [Despliegue manual](infra/docs/manual-deploy.md)
- [Infraestructura Terraform](infra/terraform/README.md)
- [Manifiestos Kubernetes](infra/k8s/README.md)
- [Inventario de AWS](/infra/terraform/INVENTARIO_AWS.md)
- [Scripts de operación](scripts/README.md)

## Variables de entorno principales

Consulta `.env.example` para valores de desarrollo.

Variables principales:

- `API_SECRET_KEY`: clave para firmar y validar tokens de acceso.
- `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`: configuración de PostgreSQL.
- `S3_ENDPOINT`: endpoint interno para API/svc en local, por defecto `http://minio:9000`.
- `S3_PUBLIC_ENDPOINT`: endpoint público para URLs firmadas, por defecto `http://localhost:9000`.
- `S3_ACCESS_KEY`, `S3_SECRET_KEY`, `S3_BUCKET`, `S3_REGION`, `S3_USE_SSL`.
- `S3_URL_TTL_SECONDS`: expiración de URLs firmadas.
- `SVC_POLL_SECONDS`: intervalo entre ejecuciones del batch.
- `SVC_RUN_ONCE`: si es `true`, ejecuta una vez y termina.
- `SVC_FORCE_REPROCESS`: si es `true`, reprocesa eventos ya procesados.

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

Imágenes:

- `POST /api/events/{event_id}/image`
- `GET /api/events/{event_id}/image`
- `GET /api/events/{event_id}/images`

Batch:

- `GET /api/batch/status`
- `GET /api/batch/executions`
- `GET /api/batch/executions/{batch_id}`

Health:

- `GET /api/health`

## Servicio batch

El servicio `svc` se encarga del procesamiento periódico de eventos con imágenes.

Funcionalidades principales:

- Detecta eventos con imágenes.
- Lee metadatos desde la base de datos y el almacenamiento S3/MinIO.
- Genera `generated_description`.
- Actualiza el estado de eventos procesados.
- Registra ejecuciones en `batch_executions`.

Modos de ejecución:

- Local continuo: `SVC_RUN_ONCE=false`
- Ejecución única: `SVC_RUN_ONCE=true`

## Seguridad mínima aplicada en la base

- `API_SECRET_KEY` no está hardcodeada en `docker-compose.yml`.
- Los secretos locales se leen desde `.env`, ignorado por Git.
- El repositorio incluye `.env.example` con placeholders de desarrollo.
- Los secretos reales de Kubernetes se mantienen en `secret.local.yaml`, no versionado.
- Las access keys reales no se gestionan con Terraform.
- En AWS, RDS se despliega sin acceso público.
- El bucket S3 mantiene bloqueo de acceso público y cifrado en reposo.
- La infraestructura cloud separa recursos persistentes y recursos con coste recurrente.

## Limitaciones

- CORS está configurado para desarrollo local.
- No existe endpoint API para disparar manualmente el batch; la ejecución la realiza `svc`.
- La arquitectura base usa credenciales estáticas para acceso a S3 desde la aplicación.
- Para una evolución Zero Trust, se plantea sustituir credenciales estáticas por IRSA y reforzar identidad, segmentación, observabilidad y políticas de acceso.
