import base64
from datetime import datetime, timezone

from models import BatchExecution, Event

MINIMAL_PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO7Yx6sAAAAASUVORK5CYII="
)


def test_full_event_flow(client, auth_headers, db_session):
    register = client.post(
        "/auth/register",
        json={"username": "flowuser", "email": "flowuser@example.com", "password": "secret123"},
    )
    assert register.status_code in (201, 409)

    login = client.post(
        "/auth/login",
        json={"identifier": "flowuser@example.com", "password": "secret123"},
    )
    assert login.status_code == 200
    token = login.json()["access_token"]
    headers = {"Authorization": f"Bearer {token}"}

    payload = {
        "title": "Evento flujo completo",
        "manual_description": "Descripcion inicial",
        "event_date": datetime.now(timezone.utc).isoformat(),
        "country": "ES",
        "language": "es",
    }

    created = client.post("/events", json=payload, headers=headers)
    assert created.status_code == 201
    event_id = created.json()["id"]

    listed = client.get("/events", headers=headers)
    assert listed.status_code == 200
    assert any(item["id"] == event_id for item in listed.json())

    detail = client.get(f"/events/{event_id}", headers=headers)
    assert detail.status_code == 200
    assert detail.json()["title"] == "Evento flujo completo"

    payload["title"] = "Evento flujo actualizado"
    updated = client.put(f"/events/{event_id}", json=payload, headers=headers)
    assert updated.status_code == 200
    assert updated.json()["title"] == payload["title"]

    uploaded = client.post(
        f"/events/{event_id}/image",
        files={"file": ("flow.png", MINIMAL_PNG, "image/png")},
        data={"caption": "imagen flujo"},
        headers=headers,
    )
    assert uploaded.status_code == 201

    images = client.get(f"/events/{event_id}/images", headers=headers)
    assert images.status_code == 200
    assert len(images.json()) >= 1

    batch = BatchExecution(
        started_at=datetime.now(timezone.utc),
        finished_at=datetime.now(timezone.utc),
        status="success",
        total_events_detected=1,
        total_events_processed=1,
        total_events_failed=0,
        log_summary="batch simulado",
        error_message=None,
    )
    db_session.add(batch)
    db_session.commit()
    db_session.refresh(batch)

    event = db_session.get(Event, event_id)
    event.generated_description = "descripcion generada de prueba"
    event.status = "processed"
    event.last_batch_execution_id = batch.id
    event.processed_at = datetime.now(timezone.utc)
    db_session.commit()

    batch_status = client.get("/batch/status", headers=headers)
    assert batch_status.status_code == 200
    assert batch_status.json()["id"] == batch.id

    detail_after_batch = client.get(f"/events/{event_id}", headers=headers)
    assert detail_after_batch.status_code == 200
    assert detail_after_batch.json()["generated_description"] == "descripcion generada de prueba"

    deleted = client.delete(f"/events/{event_id}", headers=headers)
    assert deleted.status_code == 200
