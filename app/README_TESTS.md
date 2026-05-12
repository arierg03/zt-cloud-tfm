# Pruebas automaticas con pytest

Este documento describe las pruebas automaticas de `api` y `svc` (sin E2E de frontend).

## Cobertura

- API (`app/api/tests`): autenticacion, CRUD de eventos, carga/listado de imagenes, estado batch y flujo principal.
- SVC (`app/svc/tests`): procesamiento batch y generacion de metadatos (unit tests con mocks).

## Ejecucion

Desde la raiz del repositorio:

```bash
pytest app/api/tests
pytest app/svc/tests
pytest app/api/tests app/svc/tests
```

Tambien puedes usar:

```powershell
.\scripts\Run-All-Tests.ps1
```

## Dependencias externas

### API tests

- No requieren AWS.
- No requieren MinIO real (S3 mockeado).
- Usan SQLite local de test.

### SVC tests

- No requieren PostgreSQL real.
- No requieren AWS.
- No requieren MinIO real.
- Se ejecutan como unit tests puros (mocks de DB/S3).

## Variables de entorno

No hay variables obligatorias para la ejecucion basica local de estos tests.

## Mapeo de casos de uso (UC)

### `app/api/tests/test_auth.py`

- UC-1 Registrar usuario: `test_register_user_success`
- UC-2 Iniciar sesion: `test_login_user_success`

UC-3 Cerrar sesion: no se incluye test backend porque la API actual no expone `/auth/logout`.
El logout se resuelve en frontend eliminando el token local; en backend la autenticacion es stateless por token con expiracion.

### `app/api/tests/test_events.py`

- UC-4 Crear evento: `test_create_event`
- UC-5 Listar eventos: `test_list_events`
- UC-6 Ver detalle de evento: `test_get_event_detail`
- UC-7 Editar evento: `test_update_event`
- UC-8 Eliminar evento: `test_delete_event`

### `app/api/tests/test_images.py`

- UC-9 Subir imagen a evento: `test_upload_image_to_event`
- UC-10 Ver imagenes de evento: `test_list_event_images`

### `app/svc/tests/test_batch_processing.py`

- UC-11 Procesar eventos en batch: `test_run_batch_once_processes_event`
- UC-12 Generar metadatos del evento: `test_generate_event_description_includes_metadata`

### `app/api/tests/test_batch_status.py`

- UC-13 Consultar estado del procesamiento: `test_get_batch_status`

### `app/api/tests/test_full_event_flow.py`

- Flujo principal extremo a extremo a nivel API: `test_full_event_flow`

## Limitaciones

- No se prueban servicios AWS reales.
- No se ejecutan pruebas Playwright ni E2E de React.
- UC-3 no tiene prueba backend por diseno actual (sin endpoint logout y sesion stateless).
