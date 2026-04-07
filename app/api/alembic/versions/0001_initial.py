"""initial schema

Revision ID: 0001_initial
Revises:
Create Date: 2026-03-30 12:00:00
"""

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "0001_initial"
down_revision: Union[str, Sequence[str], None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "users",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("username", sa.String(length=100), nullable=False),
        sa.Column("email", sa.String(length=150), nullable=False),
        sa.Column("password_hash", sa.String(length=255), nullable=False),
        sa.Column("role", sa.String(length=50), nullable=False, server_default="viewer"),
        sa.Column("is_active", sa.Boolean(), nullable=False, server_default=sa.text("true")),
        sa.Column("last_login_at", sa.DateTime(), nullable=True),
        sa.Column("created_at", sa.DateTime(), nullable=False, server_default=sa.text("NOW()")),
        sa.Column("updated_at", sa.DateTime(), nullable=False, server_default=sa.text("NOW()")),
        sa.UniqueConstraint("username"),
        sa.UniqueConstraint("email"),
    )

    op.create_table(
        "batch_executions",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("started_at", sa.DateTime(), nullable=False),
        sa.Column("finished_at", sa.DateTime(), nullable=True),
        sa.Column("status", sa.String(length=50), nullable=False),
        sa.Column("total_events_detected", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("total_events_processed", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("total_events_failed", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("log_summary", sa.Text(), nullable=True),
        sa.Column("error_message", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(), nullable=False, server_default=sa.text("NOW()")),
    )

    op.create_table(
        "events",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("title", sa.String(length=255), nullable=False),
        sa.Column("manual_description", sa.Text(), nullable=True),
        sa.Column("generated_description", sa.Text(), nullable=True),
        sa.Column("source_url", sa.String(length=500), nullable=True),
        sa.Column("source_name", sa.String(length=150), nullable=True),
        sa.Column("event_date", sa.DateTime(), nullable=True),
        sa.Column("country", sa.String(length=100), nullable=True),
        sa.Column("language", sa.String(length=50), nullable=True),
        sa.Column("status", sa.String(length=50), nullable=False, server_default="pending"),
        sa.Column("created_by", sa.Integer(), nullable=False),
        sa.Column("last_batch_execution_id", sa.Integer(), nullable=True),
        sa.Column("processed_at", sa.DateTime(), nullable=True),
        sa.Column("created_at", sa.DateTime(), nullable=False, server_default=sa.text("NOW()")),
        sa.Column("updated_at", sa.DateTime(), nullable=False, server_default=sa.text("NOW()")),
        sa.ForeignKeyConstraint(
            ["created_by"], ["users.id"], deferrable=True, initially="IMMEDIATE"
        ),
        sa.ForeignKeyConstraint(
            ["last_batch_execution_id"], ["batch_executions.id"], deferrable=True, initially="IMMEDIATE"
        ),
    )

    op.create_table(
        "images",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("event_id", sa.Integer(), nullable=False),
        sa.Column("uploaded_by", sa.Integer(), nullable=True),
        sa.Column("storage_path", sa.String(length=500), nullable=False),
        sa.Column("filename", sa.String(length=255), nullable=False),
        sa.Column("mime_type", sa.String(length=100), nullable=False),
        sa.Column("caption", sa.String(length=255), nullable=True),
        sa.Column("width", sa.Integer(), nullable=True),
        sa.Column("height", sa.Integer(), nullable=True),
        sa.Column("hash", sa.String(length=255), nullable=True),
        sa.Column("created_at", sa.DateTime(), nullable=False, server_default=sa.text("NOW()")),
        sa.ForeignKeyConstraint(
            ["event_id"], ["events.id"], deferrable=True, initially="IMMEDIATE"
        ),
        sa.ForeignKeyConstraint(
            ["uploaded_by"], ["users.id"], deferrable=True, initially="IMMEDIATE"
        ),
    )


def downgrade() -> None:
    op.drop_table("images")
    op.drop_table("events")
    op.drop_table("batch_executions")
    op.drop_table("users")
