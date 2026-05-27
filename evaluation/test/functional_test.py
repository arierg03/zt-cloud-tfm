import argparse
import json
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

import requests


def now_iso():
    return datetime.now(timezone.utc).isoformat()


def run_step(test_id, name, func):
    start = time.perf_counter()
    try:
        detail = func()
        elapsed_ms = round((time.perf_counter() - start) * 1000, 2)
        return {
            "id": test_id,
            "name": name,
            "status": "PASS",
            "response_time_ms": elapsed_ms,
            "detail": detail,
        }
    except Exception as exc:
        elapsed_ms = round((time.perf_counter() - start) * 1000, 2)
        return {
            "id": test_id,
            "name": name,
            "status": "FAIL",
            "response_time_ms": elapsed_ms,
            "detail": str(exc),
        }


def assert_status(response, expected_statuses):
    if response.status_code not in expected_statuses:
        raise RuntimeError(
            f"HTTP {response.status_code}. Respuesta: {response.text[:500]}"
        )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--env", required=True, choices=["base", "zt"])
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--email", required=True)
    parser.add_argument("--password", required=True)
    parser.add_argument("--image-path", required=True)
    parser.add_argument("--output-dir", default="evaluation/results")
    parser.add_argument("--trigger-batch-before-pf05", action="store_true")
    parser.add_argument("--k8s-namespace", default="tfm-app")
    parser.add_argument("--cronjob-name", default="svc")
    parser.add_argument("--kubectl-timeout-seconds", type=int, default=600)
    args = parser.parse_args()

    base_url = args.base_url.rstrip("/")
    output_dir = Path(args.output_dir) / args.env
    output_dir.mkdir(parents=True, exist_ok=True)

    session = requests.Session()
    token = None
    event_id = None

    def trigger_batch_job():
        job_name = f"{args.cronjob_name}-manual-{datetime.now(timezone.utc).strftime('%Y%m%d%H%M%S')}"

        create_cmd = [
            "kubectl",
            "-n",
            args.k8s_namespace,
            "create",
            "job",
            f"--from=cronjob/{args.cronjob_name}",
            job_name,
        ]
        create_result = subprocess.run(create_cmd, capture_output=True, text=True)
        if create_result.returncode != 0:
            raise RuntimeError(
                "No se pudo crear el Job manual del CronJob. "
                f"Comando: {' '.join(create_cmd)}. "
                f"stderr: {create_result.stderr.strip()}"
            )

        wait_cmd = [
            "kubectl",
            "-n",
            args.k8s_namespace,
            "wait",
            "--for=condition=complete",
            f"job/{job_name}",
            f"--timeout={args.kubectl_timeout_seconds}s",
        ]
        wait_result = subprocess.run(wait_cmd, capture_output=True, text=True)
        if wait_result.returncode != 0:
            raise RuntimeError(
                "El Job manual del batch no terminó correctamente. "
                f"Comando: {' '.join(wait_cmd)}. "
                f"stderr: {wait_result.stderr.strip()}"
            )

        return {
            "triggered": True,
            "namespace": args.k8s_namespace,
            "cronjob_name": args.cronjob_name,
            "job_name": job_name,
            "wait_timeout_seconds": args.kubectl_timeout_seconds,
        }

    def pf01_availability():
        frontend = requests.get(base_url, timeout=15)
        assert_status(frontend, [200])

        api_health = requests.get(f"{base_url}/api/health", timeout=15)
        assert_status(api_health, [200])

        health_data = api_health.json()
        if health_data.get("status") != "ok":
            raise RuntimeError(f"Health inválido: {health_data}")

        return {
            "frontend_status": frontend.status_code,
            "api_health_status": api_health.status_code,
            "api_health_body": health_data,
        }

    def pf02_login():
        nonlocal token

        payload = {
            "identifier": args.email,
            "password": args.password,
        }

        response = session.post(
            f"{base_url}/api/auth/login",
            json=payload,
            timeout=15,
        )
        assert_status(response, [200])

        data = response.json()
        token = data.get("access_token")
        if not token:
            raise RuntimeError(f"No se encontró access_token en la respuesta: {data}")

        session.headers.update({"Authorization": f"Bearer {token}"})

        if data.get("token_type") != "bearer":
            raise RuntimeError(f"token_type inesperado: {data.get('token_type')}")

        return {
            "login_status": response.status_code,
            "token_received": True,
            "token_type": data.get("token_type"),
            "user_email": data.get("user", {}).get("email"),
        }

    def pf03_create_event():
        nonlocal event_id

        event_payload = {
            "title": f"Evento prueba cloud {args.env}",
            "manual_description": "Evento generado automáticamente en el test funcional.",
            "event_date": now_iso(),
            "country": "ES",
            "language": "es",
        }

        response = session.post(
            f"{base_url}/api/events",
            json=event_payload,
            timeout=15,
        )
        assert_status(response, [201])

        data = response.json()
        event_id = data.get("id")

        if not event_id:
            raise RuntimeError(f"No se encontró id del evento en la respuesta: {data}")

        return {
            "create_event_status": response.status_code,
            "event_id": event_id,
        }

    def pf04_upload_image():
        if not event_id:
            raise RuntimeError("No hay event_id disponible para subir imagen.")

        image_path = Path(args.image_path)
        if not image_path.exists():
            raise RuntimeError(f"No existe la imagen de prueba: {image_path}")

        with image_path.open("rb") as image_file:
            files = {
                "file": (
                    image_path.name,
                    image_file,
                    "image/jpeg",
                )
            }

            response = session.post(
                f"{base_url}/api/events/{event_id}/image",
                files=files,
                timeout=30,
            )

        assert_status(response, [201])
        data = response.json()

        returned_event_id = data.get("event_id")
        if returned_event_id != event_id:
            raise RuntimeError(
                f"event_id inesperado en respuesta de imagen. Esperado {event_id}, recibido {returned_event_id}. Body: {data}"
            )

        response_filename = data.get("filename")
        if not response_filename:
            raise RuntimeError(f"No se encontró filename en la respuesta de imagen: {data}")

        image_url = data.get("image_url")
        if not image_url:
            raise RuntimeError(f"No se encontró image_url en la respuesta de imagen: {data}")

        return {
            "upload_image_status": response.status_code,
            "event_id": event_id,
            "image_name": image_path.name,
            "response_filename": response_filename,
            "image_url_present": True,
        }

    def pf05_query_event_and_batch():
        if not event_id:
            raise RuntimeError("No hay event_id disponible para consultar.")

        batch_trigger = {
            "triggered": False,
            "reason": "Flag --trigger-batch-before-pf05 no activada",
        }
        if args.trigger_batch_before_pf05:
            batch_trigger = trigger_batch_job()

        event_response = session.get(f"{base_url}/api/events/{event_id}", timeout=15)
        assert_status(event_response, [200])
        event_data = event_response.json()

        if event_data.get("id") != event_id:
            raise RuntimeError(f"Evento devuelto no coincide: {event_data}")

        batch_response = session.get(f"{base_url}/api/batch/status", timeout=15)
        assert_status(batch_response, [200, 404])
        batch_data = batch_response.json()

        return {
            "event_status": event_response.status_code,
            "event_id": event_id,
            "event_title_present": bool(event_data.get("title")),
            "batch_status": batch_response.status_code,
            "batch_available": batch_response.status_code == 200,
            "batch_trigger": batch_trigger,
            "event_body": event_data,
            "batch_body": batch_data,
        }

    tests = [
        run_step("F1", "Comprobación de disponibilidad", pf01_availability),
        run_step("F2", "Autenticación de usuario", pf02_login),
        run_step("F3", "Creación de evento", pf03_create_event),
        run_step("F4", "Subida de imagen", pf04_upload_image),
        run_step("F5", "Consulta de evento y resultado batch", pf05_query_event_and_batch),
    ]

    result = {
        "environment": args.env,
        "base_url": base_url,
        "timestamp": now_iso(),
        "summary": {
            "total": len(tests),
            "passed": sum(1 for test in tests if test["status"] == "PASS"),
            "failed": sum(1 for test in tests if test["status"] == "FAIL"),
        },
        "tests": tests,
    }

    output_file = output_dir / f"functional_{args.env}.json"
    output_file.write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding="utf-8")

    print(json.dumps(result, indent=2, ensure_ascii=False))

    if result["summary"]["failed"] > 0:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
