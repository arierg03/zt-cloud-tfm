import os
import time
import logging
from functools import lru_cache
from datetime import datetime, timezone
from urllib.parse import urlparse

import boto3
import psycopg
from botocore.client import Config
from botocore.exceptions import BotoCoreError, ClientError

DATABASE_URL = os.getenv("DATABASE_URL", "postgresql://events_user:events_pass@db:5432/events")
POLL_SECONDS = int(os.getenv("POLL_SECONDS", "86400"))
RUN_ONCE = os.getenv("RUN_ONCE", "false").lower() == "true"
SVC_FORCE_REPROCESS = os.getenv("SVC_FORCE_REPROCESS", "false").lower() == "true"
SVC_MAX_EVENTS_BATCH = int(os.getenv("SVC_MAX_EVENTS_BATCH", "0"))
SVC_MAX_IMAGES_ANALYZED = int(os.getenv("SVC_MAX_IMAGES_ANALYZED", "6"))
S3_ENDPOINT = os.getenv("S3_ENDPOINT", "http://minio:9000")
S3_ACCESS_KEY = os.getenv("S3_ACCESS_KEY", "minioadmin")
S3_SECRET_KEY = os.getenv("S3_SECRET_KEY", "minioadmin")
S3_BUCKET = os.getenv("S3_BUCKET", "events-images")
S3_REGION = os.getenv("S3_REGION", "eu-south-2")
S3_USE_SSL = os.getenv("S3_USE_SSL", "false").lower() == "true"

LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO").upper()
logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s %(levelname)s [svc] %(message)s",
)
logger = logging.getLogger("events-svc")


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def _is_path_style(endpoint: str) -> bool:
    host = urlparse(endpoint).hostname or ""
    return host in {"minio", "localhost", "127.0.0.1"}


@lru_cache(maxsize=1)
def get_s3_client():
    return boto3.client(
        "s3",
        endpoint_url=S3_ENDPOINT,
        aws_access_key_id=S3_ACCESS_KEY,
        aws_secret_access_key=S3_SECRET_KEY,
        region_name=S3_REGION,
        use_ssl=S3_USE_SSL,
        config=Config(signature_version="s3v4", s3={"addressing_style": "path" if _is_path_style(S3_ENDPOINT) else "virtual"}),
    )


def fetch_events_to_process(conn, force_reprocess: bool, max_events_batch: int) -> list[dict]:
    query = """
        SELECT e.id, e.title, e.manual_description, e.event_date, e.country, e.language
        FROM events e
        WHERE EXISTS (
            SELECT 1 FROM images i WHERE i.event_id = e.id
        )
    """
    params: list[object] = []
    if not force_reprocess:
        query += """
        AND (
            e.processed_at IS NULL
            OR EXISTS (
                SELECT 1
                FROM images i2
                WHERE i2.event_id = e.id
                AND i2.created_at > e.processed_at
            )
        )
        """
    query += "\nORDER BY e.created_at ASC"
    if max_events_batch > 0:
        query += "\nLIMIT %s"
        params.append(max_events_batch)

    with conn.cursor() as cur:
        cur.execute(query, params)
        rows = cur.fetchall()

    events: list[dict] = []
    for row in rows:
        events.append(
            {
                "id": row[0],
                "title": row[1],
                "manual_description": row[2],
                "event_date": row[3],
                "country": row[4],
                "language": row[5] or "es",
            }
        )
    return events


def fetch_event_images(conn, event_id: int) -> list[dict]:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT id, storage_path, filename, mime_type, caption, width, height, hash, created_at
            FROM images
            WHERE event_id = %s
            ORDER BY created_at ASC, id ASC
            """,
            (event_id,),
        )
        rows = cur.fetchall()

    images: list[dict] = []
    for row in rows:
        images.append(
            {
                "id": row[0],
                "storage_path": row[1],
                "filename": row[2],
                "mime_type": row[3],
                "caption": row[4],
                "width": row[5],
                "height": row[6],
                "hash": row[7],
                "created_at": row[8],
            }
        )
    return images


def fetch_s3_image_metadata(images: list[dict]) -> list[dict]:
    s3_client = get_s3_client()
    s3_metadata: list[dict] = []

    for image in images[: max(1, SVC_MAX_IMAGES_ANALYZED)]:
        storage_path = image.get("storage_path")
        if not storage_path:
            continue
        try:
            obj = s3_client.head_object(Bucket=S3_BUCKET, Key=storage_path)
            s3_metadata.append(
                {
                    "image_id": image.get("id"),
                    "storage_path": storage_path,
                    "content_type": obj.get("ContentType"),
                    "size_bytes": obj.get("ContentLength"),
                    "last_modified": obj.get("LastModified"),
                    "etag": str(obj.get("ETag", "")).replace('"', ""),
                }
            )
        except (ClientError, BotoCoreError, KeyError) as exc:
            logger.warning("Could not read S3 metadata for image id=%s from storage: %s", image.get("id"), exc)

    return s3_metadata


def generate_event_description(event: dict, images: list[dict], s3_metadata: list[dict]) -> str:
    caption_texts = [img["caption"].strip() for img in images if img.get("caption") and img["caption"].strip()]
    db_mime_types = sorted({img["mime_type"] for img in images if img.get("mime_type")})

    dimensions = [
        (img["width"], img["height"])
        for img in images
        if img.get("width") is not None and img.get("height") is not None
    ]
    if dimensions:
        min_w = min(d[0] for d in dimensions)
        max_w = max(d[0] for d in dimensions)
        min_h = min(d[1] for d in dimensions)
        max_h = max(d[1] for d in dimensions)
        dimensions_summary = f"resoluciones entre {min_w}x{min_h} y {max_w}x{max_h}"
    else:
        dimensions_summary = "resolucion no disponible"

    event_date = event["event_date"].isoformat() if event.get("event_date") else "sin fecha definida"
    country = event.get("country") or "pais no especificado"
    manual_description = event.get("manual_description") or "sin descripcion manual"

    captions_summary = "; ".join(caption_texts[:5]) if caption_texts else "sin captions"
    db_mime_summary = ", ".join(db_mime_types) if db_mime_types else "tipo no especificado"

    s3_content_types = sorted({m["content_type"] for m in s3_metadata if m.get("content_type")})
    s3_mime_summary = ", ".join(s3_content_types) if s3_content_types else "tipo no disponible en S3"
    sizes = [int(m["size_bytes"]) for m in s3_metadata if m.get("size_bytes") is not None]
    if sizes:
        total_kb = sum(sizes) / 1024
        min_kb = min(sizes) / 1024
        max_kb = max(sizes) / 1024
        size_summary = (
            f"tamano total aproximado {total_kb:.1f} KB, rango por imagen {min_kb:.1f}-{max_kb:.1f} KB"
        )
    else:
        size_summary = "tamano no disponible"

    etag_count = len([m for m in s3_metadata if m.get("etag")])
    latest_modified_values = [m["last_modified"] for m in s3_metadata if m.get("last_modified") is not None]
    if latest_modified_values:
        latest_modified = max(latest_modified_values).isoformat()
    else:
        latest_modified = "no disponible"

    language = (event.get("language") or "es").lower()
    if language.startswith("en"):
        return (
            f"Event '{event['title']}' ({country}, {event_date}). "
            f"Manual description: {manual_description}. "
            f"Database metadata from {len(images)} image(s): formats {db_mime_summary}, {dimensions_summary}. "
            f"S3 metadata inspected in {len(s3_metadata)} image(s): formats {s3_mime_summary}, {size_summary}, "
            f"etag entries {etag_count}, latest modification {latest_modified}. "
            f"Main visual notes from captions: {captions_summary}."
        )

    return (
        f"Evento '{event['title']}' ({country}, {event_date}). "
        f"Descripcion manual: {manual_description}. "
        f"Metadatos en BD de {len(images)} imagen(es): formatos {db_mime_summary}, {dimensions_summary}. "
        f"Metadatos leidos en S3 para {len(s3_metadata)} imagen(es): formatos {s3_mime_summary}, {size_summary}, "
        f"entradas etag {etag_count}, ultima modificacion {latest_modified}. "
        f"Observaciones visuales principales segun captions: {captions_summary}."
    )


def update_event_processed(conn, event_id: int, generated_description: str, batch_id: int) -> None:
    now = utcnow()
    with conn.cursor() as cur:
        cur.execute(
            """
            UPDATE events
            SET generated_description = %s,
                last_batch_execution_id = %s,
                processed_at = %s,
                status = %s,
                updated_at = %s
            WHERE id = %s
            """,
            (generated_description, batch_id, now, "processed", now, event_id),
        )


def mark_event_failed(conn, event_id: int) -> None:
    with conn.cursor() as cur:
        cur.execute(
            """
            UPDATE events
            SET status = %s,
                updated_at = %s
            WHERE id = %s
            """,
            ("processing_failed", utcnow(), event_id),
        )


def create_batch_execution(conn) -> int:
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO batch_executions (started_at, status, total_events_detected, total_events_processed, total_events_failed)
            VALUES (%s, %s, %s, %s, %s)
            RETURNING id
            """,
            (utcnow(), "running", 0, 0, 0),
        )
        row = cur.fetchone()
    return int(row[0])


def finalize_batch_execution(
    conn,
    batch_id: int,
    total_detected: int,
    total_processed: int,
    total_failed: int,
    errors: list[str],
) -> None:
    final_status = "success"
    if total_detected == 0:
        final_status = "no_events"
    elif total_processed > 0 and total_failed > 0:
        final_status = "partial_success"
    elif total_processed == 0 and total_failed > 0:
        final_status = "failed"

    summary = (
        f"Eventos detectados: {total_detected}. "
        f"Procesados correctamente: {total_processed}. "
        f"Fallidos: {total_failed}."
    )
    error_message = " | ".join(errors[:10]) if errors else None

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
                utcnow(),
                final_status,
                total_detected,
                total_processed,
                total_failed,
                summary,
                error_message,
                batch_id,
            ),
        )


def run_batch_once() -> None:
    logger.info(
        "Batch run started | force_reprocess=%s max_events_batch=%s",
        SVC_FORCE_REPROCESS,
        SVC_MAX_EVENTS_BATCH if SVC_MAX_EVENTS_BATCH > 0 else "unlimited",
    )
    with psycopg.connect(DATABASE_URL) as conn:
        batch_id = create_batch_execution(conn)
        total_detected = 0
        total_processed = 0
        total_failed = 0
        errors: list[str] = []

        try:
            events = fetch_events_to_process(
                conn,
                force_reprocess=SVC_FORCE_REPROCESS,
                max_events_batch=SVC_MAX_EVENTS_BATCH,
            )
            total_detected = len(events)

            for event in events:
                try:
                    images = fetch_event_images(conn, event["id"])
                    s3_metadata = fetch_s3_image_metadata(images)
                    generated_description = generate_event_description(event, images, s3_metadata)
                    update_event_processed(conn, event["id"], generated_description, batch_id)
                    logger.info(
                        "Event processed | event_id=%s images_db=%s images_s3=%s",
                        event["id"],
                        len(images),
                        len(s3_metadata),
                    )
                    total_processed += 1
                except Exception as event_exc:
                    total_failed += 1
                    mark_event_failed(conn, event["id"])
                    errors.append(f"event_id={event['id']}: {event_exc}")

            finalize_batch_execution(
                conn,
                batch_id=batch_id,
                total_detected=total_detected,
                total_processed=total_processed,
                total_failed=total_failed,
                errors=errors,
            )
            conn.commit()
            logger.info(
                "Batch run finished | batch_id=%s detected=%s processed=%s failed=%s",
                batch_id,
                total_detected,
                total_processed,
                total_failed,
            )
        except Exception as batch_exc:
            errors.append(str(batch_exc))
            finalize_batch_execution(
                conn,
                batch_id=batch_id,
                total_detected=total_detected,
                total_processed=total_processed,
                total_failed=max(total_failed, 1),
                errors=errors,
            )
            conn.commit()
            logger.exception("Batch run failed | batch_id=%s error=%s", batch_id, batch_exc)


if __name__ == "__main__":
    logger.info(
        "Service started | poll_seconds=%s run_once=%s force_reprocess=%s max_events_batch=%s db_host=%s",
        POLL_SECONDS,
        RUN_ONCE,
        SVC_FORCE_REPROCESS,
        SVC_MAX_EVENTS_BATCH if SVC_MAX_EVENTS_BATCH > 0 else "unlimited",
        DATABASE_URL.split("@")[-1] if "@" in DATABASE_URL else "n/a",
    )
    while True:
        try:
            run_batch_once()
        except Exception:
            logger.exception("Unexpected error in scheduler loop")
        if RUN_ONCE:
            logger.info("RUN_ONCE=true, stopping service after one iteration")
            break
        logger.info("Sleeping for %s seconds before next run", POLL_SECONDS)
        time.sleep(POLL_SECONDS)
