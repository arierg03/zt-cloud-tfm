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
    event_date: datetime | None
    country: str | None
    language: str | None
    status: str
    created_at: datetime

    class Config:
        from_attributes = True
