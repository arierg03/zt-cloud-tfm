from datetime import datetime

from pydantic import BaseModel


class UserPublic(BaseModel):
    id: int
    username: str
    email: str
    role: str


class LoginRequest(BaseModel):
    identifier: str
    password: str


class RegisterRequest(BaseModel):
    username: str
    email: str
    password: str


class LoginResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    expires_at: datetime
    user: UserPublic


class EventCreate(BaseModel):
    title: str
    manual_description: str | None = None
    event_date: datetime | None = None
    country: str | None = None
    language: str | None = "es"


class EventRead(BaseModel):
    id: int
    title: str
    manual_description: str | None
    generated_description: str | None
    event_date: datetime | None
    country: str | None
    language: str | None
    status: str
    last_batch_execution_id: int | None
    processed_at: datetime | None
    created_by: int
    created_at: datetime

    class Config:
        from_attributes = True


class ImageRead(BaseModel):
    id: int
    event_id: int
    filename: str
    mime_type: str
    caption: str | None
    created_at: datetime
    image_url: str

    class Config:
        from_attributes = True


class BatchExecutionRead(BaseModel):
    id: int
    started_at: datetime
    finished_at: datetime | None
    status: str
    total_events_detected: int
    total_events_processed: int
    total_events_failed: int
    log_summary: str | None
    error_message: str | None
    created_at: datetime

    class Config:
        from_attributes = True
