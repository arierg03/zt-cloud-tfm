import argparse
import json
import statistics
import time
from datetime import datetime, timezone
from pathlib import Path

import matplotlib.pyplot as plt
import requests


def now_iso():
    return datetime.now(timezone.utc).isoformat()


def percentile(values, p):
    if not values:
        return None

    sorted_values = sorted(values)
    index = int(round((p / 100) * (len(sorted_values) - 1)))
    return sorted_values[index]


def measure_request(func):
    start = time.perf_counter()
    try:
        response = func()
        elapsed_ms = round((time.perf_counter() - start) * 1000, 2)

        return {
            "success": 200 <= response.status_code < 400,
            "status_code": response.status_code,
            "elapsed_ms": elapsed_ms,
            "error": None,
        }

    except Exception as exc:
        elapsed_ms = round((time.perf_counter() - start) * 1000, 2)

        return {
            "success": False,
            "status_code": None,
            "elapsed_ms": elapsed_ms,
            "error": str(exc),
        }


def summarize_measurements(measurements):
    successful_times = [
        item["elapsed_ms"]
        for item in measurements
        if item["success"]
    ]

    failed = [
        item
        for item in measurements
        if not item["success"]
    ]

    if not successful_times:
        return {
            "iterations": len(measurements),
            "successful": 0,
            "failed": len(failed),
            "min_ms": None,
            "max_ms": None,
            "avg_ms": None,
            "median_ms": None,
            "p95_ms": None,
        }

    return {
        "iterations": len(measurements),
        "successful": len(successful_times),
        "failed": len(failed),
        "min_ms": round(min(successful_times), 2),
        "max_ms": round(max(successful_times), 2),
        "avg_ms": round(statistics.mean(successful_times), 2),
        "median_ms": round(statistics.median(successful_times), 2),
        "p95_ms": round(percentile(successful_times, 95), 2),
    }


def assert_expected_status(response, expected_statuses):
    if response.status_code not in expected_statuses:
        raise RuntimeError(
            f"HTTP {response.status_code}. Respuesta: {response.text[:500]}"
        )


def login(session, base_url, email, password):
    response = session.post(
        f"{base_url}/api/auth/login",
        json={
            "identifier": email,
            "password": password,
        },
        timeout=20,
    )

    assert_expected_status(response, [200])

    data = response.json()

    token = (
        data.get("access")
        or data.get("access_token")
        or data.get("token")
    )

    if not token:
        raise RuntimeError(f"No se encontró token en la respuesta de login: {data}")

    session.headers.update({"Authorization": f"Bearer {token}"})

    return token


def create_event(session, base_url, env_name):
    response = session.post(
        f"{base_url}/api/events",
        json={
            "title": f"Evento rendimiento {env_name}",
            "manual_description": "Evento generado automáticamente para pruebas de rendimiento.",
            "event_date": now_iso(),
            "country": "ES",
            "language": "es",
        },
        timeout=20,
    )

    assert_expected_status(response, [201])

    data = response.json()
    event_id = data.get("id")

    if not event_id:
        raise RuntimeError(f"No se encontró id del evento: {data}")

    return event_id


def run_performance_test(test_id, name, iterations, request_func):
    measurements = []

    for _ in range(iterations):
        measurements.append(measure_request(request_func))

    return {
        "id": test_id,
        "name": name,
        "summary": summarize_measurements(measurements),
        "measurements": measurements,
    }


def safe_name(text):
    normalized = (
        text.lower()
        .replace(" ", "_")
        .replace("á", "a")
        .replace("é", "e")
        .replace("í", "i")
        .replace("ó", "o")
        .replace("ú", "u")
    )
    return "".join(ch if ch.isalnum() or ch in ("_", "-") else "_" for ch in normalized)


def generate_plots(tests, environment, output_dir):
    output_dir.mkdir(parents=True, exist_ok=True)

    labels = []
    series = []
    for test in tests:
        successful_times = [m["elapsed_ms"] for m in test["measurements"] if m["success"]]
        if successful_times:
            labels.append(test["id"])
            series.append(successful_times)

    if series:
        plt.figure(figsize=(10, 6))
        plt.boxplot(series, tick_labels=labels, showfliers=True)
        plt.title(f"Distribucion de tiempos por prueba ({environment})")
        plt.xlabel("Prueba")
        plt.ylabel("Tiempo (ms)")
        plt.grid(axis="y", linestyle="--", alpha=0.4)
        plt.tight_layout()
        plt.savefig(output_dir / f"performance_boxplot_{environment}.png", dpi=150)
        plt.close()

    for test in tests:
        x_values = list(range(1, len(test["measurements"]) + 1))
        y_values = [m["elapsed_ms"] for m in test["measurements"]]
        colors = ["#2ca02c" if m["success"] else "#d62728" for m in test["measurements"]]

        plt.figure(figsize=(10, 4))
        plt.scatter(x_values, y_values, c=colors, s=20)
        plt.plot(x_values, y_values, linewidth=1.0, alpha=0.6)
        plt.title(f"{test['id']} - {test['name']} ({environment})")
        plt.xlabel("Iteracion")
        plt.ylabel("Tiempo (ms)")
        plt.grid(linestyle="--", alpha=0.4)
        plt.tight_layout()
        file_name = f"{safe_name(test['id'] + '_' + test['name'])}_{environment}.png"
        plt.savefig(output_dir / file_name, dpi=150)
        plt.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--env", required=True, choices=["base", "zt"])
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--email", required=True)
    parser.add_argument("--password", required=True)
    parser.add_argument("--image-path", required=True)
    parser.add_argument("--iterations", type=int, default=20)
    parser.add_argument("--output-dir", default="evaluation/results")
    parser.add_argument("--skip-plots", action="store_true")
    args = parser.parse_args()

    base_url = args.base_url.rstrip("/")
    output_dir = Path(args.output_dir) / args.env
    output_dir.mkdir(parents=True, exist_ok=True)

    image_path = Path(args.image_path)

    if not image_path.exists():
        raise RuntimeError(f"No existe la imagen de prueba: {image_path}")

    session = requests.Session()

    login(session, base_url, args.email, args.password)

    event_id = create_event(session, base_url, args.env)

    def r1_simple_endpoint():
        response = session.get(
            f"{base_url}/api/health",
            timeout=20,
        )
        assert_expected_status(response, [200])

        body = response.json()
        if body.get("status") != "ok":
            raise RuntimeError(f"Health inválido: {body}")

        return response

    def r2_login():
        temp_session = requests.Session()
        response = temp_session.post(
            f"{base_url}/api/auth/login",
            json={
                "identifier": args.email,
                "password": args.password,
            },
            timeout=20,
        )
        assert_expected_status(response, [200])

        data = response.json()
        if not data.get("access_token"):
            raise RuntimeError(f"Login sin access_token: {data}")

        return response

    def r3_upload_image():
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
                timeout=40,
            )

        assert_expected_status(response, [201])

        data = response.json()
        if data.get("event_id") != event_id:
            raise RuntimeError(f"event_id inesperado: {data}")
        if not data.get("image_url"):
            raise RuntimeError(f"Sin image_url en respuesta: {data}")

        return response

    tests = [
        run_performance_test(
            "R1",
            "Tiempo medio de respuesta de un endpoint simple",
            args.iterations,
            r1_simple_endpoint,
        ),
        run_performance_test(
            "R2",
            "Tiempo de autenticación de usuario",
            args.iterations,
            r2_login,
        ),
        run_performance_test(
            "R3",
            "Tiempo de subida de imagen",
            args.iterations,
            r3_upload_image,
        ),
    ]

    result = {
        "environment": args.env,
        "base_url": base_url,
        "timestamp": now_iso(),
        "iterations_per_test": args.iterations,
        "tests": tests,
    }

    output_file = output_dir / f"performance_{args.env}.json"
    output_file.write_text(
        json.dumps(result, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )

    if not args.skip_plots:
        generate_plots(tests, args.env, output_dir)

    print(json.dumps(result, indent=2, ensure_ascii=False))

    failed_tests = [
        test for test in tests
        if test["summary"]["failed"] > 0
    ]

    if failed_tests:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
