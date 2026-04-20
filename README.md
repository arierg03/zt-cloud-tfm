# zt-cloud-tfm

Repositorio del TFM sobre un enfoque Zero Trust en entorno cloud.

## Stack

- API: FastAPI + SQLAlchemy + Alembic
- Web: React (Vite)
- Base de datos: PostgreSQL 16
- Almacenamiento de imagenes: MinIO (S3 compatible)
- Proceso batch: servicio `svc` en Python
- Orquestacion local: Docker Compose

## Arranque rapido (local)

1. Copiar variables de entorno:

```bash
cp .env.example .env
```

2. Revisar `.env` y cambiar al menos `API_SECRET_KEY`.
3. Levantar servicios:

```bash
docker compose up --build
```

4. URLs utiles:
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
- `POST /auth/register`
- `POST /auth/login`

Eventos:
- `GET /events`
- `GET /events/{event_id}`
- `POST /events`
- `PUT /events/{event_id}`
- `DELETE /events/{event_id}`

Imagenes:
- `POST /events/{event_id}/image` (solo creador del evento; `multipart/form-data`)
- `GET /events/{event_id}/image` (ultima imagen)
- `GET /events/{event_id}/images` (galeria)

Batch:
- `GET /batch/status`
- `GET /batch/executions`
- `GET /batch/executions/{batch_id}`

Health:
- `GET /health`

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
