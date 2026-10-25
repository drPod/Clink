import hashlib
import json
import secrets
import sqlite3
import time
from pathlib import Path
from uuid import uuid4


class Store:
    def __init__(self, path: str) -> None:
        self.path = path
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        with self.connect() as db:
            db.executescript(
                """
                CREATE TABLE IF NOT EXISTS participants (
                    id TEXT PRIMARY KEY, token_hash TEXT UNIQUE NOT NULL,
                    instagram_account_id TEXT, instagram_user_id TEXT
                );
                CREATE TABLE IF NOT EXISTS link_states (
                    state_hash TEXT PRIMARY KEY, participant_id TEXT NOT NULL,
                    expires_at INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS meeting_joins (
                    meeting_id TEXT NOT NULL, participant_id TEXT NOT NULL,
                    peer_id TEXT NOT NULL, joined_at INTEGER NOT NULL,
                    PRIMARY KEY (meeting_id, participant_id)
                );
                CREATE TABLE IF NOT EXISTS following_cache (
                    account_id TEXT PRIMARY KEY, fetched_at INTEGER NOT NULL, users_json TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS meeting_results (
                    meeting_id TEXT PRIMARY KEY, created_at INTEGER NOT NULL, result_json TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS account_cooldowns (
                    account_id TEXT PRIMARY KEY, until_at INTEGER NOT NULL
                );
                """
            )

    def connect(self) -> sqlite3.Connection:
        db = sqlite3.connect(self.path, timeout=10)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA journal_mode=WAL")
        return db

    @staticmethod
    def digest(value: str) -> str:
        return hashlib.sha256(value.encode()).hexdigest()

    def create_participant(self) -> tuple[str, str]:
        participant_id = str(uuid4())
        token = secrets.token_urlsafe(32)
        with self.connect() as db:
            db.execute("INSERT INTO participants (id, token_hash) VALUES (?, ?)", (participant_id, self.digest(token)))
        return participant_id, token

    def participant_for_token(self, token: str) -> sqlite3.Row | None:
        with self.connect() as db:
            return db.execute("SELECT * FROM participants WHERE token_hash = ?", (self.digest(token),)).fetchone()

    def participant(self, participant_id: str) -> sqlite3.Row | None:
        with self.connect() as db:
            return db.execute("SELECT * FROM participants WHERE id = ?", (participant_id,)).fetchone()

    def create_state(self, participant_id: str, expires_at: int) -> str:
        state = secrets.token_urlsafe(32)
        with self.connect() as db:
            db.execute(
                "INSERT INTO link_states (state_hash, participant_id, expires_at) VALUES (?, ?, ?)",
                (self.digest(state), participant_id, expires_at),
            )
        return state

    def consume_state(self, state: str) -> str | None:
        with self.connect() as db:
            row = db.execute("SELECT * FROM link_states WHERE state_hash = ?", (self.digest(state),)).fetchone()
            db.execute("DELETE FROM link_states WHERE state_hash = ?", (self.digest(state),))
        return row["participant_id"] if row and row["expires_at"] >= time.time() else None

    def link_account(self, participant_id: str, account_id: str, instagram_user_id: str) -> None:
        with self.connect() as db:
            existing = db.execute(
                "SELECT id FROM participants WHERE instagram_account_id = ? AND id != ?", (account_id, participant_id)
            ).fetchone()
            if existing:
                raise ValueError("Instagram account is already linked to another phone")
            db.execute(
                "UPDATE participants SET instagram_account_id = ?, instagram_user_id = ? WHERE id = ?",
                (account_id, instagram_user_id, participant_id),
            )

    def join(self, meeting_id: str, participant_id: str, peer_id: str) -> None:
        with self.connect() as db:
            db.execute(
                "INSERT OR REPLACE INTO meeting_joins (meeting_id, participant_id, peer_id, joined_at) VALUES (?, ?, ?, ?)",
                (meeting_id, participant_id, peer_id, int(time.time())),
            )

    def reciprocal_peer(self, meeting_id: str, participant_id: str, peer_id: str) -> bool:
        with self.connect() as db:
            row = db.execute(
                """SELECT 1 FROM meeting_joins WHERE meeting_id = ? AND participant_id = ?
                AND peer_id = ? AND joined_at >= ?""",
                (meeting_id, peer_id, participant_id, int(time.time()) - 600),
            ).fetchone()
            return row is not None

    def has_join(self, meeting_id: str, participant_id: str) -> sqlite3.Row | None:
        with self.connect() as db:
            return db.execute(
                "SELECT * FROM meeting_joins WHERE meeting_id = ? AND participant_id = ?",
                (meeting_id, participant_id),
            ).fetchone()

    def cached_following(self, account_id: str, max_age: int = 3600) -> tuple[list[dict[str, str | None]], int] | None:
        with self.connect() as db:
            row = db.execute("SELECT * FROM following_cache WHERE account_id = ?", (account_id,)).fetchone()
        if not row or row["fetched_at"] < time.time() - max_age:
            return None
        return json.loads(row["users_json"]), row["fetched_at"]

    def save_following(self, account_id: str, users: list[dict[str, str | None]]) -> None:
        with self.connect() as db:
            db.execute(
                "INSERT OR REPLACE INTO following_cache (account_id, fetched_at, users_json) VALUES (?, ?, ?)",
                (account_id, int(time.time()), json.dumps(users)),
            )

    def meeting_result(self, meeting_id: str) -> dict | None:
        with self.connect() as db:
            row = db.execute("SELECT result_json FROM meeting_results WHERE meeting_id = ?", (meeting_id,)).fetchone()
        return json.loads(row["result_json"]) if row else None

    def save_meeting_result(self, meeting_id: str, result: dict) -> None:
        with self.connect() as db:
            db.execute(
                "INSERT OR IGNORE INTO meeting_results (meeting_id, created_at, result_json) VALUES (?, ?, ?)",
                (meeting_id, int(time.time()), json.dumps(result)),
            )

    def cooldown_remaining(self, account_id: str) -> int:
        with self.connect() as db:
            row = db.execute("SELECT until_at FROM account_cooldowns WHERE account_id = ?", (account_id,)).fetchone()
        return max(0, row["until_at"] - int(time.time())) if row else 0

    def save_cooldown(self, account_id: str, seconds: int) -> None:
        with self.connect() as db:
            db.execute(
                "INSERT OR REPLACE INTO account_cooldowns (account_id, until_at) VALUES (?, ?)",
                (account_id, int(time.time()) + seconds),
            )
