import sys
from datetime import datetime, timezone
from pathlib import Path

SVC_DIR = Path(__file__).resolve().parents[1]
if str(SVC_DIR) not in sys.path:
    sys.path.insert(0, str(SVC_DIR))

import main as svc_main


def test_generate_event_description_includes_metadata():
    event = {
        "id": 1,
        "title": "Evento demo",
        "manual_description": "Descripcion manual",
        "event_date": datetime(2026, 1, 2, tzinfo=timezone.utc),
        "country": "ES",
        "language": "es",
    }
    images = [
        {
            "id": 10,
            "storage_path": "events/1/a.png",
            "filename": "a.png",
            "mime_type": "image/png",
            "caption": "cartel principal",
            "width": 100,
            "height": 120,
            "hash": "h1",
            "created_at": datetime.now(timezone.utc),
        },
        {
            "id": 11,
            "storage_path": "events/1/b.png",
            "filename": "b.png",
            "mime_type": "image/jpeg",
            "caption": "escenario de noche",
            "width": 300,
            "height": 400,
            "hash": "h2",
            "created_at": datetime.now(timezone.utc),
        },
    ]
    s3_metadata = [
        {
            "image_id": 10,
            "storage_path": "events/1/a.png",
            "content_type": "image/png",
            "size_bytes": 1024,
            "last_modified": datetime(2026, 1, 2, tzinfo=timezone.utc),
            "etag": "etag-a",
        },
        {
            "image_id": 11,
            "storage_path": "events/1/b.png",
            "content_type": "image/jpeg",
            "size_bytes": 2048,
            "last_modified": datetime(2026, 1, 3, tzinfo=timezone.utc),
            "etag": "etag-b",
        },
    ]

    description = svc_main.generate_event_description(event, images, s3_metadata)

    assert "Evento 'Evento demo'" in description
    assert "Metadatos en BD de 2 imagen(es)" in description
    assert "Metadatos leidos en S3 para 2 imagen(es)" in description
    assert "cartel principal" in description


def test_run_batch_once_processes_event(monkeypatch):
    fake_state = {
        "batch_id": 77,
        "events": [
            {
                "id": 99,
                "title": "Evento batch",
                "manual_description": "Descripcion",
                "event_date": datetime(2026, 1, 10, tzinfo=timezone.utc),
                "country": "ES",
                "language": "es",
            }
        ],
        "images": [
            {
                "id": 1,
                "storage_path": "events/99/test.png",
                "filename": "test.png",
                "mime_type": "image/png",
                "caption": "imagen de prueba",
                "width": 640,
                "height": 480,
                "hash": "abc123",
                "created_at": datetime.now(timezone.utc),
            }
        ],
    }
    calls = {"update": [], "finalize": []}

    class FakeConn:
        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

        def commit(self):
            pass

    monkeypatch.setattr(svc_main.psycopg, "connect", lambda _: FakeConn())
    monkeypatch.setattr(svc_main, "create_batch_execution", lambda conn: fake_state["batch_id"])
    monkeypatch.setattr(svc_main, "fetch_events_to_process", lambda conn, force_reprocess: fake_state["events"])
    monkeypatch.setattr(svc_main, "fetch_event_images", lambda conn, event_id: fake_state["images"])
    monkeypatch.setattr(
        svc_main,
        "fetch_s3_image_metadata",
        lambda images: [
            {
                "image_id": 1,
                "storage_path": "events/99/test.png",
                "content_type": "image/png",
                "size_bytes": 1024,
                "last_modified": datetime.now(timezone.utc),
                "etag": "etag-1",
            }
        ],
    )

    def _capture_update(conn, event_id, generated_description, batch_id):
        calls["update"].append((event_id, generated_description, batch_id))

    def _capture_finalize(conn, batch_id, total_detected, total_processed, total_failed, errors):
        calls["finalize"].append((batch_id, total_detected, total_processed, total_failed, errors))

    monkeypatch.setattr(svc_main, "update_event_processed", _capture_update)
    monkeypatch.setattr(svc_main, "finalize_batch_execution", _capture_finalize)

    svc_main.run_batch_once()

    assert len(calls["update"]) == 1
    event_id, generated_description, batch_id = calls["update"][0]
    assert event_id == 99
    assert batch_id == 77
    assert "Metadatos" in generated_description

    assert len(calls["finalize"]) == 1
    batch_id, total_detected, total_processed, total_failed, errors = calls["finalize"][0]
    assert batch_id == 77
    assert total_detected == 1
    assert total_processed == 1
    assert total_failed == 0
    assert errors == []
