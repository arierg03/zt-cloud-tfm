from datetime import datetime, timezone


def _event_payload(title="Evento test"):
    return {
        "title": title,
        "manual_description": "descripcion manual",
        "event_date": datetime.now(timezone.utc).isoformat(),
        "country": "ES",
        "language": "es",
    }


def test_create_event(client, auth_headers):
    response = client.post("/events", json=_event_payload(), headers=auth_headers)
    assert response.status_code == 201
    assert "id" in response.json()


def test_list_events(client, auth_headers):
    client.post("/events", json=_event_payload("Evento listado"), headers=auth_headers)
    response = client.get("/events", headers=auth_headers)
    assert response.status_code == 200
    assert isinstance(response.json(), list)
    assert any(event["title"] == "Evento listado" for event in response.json())


def test_get_event_detail(client, auth_headers):
    created = client.post("/events", json=_event_payload("Evento detalle"), headers=auth_headers).json()
    response = client.get(f"/events/{created['id']}", headers=auth_headers)
    assert response.status_code == 200
    assert response.json()["id"] == created["id"]


def test_update_event(client, auth_headers):
    created = client.post("/events", json=_event_payload("Evento update"), headers=auth_headers).json()
    updated_payload = _event_payload("Evento actualizado")

    response = client.put(f"/events/{created['id']}", json=updated_payload, headers=auth_headers)
    assert response.status_code == 200
    assert response.json()["title"] == "Evento actualizado"


def test_delete_event(client, auth_headers):
    created = client.post("/events", json=_event_payload("Evento delete"), headers=auth_headers).json()
    response = client.delete(f"/events/{created['id']}", headers=auth_headers)
    assert response.status_code == 200
    assert response.json()["message"] == "deleted"

    check = client.get(f"/events/{created['id']}", headers=auth_headers)
    assert check.status_code == 404
