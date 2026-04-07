import base64
import binascii
import hashlib
import hmac
import json
import os
from datetime import datetime, timedelta, timezone


PASSWORD_SCHEME = "pbkdf2_sha256"
PASSWORD_ITERATIONS = 120_000
TOKEN_TTL_HOURS = 12
TOKEN_SECRET = os.getenv("API_SECRET_KEY", "change-me-dev-secret")


def _b64url_encode(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("utf-8")


def _b64url_decode(raw: str) -> bytes:
    padding = "=" * (-len(raw) % 4)
    return base64.urlsafe_b64decode(raw + padding)


def hash_password(password: str) -> str:
    salt = os.urandom(16)
    digest = hashlib.pbkdf2_hmac(
        "sha256",
        password.encode("utf-8"),
        salt,
        PASSWORD_ITERATIONS,
    )
    return f"{PASSWORD_SCHEME}${PASSWORD_ITERATIONS}${salt.hex()}${digest.hex()}"


def _verify_pbkdf2(password: str, stored_hash: str) -> bool:
    try:
        scheme, iterations, salt_hex, digest_hex = stored_hash.split("$", 3)
        if scheme != PASSWORD_SCHEME:
            return False
        expected = hashlib.pbkdf2_hmac(
            "sha256",
            password.encode("utf-8"),
            bytes.fromhex(salt_hex),
            int(iterations),
        )
        return hmac.compare_digest(expected.hex(), digest_hex)
    except ValueError:
        return False


def verify_password(password: str, stored_hash: str) -> bool:
    if stored_hash.startswith(f"{PASSWORD_SCHEME}$"):
        return _verify_pbkdf2(password, stored_hash)

    # Compatibilidad con semilla antigua local.
    if stored_hash == "demo-hash" and password == "admin123":
        return True

    return hmac.compare_digest(stored_hash, password)


def create_access_token(user_id: int, username: str, role: str) -> tuple[str, datetime]:
    expires_at = datetime.now(timezone.utc) + timedelta(hours=TOKEN_TTL_HOURS)
    payload = {
        "sub": str(user_id),
        "username": username,
        "role": role,
        "exp": int(expires_at.timestamp()),
    }
    payload_raw = _b64url_encode(json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8"))
    signature = hmac.new(TOKEN_SECRET.encode("utf-8"), payload_raw.encode("utf-8"), hashlib.sha256).digest()
    token = f"{payload_raw}.{_b64url_encode(signature)}"
    return token, expires_at


def decode_access_token(token: str) -> dict | None:
    try:
        payload_raw, signature_raw = token.split(".", 1)
    except (ValueError, binascii.Error):
        return None

    expected_sig = hmac.new(TOKEN_SECRET.encode("utf-8"), payload_raw.encode("utf-8"), hashlib.sha256).digest()
    try:
        given_sig = _b64url_decode(signature_raw)
    except ValueError:
        return None
    if not hmac.compare_digest(expected_sig, given_sig):
        return None

    try:
        payload = json.loads(_b64url_decode(payload_raw).decode("utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError, ValueError):
        return None

    exp = payload.get("exp")
    if not isinstance(exp, int) or exp < int(datetime.now(timezone.utc).timestamp()):
        return None

    return payload
