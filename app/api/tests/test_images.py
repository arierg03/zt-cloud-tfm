import base64
from datetime import datetime, timezone

MINIMAL_PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO7Yx6sAAAAASUVORK5CYII="
)


def _event_payload(title="Evento con imagen"):
    return {
        "title": title,
        "manual_description": "descripcion",
        "event_date": datetime.now(timezone.utc).isoformat(),
        "country": "ES",
        "language": "es",
    }


def test_upload_image_to_event(client, auth_headers):
    created = client.post("/events", json=_event_payload(), headers=auth_headers).json()

    response = client.post(
        f"/events/{created['id']}/image",
        files={"file": ("test.png", MINIMAL_PNG, "image/png")},
        data={"caption": "cartel del evento"},
        headers=auth_headers,
    )
    assert response.status_code == 201
    body = response.json()
    assert body["event_id"] == created["id"]
    assert body["mime_type"] == "image/png"


def test_list_event_images(client, auth_headers):
    created = client.post("/events", json=_event_payload("Evento listado imagenes"), headers=auth_headers).json()
    client.post(
        f"/events/{created['id']}/image",
        files={"file": ("test.png", MINIMAL_PNG, "image/png")},
        data={"caption": "imagen 1"},
        headers=auth_headers,
    )

    response = client.get(f"/events/{created['id']}/images", headers=auth_headers)
    assert response.status_code == 200
    images = response.json()
    assert len(images) >= 1
    assert images[0]["event_id"] == created["id"]
    assert images[0]["image_url"].startswith("http://test-s3.local/")
