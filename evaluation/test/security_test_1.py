import argparse
import json
import time
from datetime import datetime, timezone
from pathlib import Path
import socket

import requests


class StructuredTestFailure(Exception):
    def __init__(self, message, detail):
        super().__init__(message)
        self.message = message
        self.detail = detail


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
    except StructuredTestFailure as exc:
        elapsed_ms = round((time.perf_counter() - start) * 1000, 2)
        return {
            "id": test_id,
            "name": name,
            "status": "FAIL",
            "response_time_ms": elapsed_ms,
            "detail": {
                "message": exc.message,
                **exc.detail,
            },
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


def expect_status(response, expected_statuses, description):
    if response.status_code not in expected_statuses:
        raise RuntimeError(
            f"{description}. Esperado {expected_statuses}, recibido HTTP {response.status_code}. "
            f"Respuesta: {response.text[:500]}"
        )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--env", required=True, choices=["base", "zt"])
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--output-dir", default="evaluation/results")
    parser.add_argument("--db-host", default=None)
    parser.add_argument("--db-port", type=int, default=5432)
    parser.add_argument("--s3-bucket", default=None)
    parser.add_argument("--s3-region", default="eu-south-2")
    parser.add_argument("--s3-test-object-key", default=None)
    args = parser.parse_args()

    base_url = args.base_url.rstrip("/")
    output_dir = Path(args.output_dir) / args.env
    output_dir.mkdir(parents=True, exist_ok=True)

    private_endpoint = f"{base_url}/api/events"

    def s1_access_without_token():
        response = requests.get(private_endpoint, timeout=15)
        expect_status(
            response,
            [401, 403],
            "El endpoint privado debería rechazar acceso sin token",
        )

        body = response.json()
        detail = body.get("detail")

        if not detail:
            raise RuntimeError(f"Respuesta sin detalle de error: {body}")

        return {
            "endpoint": private_endpoint,
            "status_code": response.status_code,
            "detail": detail,
            "access_denied": True,
        }

    def s2_access_with_invalid_token():
        fake_jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxIiwicm9sZSI6ImFkbWluIn0.invalidsignature"
        headers = {"Authorization": f"Bearer {fake_jwt}"}

        response = requests.get(private_endpoint, headers=headers, timeout=15)

        expect_status(
            response,
            [401, 403],
            "El endpoint privado debería rechazar token inválido",
        )

        body = response.json()
        detail = body.get("detail")
        if not detail:
            raise RuntimeError(f"Respuesta sin detalle de error: {body}")

        return {
            "endpoint": private_endpoint,
            "status_code": response.status_code,
            "detail": detail,
            "access_denied": True,
        }

    def s3_internal_endpoints_not_exposed_from_outside():
        internal_endpoints = [
            f"{base_url}/metrics",
            f"{base_url}/admin",
            f"{base_url}/docs",
            f"{base_url}/openapi.json",
            f"{base_url}/api/docs",
        ]

        def classify_internal(status_code):
            if status_code == 200:
                return "FAIL_CRITICAL", "Endpoint interno expuesto públicamente"
            if status_code in [401, 403]:
                return "FAIL_MODERATE", "Endpoint interno publicado (protegido, pero alcanzable)"
            if status_code in [404, 502, 503]:
                return "PASS", "No expuesto por superficie pública"
            return "FAIL_MODERATE", f"Estado inesperado: HTTP {status_code}"

        checked = []

        # HTTP
        for endpoint in internal_endpoints:
            try:
                response = requests.get(endpoint, timeout=10)
                classification, reason = classify_internal(response.status_code)
                checked.append(
                    {
                        "component": "http-internal",
                        "endpoint": endpoint,
                        "status_code": response.status_code,
                        "classification": classification,
                        "reason": reason,
                    }
                )
            except requests.RequestException as exc:
                checked.append(
                    {
                        "component": "http-internal",
                        "endpoint": endpoint,
                        "status_code": None,
                        "classification": "PASS",
                        "reason": f"No alcanzable desde fuera ({exc})",
                    }
                )

        # RDS
        if args.db_host:
            try:
                with socket.create_connection((args.db_host, args.db_port), timeout=5):
                    checked.append(
                        {
                            "component": "rds",
                            "endpoint": f"{args.db_host}:{args.db_port}",
                            "status_code": None,
                            "classification": "FAIL_CRITICAL",
                            "reason": "Puerto de base de datos accesible desde cliente externo",
                        }
                    )
            except (TimeoutError, OSError) as exc:
                checked.append(
                    {
                        "component": "rds",
                        "endpoint": f"{args.db_host}:{args.db_port}",
                        "status_code": None,
                        "classification": "PASS",
                        "reason": f"Base de datos no accesible directamente ({exc})",
                    }
                )
        else:
            checked.append(
                {
                    "component": "rds",
                    "endpoint": None,
                    "status_code": None,
                    "classification": "INFO",
                    "reason": "Comprobación RDS omitida (sin --db-host)",
                }
            )

        # S3
        if args.s3_bucket:
            s3_base = f"https://{args.s3_bucket}.s3.{args.s3_region}.amazonaws.com"

            # Bucket root
            try:
                bucket_resp = requests.get(s3_base, timeout=10)
                if bucket_resp.status_code == 200:
                    cls, rsn = "FAIL_CRITICAL", "Bucket S3 accesible de forma anónima (listing/root)"
                elif bucket_resp.status_code in [403, 404]:
                    cls, rsn = "PASS", "Bucket no accesible anónimamente"
                else:
                    cls, rsn = "FAIL_MODERATE", f"Estado inesperado en bucket root: HTTP {bucket_resp.status_code}"

                checked.append(
                    {
                        "component": "s3",
                        "endpoint": s3_base,
                        "status_code": bucket_resp.status_code,
                        "classification": cls,
                        "reason": rsn,
                    }
                )
            except requests.RequestException as exc:
                checked.append(
                    {
                        "component": "s3",
                        "endpoint": s3_base,
                        "status_code": None,
                        "classification": "PASS",
                        "reason": f"No alcanzable desde fuera ({exc})",
                    }
                )

            # Optional test object
            if args.s3_test_object_key:
                obj_url = f"{s3_base}/{args.s3_test_object_key.lstrip('/')}"
                try:
                    obj_resp = requests.get(obj_url, timeout=10)
                    if obj_resp.status_code == 200:
                        cls, rsn = "FAIL_CRITICAL", "Objeto S3 accesible de forma anónima"
                    elif obj_resp.status_code in [403, 404]:
                        cls, rsn = "PASS", "Objeto no accesible anónimamente"
                    else:
                        cls, rsn = "FAIL_MODERATE", f"Estado inesperado en objeto S3: HTTP {obj_resp.status_code}"

                    checked.append(
                        {
                            "component": "s3",
                            "endpoint": obj_url,
                            "status_code": obj_resp.status_code,
                            "classification": cls,
                            "reason": rsn,
                        }
                    )
                except requests.RequestException as exc:
                    checked.append(
                        {
                            "component": "s3",
                            "endpoint": obj_url,
                            "status_code": None,
                            "classification": "PASS",
                            "reason": f"No alcanzable desde fuera ({exc})",
                        }
                    )
        else:
            checked.append(
                {
                    "component": "s3",
                    "endpoint": None,
                    "status_code": None,
                    "classification": "INFO",
                    "reason": "Comprobación S3 omitida (sin --s3-bucket)",
                }
            )

        critical = [item for item in checked if item["classification"] == "FAIL_CRITICAL"]
        moderate = [item for item in checked if item["classification"] == "FAIL_MODERATE"]

        if critical or moderate:
            raise StructuredTestFailure(
                "Se detectó exposición de componentes internos.",
                {
                    "critical_count": len(critical),
                    "moderate_count": len(moderate),
                    "findings": critical + moderate,
                    "checked": checked,
                },
            )

        return {
            "checked_endpoints": checked,
            "critical_exposed": len(critical),
            "moderate_exposed": len(moderate),
            "total_checked": len(checked),
        }

    tests = [
        run_step("S1", "Acceso sin token a endpoint privado", s1_access_without_token),
        run_step("S2", "Acceso con token inválido o caducado", s2_access_with_invalid_token),
        run_step("S3", "Intento de acceso directo a componentes internos desde el exterior", s3_internal_endpoints_not_exposed_from_outside),
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

    output_file = output_dir / f"security_{args.env}_1.json"
    output_file.write_text(
        json.dumps(result, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )

    print(json.dumps(result, indent=2, ensure_ascii=False))

    if result["summary"]["failed"] > 0:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
