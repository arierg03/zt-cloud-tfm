import os
import time
import logging
from datetime import datetime, timezone

import psycopg

DATABASE_URL = os.getenv("DATABASE_URL", "postgresql://events_user:events_pass@db:5432/events")
POLL_SECONDS = int(os.getenv("POLL_SECONDS", "86400"))
RUN_ONCE = os.getenv("RUN_ONCE", "false").lower() == "true"

LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO").upper()
logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s %(levelname)s [svc] %(message)s",
)
logger = logging.getLogger("events-svc")


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def fetch_events_to_process(conn) -> list[dict]:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT e.id, e.title, e.manual_description, e.event_date, e.country, e.language
            FROM events e
            WHERE EXISTS (
                SELECT 1 FROM images i WHERE i.event_id = e.id
            )
            AND (
                e.processed_at IS NULL
                OR EXISTS (
                    SELECT 1
                    FROM images i2
                    WHERE i2.event_id = e.id
                    AND i2.created_at > e.processed_at
                )
            )
            ORDER BY e.created_at ASC
            """
        )
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
            SELECT id, filename, mime_type, caption, width, height, hash, created_at
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
                "filename": row[1],
                "mime_type": row[2],
                "caption": row[3],
                "width": row[4],
                "height": row[5],
                "hash": row[6],
                "created_at": row[7],
            }
        )
    return images


def external_agent_generate_description(event: dict, images: list[dict]) -> str:
    # Simulacion de agente externo: resume metadatos del evento + observaciones de imagen.
    caption_texts = [img["caption"].strip() for img in images if img.get("caption") and img["caption"].strip()]
    mime_types = sorted({img["mime_type"] for img in images if img.get("mime_type")})

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
    mime_summary = ", ".join(mime_types) if mime_types else "tipo no especificado"

    language = (event.get("language") or "es").lower()
    if language.startswith("en"):
        return (
            f"Event '{event['title']}' ({country}, {event_date}). "
            f"Manual description: {manual_description}. "
            f"The batch analyzed {len(images)} image(s) with formats {mime_summary}, {dimensions_summary}. "
            f"Main visual notes from captions: {captions_summary}."
        )

    return (
        f"Evento '{event['title']}' ({country}, {event_date}). "
        f"Descripcion manual: {manual_description}. "
        f"El batch analizo {len(images)} imagen(es) con formatos {mime_summary}, {dimensions_summary}. "
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
    logger.info("Batch run started")
    with psycopg.connect(DATABASE_URL) as conn:
        batch_id = create_batch_execution(conn)
        total_detected = 0
        total_processed = 0
        total_failed = 0
        errors: list[str] = []

        try:
            events = fetch_events_to_process(conn)
            total_detected = len(events)

            for event in events:
                try:
                    images = fetch_event_images(conn, event["id"])
                    generated_description = external_agent_generate_description(event, images)
                    update_event_processed(conn, event["id"], generated_description, batch_id)
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
        "Service started | poll_seconds=%s run_once=%s db_host=%s",
        POLL_SECONDS,
        RUN_ONCE,
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
