import json
import logging
import os
import time
from datetime import UTC, datetime, timedelta
from threading import Lock
from uuid import UUID

from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.responses import RedirectResponse
from pydantic import BaseModel
from unipile.exceptions import ApiException

from bump_server.store import Store
from bump_server.unipile_client import InstagramClient, UnipileDataError

log = logging.getLogger(__name__)
app = FastAPI(title="Bump Demo", version="0.1.0", docs_url=None, redoc_url=None)
store = Store(os.environ.get("BUMP_DB_PATH", "/tmp/bump-demo.db"))
public_url = os.environ.get("BUMP_PUBLIC_URL", "").rstrip("/")
api_key = os.environ.get("UNIPILE_V2_API_KEY", "")
unipile_base = os.environ.get("BUMP_UNIPILE_BASE_URL", "https://api.unipile.com")
client = InstagramClient(api_key, base_url=unipile_base) if api_key else None
result_lock = Lock()


class ParticipantCreated(BaseModel):
    participant_id: str
    token: str


class MeetingJoin(BaseModel):
    peer_id: UUID


class CooldownError(RuntimeError):
    def __init__(self, retry_after: int) -> None:
        self.retry_after = retry_after


def current_participant(authorization: str = Header(default="")) -> str:
    if not authorization.startswith("Bearer "):
        raise HTTPException(401, "Missing device token")
    row = store.participant_for_token(authorization[7:])
    if row is None:
        raise HTTPException(401, "Invalid device token")
    return row["id"]


def ready_client() -> InstagramClient:
    if client is None or not public_url:
        raise HTTPException(503, "Instagram service is not configured")
    return client


def upstream_error(error: Exception) -> HTTPException:
    if isinstance(error, CooldownError):
        return HTTPException(
            429, "Instagram is rate limited; retry later", headers={"Retry-After": str(error.retry_after)}
        )
    if isinstance(error, ApiException) and error.status == 429:
        try:
            error_type = json.loads(error.body).get("type") if isinstance(error.body, str) else ""
        except ValueError:
            error_type = ""
        headers = {}
        if error_type == "api/too_many_requests":
            retry_after = (error.headers or {}).get("retry-after")
            if retry_after and str(retry_after).isdigit():
                headers["Retry-After"] = str(retry_after)
        return HTTPException(429, "Instagram is rate limited; retry later", headers=headers)
    log.warning("Unipile request failed: %s", type(error).__name__)
    return HTTPException(502, "Instagram provider request failed")


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok", "instagram": "configured" if client and public_url else "unconfigured"}


@app.post("/v1/participants", response_model=ParticipantCreated)
def create_participant() -> ParticipantCreated:
    participant_id, token = store.create_participant()
    return ParticipantCreated(participant_id=participant_id, token=token)


@app.get("/v1/me")
def me(participant_id: str = Depends(current_participant)) -> dict[str, str | bool]:
    row = store.participant(participant_id)
    assert row is not None
    return {"participant_id": participant_id, "instagram_connected": bool(row["instagram_account_id"])}


@app.post("/v1/instagram/link")
def link_instagram(participant_id: str = Depends(current_participant)) -> dict[str, str]:
    sdk = ready_client()
    expires = datetime.now(UTC) + timedelta(minutes=10)
    state = store.create_state(participant_id, int(expires.timestamp()))
    try:
        link = sdk.create_link(callback=f"{public_url}/v1/instagram/callback", state=state, expires_on=expires)
    except (ApiException, ValueError) as error:
        raise upstream_error(error) from error
    return {"url": link}


@app.get("/v1/instagram/callback")
def instagram_callback(
    state: str = "", account_id: str = "", provider: str = "", error_type: str = ""
) -> RedirectResponse:
    participant_id = store.consume_state(state) if state else None
    if not participant_id:
        raise HTTPException(400, "Invalid or expired link state")
    if error_type or provider != "instagram" or not account_id.startswith("acc_"):
        return RedirectResponse("bumpdemo://instagram-linked?ok=0", status_code=303)
    try:
        verified_id, owner_id = ready_client().verify_account(account_id)
        store.link_account(participant_id, verified_id, owner_id)
    except (ApiException, UnipileDataError, ValueError) as error:
        log.warning("Instagram callback rejected: %s", type(error).__name__)
        return RedirectResponse("bumpdemo://instagram-linked?ok=0", status_code=303)
    return RedirectResponse("bumpdemo://instagram-linked?ok=1", status_code=303)


def checked_meeting_id(meeting_id: str) -> str:
    try:
        parsed = UUID(meeting_id)
    except ValueError as error:
        raise HTTPException(422, "Invalid meeting ID") from error
    if str(parsed) != meeting_id:
        raise HTTPException(422, "Invalid meeting ID")
    return meeting_id


@app.post("/v1/meetings/{meeting_id}/join")
def join_meeting(
    meeting_id: str, body: MeetingJoin, participant_id: str = Depends(current_participant)
) -> dict[str, str | int | list[dict[str, str | None]]]:
    checked_meeting_id(meeting_id)
    if str(body.peer_id) == participant_id:
        raise HTTPException(422, "Cannot meet yourself")
    if store.participant(str(body.peer_id)) is None:
        raise HTTPException(404, "Other phone not registered")
    store.join(meeting_id, participant_id, str(body.peer_id))
    return meeting_result(meeting_id, participant_id)


@app.get("/v1/meetings/{meeting_id}")
def get_meeting(
    meeting_id: str, participant_id: str = Depends(current_participant)
) -> dict[str, str | int | list[dict[str, str | None]]]:
    checked_meeting_id(meeting_id)
    return meeting_result(meeting_id, participant_id)


def following(account_id: str, sdk: InstagramClient) -> tuple[list[dict[str, str | None]], int, bool]:
    cached = store.cached_following(account_id)
    if cached is not None:
        return cached[0], cached[1], False
    cooldown = store.cooldown_remaining(account_id)
    if cooldown:
        stale = store.cached_following(account_id, max_age=86400)
        if stale is not None:
            return stale[0], stale[1], True
        raise CooldownError(cooldown)
    try:
        users = sdk.following(account_id)
    except ApiException as error:
        stale = store.cached_following(account_id, max_age=86400)
        if error.status == 429:
            retry_header = next(
                (value for key, value in (error.headers or {}).items() if key.lower() == "retry-after"), None
            )
            retry_seconds = int(retry_header) if retry_header and str(retry_header).isdigit() else 300
            store.save_cooldown(account_id, max(60, retry_seconds))
        if stale is None or (error.status != 429 and error.status < 500):
            raise
        return stale[0], stale[1], True
    store.save_following(account_id, users)
    return users, int(time.time()), False


def meeting_result(meeting_id: str, participant_id: str) -> dict[str, str | int | bool | list[dict[str, str | None]]]:
    join = store.has_join(meeting_id, participant_id)
    if join is None or join["joined_at"] < time.time() - 600:
        raise HTTPException(404, "Meeting not found")
    peer_id = join["peer_id"]
    if not store.reciprocal_peer(meeting_id, participant_id, peer_id):
        return {"status": "waiting_for_other_phone"}
    own = store.participant(participant_id)
    peer = store.participant(peer_id)
    assert own is not None and peer is not None
    if not own["instagram_account_id"] or not peer["instagram_account_id"]:
        return {"status": "waiting_for_instagram"}
    with result_lock:
        saved = store.meeting_result(meeting_id)
        if saved is not None:
            return saved
        sdk = ready_client()
        try:
            sdk.verify_account(own["instagram_account_id"])
            sdk.verify_account(peer["instagram_account_id"])
            own_users, own_fetched_at, own_stale = following(own["instagram_account_id"], sdk)
            peer_users, peer_fetched_at, peer_stale = following(peer["instagram_account_id"], sdk)
        except (ApiException, CooldownError, UnipileDataError, ValueError) as error:
            raise upstream_error(error) from error
        peer_ids = {user["id"] for user in peer_users}
        common = sorted(
            (user for user in own_users if user["id"] in peer_ids),
            key=lambda user: ((user["name"] or "").casefold(), user["id"] or ""),
        )
        result = {
            "status": "ready",
            "count": len(common),
            "common": common,
            "as_of": min(own_fetched_at, peer_fetched_at),
            "stale": own_stale or peer_stale,
        }
        store.save_meeting_result(meeting_id, result)
        return result
