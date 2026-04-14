# zt-cloud-tfm

Repositorio del TFM sobre implementacion de un enfoque Zero Trust en entorno cloud.

## Arranque local

1. Crear archivo de entorno a partir del ejemplo:
   `cp .env.example .env`
2. Editar `.env` y definir un valor propio para `API_SECRET_KEY`.
   Tambien puedes ajustar `POSTGRES_DB`, `POSTGRES_USER` y `POSTGRES_PASSWORD`.
   Para imagenes en local con MinIO, revisa tambien `S3_ENDPOINT` y `S3_PUBLIC_ENDPOINT`.
3. Levantar servicios:
   `docker compose up --build`

Servicios:
- API: `http://localhost:8000`
- Web: `http://localhost:5173`
- MinIO API (S3 local): `http://localhost:9000`
- MinIO Console: `http://localhost:9001`

Credenciales MinIO por defecto (local):
- Access Key: `minioadmin`
- Secret Key: `minioadmin`
- Bucket: `events-images`

Variables MinIO/S3 usadas en local:
- `S3_ENDPOINT`: endpoint interno para la API (por defecto `http://minio:9000`)
- `S3_PUBLIC_ENDPOINT`: endpoint para URLs firmadas accesibles desde navegador (por defecto `http://localhost:9000`)
- `S3_BUCKET`: bucket de imagenes
- `S3_REGION`: region de firma
- `S3_USE_SSL`: `false` en local
- `S3_URL_TTL_SECONDS`: expiracion de URLs firmadas

## Credenciales de prueba

- Admin demo:
  - Email: `admin@example.com`
  - Password: `admin123`

## Seguridad minima aplicada

- La clave de firma de tokens (`API_SECRET_KEY`) ya no esta hardcodeada en `docker-compose.yml`.
- El valor debe venir desde `.env` (que esta ignorado por git).
- El repositorio incluye solo `.env.example` como plantilla sin secretos reales.

## Procesamiento batch de eventos

- Servicio `svc` (contenedor `events-svc`):
  - Ejecuta procesamiento periodico cada `POLL_SECONDS` (configurado por `SVC_POLL_SECONDS` en `.env`).
  - En local puede correr en bucle; en Kubernetes se recomienda ejecutarlo como `CronJob`.

### Local vs CronJob en Kubernetes

- Modo local (contenedor persistente):
  - `RUN_ONCE=false`
  - `SVC_POLL_SECONDS=86400` (o el intervalo que quieras)
  - El proceso queda activo y ejecuta en bucle.

- Modo Kubernetes CronJob (recomendado para diario):
  - `RUN_ONCE=true`
  - El contenedor arranca, ejecuta una sola vez y finaliza.
  - El horario lo define `spec.schedule` del CronJob (por ejemplo una vez al dia).
  - En este modo, no es necesario usar `SVC_POLL_SECONDS=86400`.

## Imagenes de evento

- Subida:
  - Endpoint `POST /events/{event_id}/image` (`multipart/form-data`).
  - Solo el creador del evento puede subir imagenes.
  - Guarda objeto en MinIO y metadata en `images` (`storage_path`, `hash`, `width`, `height`, `caption`).

- Visualizacion:
  - Endpoint `GET /events/{event_id}/images`.
  - Devuelve la galeria de imagenes del evento con URL firmada temporal.

## Batch y metadatos

- Procesamiento:
  - El `svc` detecta eventos con imagenes pendientes de procesar.
  - Cada ejecucion se registra en `batch_executions`.

- Metadatos generados:
  - Genera `generated_description` usando metadatos del evento + imagenes.
  - Actualiza `events.generated_description`, `events.last_batch_execution_id`, `events.processed_at` y `events.status`.

- Estado del procesamiento:
  - `GET /batch/status`: ultima ejecucion batch.
  - `GET /batch/executions`: historial.
  - `GET /batch/executions/{batch_id}`: detalle.
  - `POST /batch/run`: lanza ejecucion manual (solo admin).
