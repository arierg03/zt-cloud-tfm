import os
from urllib.parse import urlparse

import boto3
from botocore.client import Config
from botocore.exceptions import ClientError

S3_ENDPOINT = os.getenv("S3_ENDPOINT", "http://minio:9000")
S3_PUBLIC_ENDPOINT = os.getenv("S3_PUBLIC_ENDPOINT", S3_ENDPOINT)
S3_ACCESS_KEY = os.getenv("S3_ACCESS_KEY", "minioadmin")
S3_SECRET_KEY = os.getenv("S3_SECRET_KEY", "minioadmin")
S3_BUCKET = os.getenv("S3_BUCKET", "events-images")
S3_REGION = os.getenv("S3_REGION", "eu-south-2")
S3_USE_SSL = os.getenv("S3_USE_SSL", "false").lower() == "true"
S3_URL_TTL_SECONDS = int(os.getenv("S3_URL_TTL_SECONDS", "3600"))


def _is_path_style(endpoint: str) -> bool:
    host = urlparse(endpoint).hostname or ""
    return host in {"minio", "localhost", "127.0.0.1"}


def _build_s3_client(endpoint: str):
    return boto3.client(
        "s3",
        endpoint_url=endpoint,
        aws_access_key_id=S3_ACCESS_KEY,
        aws_secret_access_key=S3_SECRET_KEY,
        region_name=S3_REGION,
        use_ssl=S3_USE_SSL,
        config=Config(signature_version="s3v4", s3={"addressing_style": "path" if _is_path_style(endpoint) else "virtual"}),
    )


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
