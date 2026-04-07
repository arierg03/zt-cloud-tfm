import hashlib
import mimetypes
import os
import time
from datetime import datetime
from pathlib import Path

import psycopg
from PIL import Image

DATABASE_URL = os.getenv("DATABASE_URL", "postgresql://events_user:events_pass@db:5432/events")
S3_BUCKET = os.getenv("S3_BUCKET", "local-placeholder")
INBOX = Path(os.getenv("INBOX_DIR", "/app/inbox"))
POLL_SECONDS = int(os.getenv("POLL_SECONDS", "30"))


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while chunk := f.read(8192):
            h.update(chunk)
    return h.hexdigest()


def ensure_demo_event(conn) -> int:
    with conn.cursor() as cur:
        cur.execute("SELECT id FROM users ORDER BY id LIMIT 1")
        user = cur.fetchone()
        if not user:
            cur.execute(
                """
                INSERT INTO users (username, email, password_hash, role, is_active)
                VALUES (%s, %s, %s, %s, %s)
                RETURNING id
                """,
                ("svc-user", "svc@example.com", "demo-hash", "admin", True),
            )
            user = cur.fetchone()

        cur.execute("SELECT id FROM events ORDER BY id LIMIT 1")
        event = cur.fetchone()
        if event:
            return event[0]

        cur.execute(
            """
            INSERT INTO events (title, manual_description, created_by)
            VALUES (%s, %s, %s)
            RETURNING id
            """,
            ("Auto event", "Creado por svc para asociar imagenes", user[0]),
        )
        return cur.fetchone()[0]


def run_batch() -> None:
    INBOX.mkdir(parents=True, exist_ok=True)
    files = [p for p in INBOX.iterdir() if p.is_file()]

    started_at = datetime.utcnow()
    status = "success"
    processed = 0
    failed = 0
    error_message = None

    try:
        with psycopg.connect(DATABASE_URL) as conn:
            event_id = ensure_demo_event(conn)

            with conn.cursor() as cur:
                cur.execute(
                    """
                    INSERT INTO batch_executions (started_at, status)
                    VALUES (%s, %s)
                    RETURNING id
                    """,
                    (started_at, "running"),
                )
                batch_id = cur.fetchone()[0]

            for file_path in files:
                try:
                    with Image.open(file_path) as img:
                        width, height = img.size

                    mime = mimetypes.guess_type(file_path.name)[0] or "application/octet-stream"
                    file_hash = sha256_file(file_path)

                    with conn.cursor() as cur:
                        cur.execute(
                            """
                            INSERT INTO images (
                              event_id, uploaded_by, storage_path, filename, mime_type, width, height, hash
                            ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
                            """,
                            (
                                event_id,
                                None,
                                f"s3://{S3_BUCKET}/{file_path.name}",
                                file_path.name,
                                mime,
                                width,
                                height,
                                file_hash,
                            ),
                        )

                    file_path.unlink(missing_ok=True)
                    processed += 1
                except Exception:
                    failed += 1

            finished_at = datetime.utcnow()
            with conn.cursor() as cur:
                cur.execute(
                    """
                    UPDATE batch_executions
                    SET finished_at = %s,
                        status = %s,
                        total_events_detected = %s,
                        total_events_processed = %s,
                        total_events_failed = %s,
                        log_summary = %s,
                        error_message = %s
                    WHERE id = %s
                    """,
                    (
                        finished_at,
                        status if failed == 0 else "partial_success",
                        len(files),
                        processed,
                        failed,
                        f"Processed {processed} files, failed {failed}",
                        error_message,
                        batch_id,
                    ),
                )
            conn.commit()
    except Exception as exc:
        print(f"batch error: {exc}")


if __name__ == "__main__":
    print(f"svc started. Watching {INBOX}")
    while True:
        run_batch()
        time.sleep(POLL_SECONDS)
