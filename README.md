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
