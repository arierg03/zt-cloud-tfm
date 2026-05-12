import sys
from pathlib import Path
from datetime import datetime, timezone

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

API_DIR = Path(__file__).resolve().parents[1]
if str(API_DIR) not in sys.path:
    sys.path.insert(0, str(API_DIR))

import main as api_main
from database import Base
from models import BatchExecution


class FakeS3Client:
    def __init__(self):
        self.objects = {}

    def put_object(self, Bucket, Key, Body, ContentType):
        self.objects[(Bucket, Key)] = {
            "body": Body,
            "content_type": ContentType,
        }

    def delete_object(self, Bucket, Key):
        self.objects.pop((Bucket, Key), None)


def _fake_presigned_url(storage_path: str) -> str:
    return f"http://test-s3.local/{storage_path}"


@pytest.fixture(scope="session")
def engine():
    db_dir = Path(__file__).resolve().parent / ".tmp"
    db_dir.mkdir(parents=True, exist_ok=True)
    db_file = db_dir / "test_api.db"
    if db_file.exists():
        db_file.unlink()
    engine = create_engine(f"sqlite:///{db_file}", connect_args={"check_same_thread": False})
    Base.metadata.create_all(bind=engine)
    return engine


@pytest.fixture()
def db_session(engine):
    TestingSessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
    db = TestingSessionLocal()
    try:
        yield db
    finally:
        db.rollback()
        db.close()


@pytest.fixture()
def client(db_session, monkeypatch):
    fake_s3 = FakeS3Client()

    def override_get_db():
        try:
            yield db_session
        finally:
            pass

    monkeypatch.setattr(api_main, "ensure_bucket_exists", lambda: None)
    monkeypatch.setattr(api_main, "get_s3_client", lambda: fake_s3)
    monkeypatch.setattr(api_main, "build_presigned_get_url", _fake_presigned_url)

    api_main.app.dependency_overrides[api_main.get_db] = override_get_db
    test_client = TestClient(api_main.app)
    try:
        yield test_client
    finally:
        api_main.app.dependency_overrides.clear()


@pytest.fixture()
def registered_user_payload():
    return {
        "username": "testuser",
        "email": "testuser@example.com",
        "password": "secret123",
    }


@pytest.fixture()
def auth_headers(client, registered_user_payload):
    response = client.post("/auth/register", json=registered_user_payload)
    assert response.status_code in (201, 409)

    login_response = client.post(
        "/auth/login",
        json={"identifier": registered_user_payload["email"], "password": registered_user_payload["password"]},
    )
    assert login_response.status_code == 200
    token = login_response.json()["access_token"]
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture()
def create_batch_execution(db_session):
    def _create(status="success"):
        row = BatchExecution(
            started_at=datetime.now(timezone.utc),
            finished_at=datetime.now(timezone.utc),
            status=status,
            total_events_detected=1,
            total_events_processed=1,
            total_events_failed=0,
            log_summary="ok",
            error_message=None,
        )
        db_session.add(row)
        db_session.commit()
        db_session.refresh(row)
        return row

    return _create
