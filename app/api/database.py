import os

from sqlalchemy import create_engine
from sqlalchemy.engine import URL
from sqlalchemy.orm import declarative_base, sessionmaker

Base = declarative_base()

DATABASE_URL = os.getenv("DATABASE_URL")

if not DATABASE_URL:
    pg_user = os.getenv("POSTGRES_USER", "events_user")
    pg_password = os.getenv("POSTGRES_PASSWORD", "events_pass")
    pg_host = os.getenv("POSTGRES_HOST", "db")
    pg_port = int(os.getenv("POSTGRES_PORT", "5432"))
    pg_db = os.getenv("POSTGRES_DB", "events")

    DATABASE_URL = URL.create(
        drivername="postgresql+psycopg",
        username=pg_user,
        password=pg_password,
        host=pg_host,
        port=pg_port,
        database=pg_db,
    )

engine = create_engine(DATABASE_URL, pool_pre_ping=True)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)