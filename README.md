# zt-cloud-tfm

Repositorio del TFM sobre implementacion de un enfoque Zero Trust en entorno cloud.

## Arranque local

1. Crear archivo de entorno a partir del ejemplo:
   `cp .env.example .env`
2. Editar `.env` y definir un valor propio para `API_SECRET_KEY`.
   Tambien puedes ajustar `POSTGRES_DB`, `POSTGRES_USER` y `POSTGRES_PASSWORD`.
3. Levantar servicios:
   `docker compose up --build`

Servicios:
- API: `http://localhost:8000`
- Web: `http://localhost:5173`

## Credenciales de prueba

- Admin demo:
  - Email: `admin@example.com`
  - Password: `admin123`

## Seguridad minima aplicada

- La clave de firma de tokens (`API_SECRET_KEY`) ya no esta hardcodeada en `docker-compose.yml`.
- El valor debe venir desde `.env` (que esta ignorado por git).
- El repositorio incluye solo `.env.example` como plantilla sin secretos reales.
