import hashlib
from io import BytesIO
from datetime import datetime, timezone
from uuid import uuid4

from fastapi import Depends, FastAPI, File, Form, HTTPException, UploadFile
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from fastapi.middleware.cors import CORSMiddleware
from botocore.exceptions import BotoCoreError, ClientError
from PIL import Image as PILImage, UnidentifiedImageError
from sqlalchemy import text
from sqlalchemy import or_
from sqlalchemy.orm import Session

from auth import create_access_token, decode_access_token, hash_password, verify_password
from database import SessionLocal
from models import Event, Image, User
from schemas import EventCreate, EventRead, ImageRead, LoginRequest, LoginResponse, RegisterRequest, UserPublic
from storage import S3_BUCKET, build_presigned_get_url, ensure_bucket_exists, get_s3_client


app = FastAPI(title="Events API", version="0.1.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:5173"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

security = HTTPBearer(auto_error=False)
ALLOWED_IMAGE_MIME_TYPES = {"image/jpeg", "image/png", "image/webp"}
MAX_IMAGE_BYTES = 5 * 1024 * 1024


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


def ensure_default_admin(db: Session) -> User:
    user = (
        db.query(User)
        .filter(or_(User.email == "admin@example.com", User.username == "admin"))
        .first()
    )
    if not user:
        user = User(
            username="admin",
            email="admin@example.com",
            password_hash=hash_password("admin123"),
            role="admin",
            is_active=True,
        )
        db.add(user)
        db.commit()
        db.refresh(user)
        return user

    if user.password_hash == "demo-hash":
        user.password_hash = hash_password("admin123")
        db.commit()
        db.refresh(user)

    return user


def get_current_user(
    credentials: HTTPAuthorizationCredentials | None = Depends(security),
    db: Session = Depends(get_db),
) -> User:
    if not credentials:
        raise HTTPException(status_code=401, detail="Missing bearer token")

    payload = decode_access_token(credentials.credentials)
    if not payload:
        raise HTTPException(status_code=401, detail="Invalid or expired token")

    try:
        user_id = int(payload.get("sub", ""))
    except ValueError as exc:
        raise HTTPException(status_code=401, detail="Invalid token payload") from exc

    user = db.get(User, user_id)
    if not user or not user.is_active:
        raise HTTPException(status_code=401, detail="User not found or inactive")

    return user


def can_manage_event(user: User, event: Event) -> bool:
    return user.role == "admin" or event.created_by == user.id


def is_event_creator(user: User, event: Event) -> bool:
    return event.created_by == user.id


def latest_event_image(db: Session, event_id: int) -> Image | None:
    return (
        db.query(Image)
        .filter(Image.event_id == event_id)
        .order_by(Image.created_at.desc(), Image.id.desc())
        .first()
    )


def serialize_image(image: Image) -> ImageRead:
    image_url = build_presigned_get_url(image.storage_path)
    return ImageRead(
        id=image.id,
        event_id=image.event_id,
        filename=image.filename,
        mime_type=image.mime_type,
        caption=image.caption,
        created_at=image.created_at,
        image_url=image_url,
    )


def delete_image_from_storage(storage_path: str) -> None:
    try:
        get_s3_client().delete_object(Bucket=S3_BUCKET, Key=storage_path)
    except (ClientError, BotoCoreError):
        # Prefer DB consistency over failing deletes of stale remote objects.
        pass


def extract_dimensions(content: bytes) -> tuple[int | None, int | None]:
    try:
        with PILImage.open(BytesIO(content)) as image:
            return image.width, image.height
    except (UnidentifiedImageError, OSError):
        return None, None


@app.on_event("startup")
def ensure_storage_bucket():
    try:
        ensure_bucket_exists()
    except Exception as exc:
        print(f"[startup] warning: could not ensure bucket {S3_BUCKET}: {exc}")


@app.get("/health")
def health(db: Session = Depends(get_db)):
    try:
        db.execute(text("SELECT 1"))
        return {"status": "ok"}
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"db error: {exc}") from exc


@app.post("/auth/login", response_model=LoginResponse)
def login(payload: LoginRequest, db: Session = Depends(get_db)):
    ensure_default_admin(db)

    identifier = payload.identifier.strip().lower()
    user = (
        db.query(User)
        .filter(
            or_(
                User.email == identifier,
                User.username == identifier,
            )
        )
        .first()
    )

    if not user or not verify_password(payload.password, user.password_hash):
        raise HTTPException(status_code=401, detail="Credenciales invalidas")

    if not user.is_active:
        raise HTTPException(status_code=403, detail="Usuario inactivo")

    if not user.password_hash.startswith("pbkdf2_sha256$"):
        user.password_hash = hash_password(payload.password)

    user.last_login_at = datetime.now(timezone.utc)
    db.commit()
    db.refresh(user)

    token, expires_at = create_access_token(user_id=user.id, username=user.username, role=user.role)
    return LoginResponse(
        access_token=token,
        expires_at=expires_at,
        user=UserPublic(id=user.id, username=user.username, email=user.email, role=user.role),
    )


@app.post("/auth/register", response_model=LoginResponse, status_code=201)
def register(payload: RegisterRequest, db: Session = Depends(get_db)):
    username = payload.username.strip().lower()
    email = payload.email.strip().lower()

    if len(username) < 3:
        raise HTTPException(status_code=400, detail="El username debe tener al menos 3 caracteres")
    if len(payload.password) < 6:
        raise HTTPException(status_code=400, detail="La contrasena debe tener al menos 6 caracteres")

    existing_user = (
        db.query(User)
        .filter(
            or_(
                User.email == email,
                User.username == username,
            )
        )
        .first()
    )
    if existing_user:
        raise HTTPException(status_code=409, detail="El email o username ya existe")

    user = User(
        username=username,
        email=email,
        password_hash=hash_password(payload.password),
        role="viewer",
        is_active=True,
        last_login_at=datetime.now(timezone.utc),
    )
    db.add(user)
    db.commit()
    db.refresh(user)

    token, expires_at = create_access_token(user_id=user.id, username=user.username, role=user.role)
    return LoginResponse(
        access_token=token,
        expires_at=expires_at,
        user=UserPublic(id=user.id, username=user.username, email=user.email, role=user.role),
    )


@app.get("/events", response_model=list[EventRead])
def list_events(
    db: Session = Depends(get_db),
    _: User = Depends(get_current_user),
):
    return db.query(Event).order_by(Event.created_at.desc()).all()


@app.get("/events/{event_id}", response_model=EventRead)
def get_event(
    event_id: int,
    db: Session = Depends(get_db),
    _: User = Depends(get_current_user),
):
    event = db.get(Event, event_id)
    if not event:
        raise HTTPException(status_code=404, detail="Evento no encontrado")
    return event


@app.put("/events/{event_id}", response_model=EventRead)
def update_event(
    event_id: int,
    payload: EventCreate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    event = db.get(Event, event_id)
    if not event:
        raise HTTPException(status_code=404, detail="Evento no encontrado")
    if not can_manage_event(current_user, event):
        raise HTTPException(status_code=403, detail="No tienes permisos para editar este evento")

    event.title = payload.title
    event.manual_description = payload.manual_description
    event.event_date = payload.event_date
    event.country = payload.country
    event.language = payload.language
    event.updated_at = datetime.now(timezone.utc)
    db.commit()
    db.refresh(event)
    return event


@app.delete("/events/{event_id}")
def delete_event(
    event_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    event = db.get(Event, event_id)
    if not event:
        raise HTTPException(status_code=404, detail="Evento no encontrado")
    if not can_manage_event(current_user, event):
        raise HTTPException(status_code=403, detail="No tienes permisos para eliminar este evento")

    db.delete(event)
    db.commit()
    return {"message": "deleted"}


@app.post("/events", status_code=201)
def create_event(
    payload: EventCreate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    event = Event(
        title=payload.title,
        manual_description=payload.manual_description,
        event_date=payload.event_date,
        country=payload.country,
        language=payload.language,
        created_by=current_user.id,
    )
    db.add(event)
    db.commit()
    db.refresh(event)

    return {"id": event.id, "message": "created"}


@app.get("/events/{event_id}/image", response_model=ImageRead)
def get_event_image(
    event_id: int,
    db: Session = Depends(get_db),
    _: User = Depends(get_current_user),
):
    event = db.get(Event, event_id)
    if not event:
        raise HTTPException(status_code=404, detail="Evento no encontrado")

    image = latest_event_image(db, event_id)
    if not image:
        raise HTTPException(status_code=404, detail="Imagen no encontrada")

    try:
        return serialize_image(image)
    except (ClientError, BotoCoreError) as exc:
        raise HTTPException(status_code=503, detail=f"Error generando URL de imagen: {exc}") from exc


@app.get("/events/{event_id}/images", response_model=list[ImageRead])
def list_event_images(
    event_id: int,
    db: Session = Depends(get_db),
    _: User = Depends(get_current_user),
):
    event = db.get(Event, event_id)
    if not event:
        raise HTTPException(status_code=404, detail="Evento no encontrado")

    images = (
        db.query(Image)
        .filter(Image.event_id == event_id)
        .order_by(Image.created_at.desc(), Image.id.desc())
        .all()
    )
    try:
        return [serialize_image(image) for image in images]
    except (ClientError, BotoCoreError) as exc:
        raise HTTPException(status_code=503, detail=f"Error generando URL de imagen: {exc}") from exc


@app.post("/events/{event_id}/image", response_model=ImageRead, status_code=201)
async def upload_event_image(
    event_id: int,
    file: UploadFile = File(...),
    caption: str | None = Form(default=None),
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    event = db.get(Event, event_id)
    if not event:
        raise HTTPException(status_code=404, detail="Evento no encontrado")
    if not is_event_creator(current_user, event):
        raise HTTPException(status_code=403, detail="Solo el creador del evento puede subir imagen")

    mime_type = (file.content_type or "").lower()
    if mime_type not in ALLOWED_IMAGE_MIME_TYPES:
        raise HTTPException(status_code=400, detail="Formato de imagen no permitido (usa JPG, PNG o WEBP)")

    content = await file.read()
    if not content:
        raise HTTPException(status_code=400, detail="Imagen vacia")
    if len(content) > MAX_IMAGE_BYTES:
        raise HTTPException(status_code=400, detail="La imagen supera 5 MB")

    extension_by_mime = {
        "image/jpeg": "jpg",
        "image/png": "png",
        "image/webp": "webp",
    }
    extension = extension_by_mime[mime_type]
    storage_path = f"events/{event_id}/{uuid4().hex}.{extension}"
    file_hash = hashlib.sha256(content).hexdigest()
    width, height = extract_dimensions(content)
    normalized_caption = (caption or "").strip() or None

    try:
        client = get_s3_client()
        client.put_object(
            Bucket=S3_BUCKET,
            Key=storage_path,
            Body=content,
            ContentType=mime_type,
        )
    except (ClientError, BotoCoreError) as exc:
        raise HTTPException(status_code=503, detail=f"Error subiendo imagen a almacenamiento: {exc}") from exc

    image = Image(
        event_id=event_id,
        uploaded_by=current_user.id,
        storage_path=storage_path,
        filename=file.filename or f"event-{event_id}.{extension}",
        mime_type=mime_type,
        caption=normalized_caption,
        width=width,
        height=height,
        hash=file_hash,
    )
    db.add(image)
    db.commit()
    db.refresh(image)

    try:
        return serialize_image(image)
    except (ClientError, BotoCoreError) as exc:
        raise HTTPException(status_code=503, detail=f"Error generando URL de imagen: {exc}") from exc
