import os
from urllib.parse import urlparse

import boto3
from botocore.client import Config
from botocore.exceptions import ClientError

def _optional_env(name: str) -> str | None:
    value = os.getenv(name)
    if value is None:
        return None
    value = value.strip()
    return value or None


S3_ENDPOINT = _optional_env("S3_ENDPOINT")
S3_PUBLIC_ENDPOINT = _optional_env("S3_PUBLIC_ENDPOINT") or S3_ENDPOINT
S3_ACCESS_KEY = _optional_env("S3_ACCESS_KEY")
S3_SECRET_KEY = _optional_env("S3_SECRET_KEY")
S3_BUCKET = os.getenv("S3_BUCKET", "events-images")
S3_REGION = os.getenv("S3_REGION", "eu-south-2")
S3_USE_SSL = os.getenv("S3_USE_SSL", "false").lower() == "true"
S3_URL_TTL_SECONDS = int(os.getenv("S3_URL_TTL_SECONDS", "3600"))


def _is_path_style(endpoint: str) -> bool:
    host = urlparse(endpoint).hostname or ""
    return host in {"minio", "localhost", "127.0.0.1"}


def _build_s3_client(endpoint: str | None = None):
    client_kwargs = {
        "service_name": "s3",
        "region_name": S3_REGION,
        "use_ssl": S3_USE_SSL,
        "config": Config(
            signature_version="s3v4",
            s3={"addressing_style": "path" if endpoint and _is_path_style(endpoint) else "virtual"},
        ),
    }

    if endpoint:
        client_kwargs["endpoint_url"] = endpoint

    if S3_ACCESS_KEY and S3_SECRET_KEY:
        client_kwargs["aws_access_key_id"] = S3_ACCESS_KEY
        client_kwargs["aws_secret_access_key"] = S3_SECRET_KEY

    return boto3.client(**client_kwargs)


def get_s3_client():
    return _build_s3_client(S3_ENDPOINT)


def get_s3_public_client():
    return _build_s3_client(S3_PUBLIC_ENDPOINT)


def ensure_bucket_exists() -> None:
    client = get_s3_client()
    try:
        client.head_bucket(Bucket=S3_BUCKET)
    except ClientError as exc:
        code = str(exc.response.get("Error", {}).get("Code", ""))
        if code in {"404", "NoSuchBucket", "NotFound"}:
            client.create_bucket(Bucket=S3_BUCKET)
            return
        raise


def build_presigned_get_url(storage_path: str) -> str:
    client = get_s3_public_client()
    return client.generate_presigned_url(
        "get_object",
        Params={"Bucket": S3_BUCKET, "Key": storage_path},
        ExpiresIn=S3_URL_TTL_SECONDS,
    )
