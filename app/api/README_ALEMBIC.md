# Alembic Quickstart

Este proyecto usa `SQLAlchemy + Alembic`.

## Flujo diario

1. Cambia modelos en `models.py`.
2. Crea migracion:
   `alembic revision --autogenerate -m "descripcion"`
3. Aplica migraciones:
   `alembic upgrade head`

## Comandos utiles

- Version actual: `alembic current`
- Historial: `alembic history`
- Bajar una version: `alembic downgrade -1`

## Nota docker

En `docker-compose.yml`, el servicio `api` ya ejecuta:
`alembic upgrade head`
antes de levantar FastAPI.
