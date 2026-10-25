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
from bump_server.unipile_client import NETWORKS as UNIPILE_NETWORKS
from bump_server.unipile_client import UnipileClient, UnipileDataError
from bump_server.x_client import XClient, XError, pkce_pair

log = logging.getLogger(__name__)
app = FastAPI(title="Bump Demo", version="0.2.0", docs_url=None, redoc_url=None)
store = Store(os.environ.get("BUMP_DB_PATH", "/tmp/bump-demo.db"))
public_url = os.environ.get("BUMP_PUBLIC_URL", "").rstrip("/")
api_key = os.environ.get("UNIPILE_V2_API_KEY", "")
unipile_base = os.environ.get("BUMP_UNIPILE_BASE_URL", "https://api.unipile.com")
unipile = UnipileClient(api_key, base_url=unipile_base) if api_key else None
x_client_id = os.environ.get("X_CLIENT_ID", "")
x_graph_key = os.environ.get("TWITTERAPI_IO_KEY", "")
x = XClient(x_client_id, os.environ.get("X_CLIENT_SECRET", ""), x_graph_key) if x_client_id and x_graph_key else None
NETWORKS = (*UNIPILE_NETWORKS, "x")
LABELS = {"instagram": "Instagram", "linkedin": "LinkedIn", "x": "X"}
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


def available_networks() -> list[str]:
    if not public_url:
        return []
    return [network for network in NETWORKS if (x if network == "x" else unipile) is not None]


def checked_network(network: str) -> str:
    if network not in NETWORKS:
        raise HTTPException(404, "Unknown network")
    if network not in available_networks():
        raise HTTPException(503, f"{LABELS[network]} is not configured on the server")
    return network


def retry_after_header(headers) -> str | None:
    value = next((value for key, value in (headers or {}).items() if key.lower() == "retry-after"), None)
    return str(value) if value and str(value).isdigit() else None


def upstream_error(network: str, error: Exception) -> HTTPException:
    label = LABELS[network]
    if isinstance(error, CooldownError):
        return HTTPException(
            429, f"{label} is rate limited; retry later", headers={"Retry-After": str(error.retry_after)}
        )
    if isinstance(error, XError) and error.status == 429:
        headers = {"Retry-After": error.retry_after} if error.retry_after and error.retry_after.isdigit() else {}
        return HTTPException(429, f"{label} is rate limited; retry later", headers=headers)
    if isinstance(error, ApiException) and error.status == 429:
        try:
            error_type = json.loads(error.body).get("type") if isinstance(error.body, str) else ""
        except ValueError:
            error_type = ""
        retry_after = retry_after_header(error.headers) if error_type == "api/too_many_requests" else None
        return HTTPException(
            429, f"{label} is rate limited; retry later", headers={"Retry-After": retry_after} if retry_after else {}
        )
    log.warning("%s provider request failed: %s", network, type(error).__name__)
    return HTTPException(502, f"{label} provider request failed")


@app.get("/health")
def health() -> dict[str, str | list[str]]:
    networks = available_networks()
    return {
        "status": "ok",
        "instagram": "configured" if "instagram" in networks else "unconfigured",
        "networks": networks,
    }


@app.post("/v1/participants", response_model=ParticipantCreated)
def create_participant() -> ParticipantCreated:
    participant_id, token = store.create_participant()
    return ParticipantCreated(participant_id=participant_id, token=token)


@app.get("/v1/me")
def me(participant_id: str = Depends(current_participant)) -> dict:
    linked = store.linked_accounts(participant_id)
    return {
        "participant_id": participant_id,
        "available": available_networks(),
        "connected": {network: row["username"] for network, row in linked.items()},
    }


@app.post("/v1/{network}/link")
def link(network: str, participant_id: str = Depends(current_participant)) -> dict[str, str]:
    checked_network(network)
    expires = datetime.now(UTC) + timedelta(minutes=10)
    callback = f"{public_url}/v1/{network}/callback"
    if network == "x":
        verifier, challenge = pkce_pair()
        state = store.create_state(participant_id, network, int(expires.timestamp()), verifier)
        return {"url": x.authorize_url(callback=callback, state=state, challenge=challenge)}
    state = store.create_state(participant_id, network, int(expires.timestamp()))
    try:
        url = unipile.create_link(network, callback=callback, state=state, expires_on=expires)
    except (ApiException, ValueError) as error:
        raise upstream_error(network, error) from error
    return {"url": url}


def finish_link(network: str, ok: bool) -> RedirectResponse:
    return RedirectResponse(f"bumpdemo://linked?network={network}&ok={int(ok)}", status_code=303)


@app.get("/v1/{network}/callback")
def callback(
    network: str,
    state: str = "",
    account_id: str = "",
    provider: str = "",
    error_type: str = "",
    code: str = "",
    error: str = "",
) -> RedirectResponse:
    checked_network(network)
    pending = store.consume_state(state, network) if state else None
    if pending is None:
        raise HTTPException(400, "Invalid or expired link state")
    participant_id = pending["participant_id"]
    try:
        if network == "x":
            if error or not code:
                return finish_link(network, False)
            user_id, username = x.identify(
                code=code, verifier=pending["verifier"], callback=f"{public_url}/v1/x/callback"
            )
            store.link_account(participant_id, network, user_id, user_id, username)
        else:
            if error_type or provider != network or not account_id.startswith("acc_"):
                return finish_link(network, False)
            verified_id, owner_id = unipile.verify_account(network, account_id)
            store.link_account(participant_id, network, verified_id, owner_id)
    except (ApiException, UnipileDataError, XError, ValueError) as failure:
        log.warning("%s callback rejected: %s", network, type(failure).__name__)
        return finish_link(network, False)
    return finish_link(network, True)


def checked_meeting_id(meeting_id: str) -> str:
    try:
        parsed = UUID(meeting_id)
    except ValueError as error:
        raise HTTPException(422, "Invalid meeting ID") from error
    if str(parsed) != meeting_id:
        raise HTTPException(422, "Invalid meeting ID")
    return meeting_id


@app.post("/v1/meetings/{meeting_id}/join")
def join_meeting(meeting_id: str, body: MeetingJoin, participant_id: str = Depends(current_participant)) -> dict:
    checked_meeting_id(meeting_id)
    if str(body.peer_id) == participant_id:
        raise HTTPException(422, "Cannot meet yourself")
    if store.participant(str(body.peer_id)) is None:
        raise HTTPException(404, "Other phone not registered")
    store.join(meeting_id, participant_id, str(body.peer_id))
    return meeting_result(meeting_id, participant_id)


@app.get("/v1/meetings/{meeting_id}")
def get_meeting(meeting_id: str, participant_id: str = Depends(current_participant)) -> dict:
    checked_meeting_id(meeting_id)
    return meeting_result(meeting_id, participant_id)


def fetch_people(network: str, account: dict) -> list[dict[str, str | None]]:
    if network == "x":
        return x.following(account["username"])
    unipile.verify_account(network, account["account_id"])
    return unipile.people(network, account["account_id"])


def people(network: str, account: dict) -> tuple[list[dict[str, str | None]], int, bool]:
    cache_key = f"{network}:{account['account_id']}"
    cached = store.cached_following(cache_key)
    if cached is not None:
        return cached[0], cached[1], False
    cooldown = store.cooldown_remaining(cache_key)
    if cooldown:
        stale = store.cached_following(cache_key, max_age=86400)
        if stale is not None:
            return stale[0], stale[1], True
        raise CooldownError(cooldown)
    try:
        users = fetch_people(network, account)
    except (ApiException, XError) as error:
        stale = store.cached_following(cache_key, max_age=86400)
        if error.status == 429:
            retry_after = retry_after_header(error.headers) if isinstance(error, ApiException) else error.retry_after
            store.save_cooldown(cache_key, max(60, int(retry_after) if retry_after and retry_after.isdigit() else 300))
        if stale is None or (error.status != 429 and error.status < 500):
            raise
        return stale[0], stale[1], True
    store.save_following(cache_key, users)
    return users, int(time.time()), False


def overlap(own_users: list[dict], peer_users: list[dict]) -> list[dict]:
    peer_ids = {user["id"] for user in peer_users}
    peer_names = {user["username"].casefold() for user in peer_users if user.get("username")}
    common = (
        user
        for user in own_users
        if user["id"] in peer_ids or (user.get("username") and user["username"].casefold() in peer_names)
    )
    return sorted(common, key=lambda user: ((user["name"] or "").casefold(), user["id"] or ""))


def network_result(network: str, own: dict, peer: dict) -> dict:
    try:
        own_users, own_fetched_at, own_stale = people(network, own)
        peer_users, peer_fetched_at, peer_stale = people(network, peer)
    except (ApiException, CooldownError, UnipileDataError, XError, ValueError) as error:
        failure = upstream_error(network, error)
        return {"error": failure.detail, "retry_after": (failure.headers or {}).get("Retry-After")}
    common = overlap(own_users, peer_users)
    return {
        "count": len(common),
        "common": common,
        "as_of": min(own_fetched_at, peer_fetched_at),
        "stale": own_stale or peer_stale,
    }


def meeting_result(meeting_id: str, participant_id: str) -> dict:
    join = store.has_join(meeting_id, participant_id)
    if join is None or join["joined_at"] < time.time() - 600:
        raise HTTPException(404, "Meeting not found")
    peer_id = join["peer_id"]
    if not store.reciprocal_peer(meeting_id, participant_id, peer_id):
        return {"status": "waiting_for_other_phone"}
    own = store.linked_accounts(participant_id)
    peer = store.linked_accounts(peer_id)
    shared = [network for network in available_networks() if network in own and network in peer]
    if not shared:
        return {"status": "waiting_for_accounts"}
    result_key = f"{meeting_id}:{','.join(shared)}"
    with result_lock:
        saved = store.meeting_result(result_key)
        if saved is not None:
            return saved
        networks = {network: network_result(network, dict(own[network]), dict(peer[network])) for network in shared}
        result = {"status": "ready", "networks": networks}
        if all("error" not in value for value in networks.values()):
            store.save_meeting_result(result_key, result)
        return result
