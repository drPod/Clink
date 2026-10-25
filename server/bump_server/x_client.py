import base64
import hashlib
import json
import secrets
from urllib.parse import urlencode

import urllib3

AUTHORIZE_URL = "https://x.com/i/oauth2/authorize"
TOKEN_URL = "https://api.x.com/2/oauth2/token"
ME_URL = "https://api.x.com/2/users/me"
FOLLOWINGS_URL = "https://api.twitterapi.io/twitter/user/followings"
MAX_PAGES = 50


class XError(RuntimeError):
    def __init__(self, message: str, status: int = 502, retry_after: str | None = None) -> None:
        super().__init__(message)
        self.status = status
        self.retry_after = retry_after


def pkce_pair() -> tuple[str, str]:
    verifier = secrets.token_urlsafe(64)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    return verifier, challenge


class XClient:
    def __init__(self, client_id: str, client_secret: str, graph_key: str) -> None:
        self.client_id = client_id
        self.client_secret = client_secret
        self.graph_key = graph_key
        self.http = urllib3.PoolManager(timeout=urllib3.Timeout(connect=10, read=30), retries=False)

    def authorize_url(self, *, callback: str, state: str, challenge: str) -> str:
        query = {
            "response_type": "code",
            "client_id": self.client_id,
            "redirect_uri": callback,
            "scope": "users.read tweet.read",
            "state": state,
            "code_challenge": challenge,
            "code_challenge_method": "S256",
        }
        return f"{AUTHORIZE_URL}?{urlencode(query)}"

    def identify(self, *, code: str, verifier: str, callback: str) -> tuple[str, str]:
        form = {"grant_type": "authorization_code", "code": code, "redirect_uri": callback, "code_verifier": verifier}
        headers = {"Content-Type": "application/x-www-form-urlencoded"}
        if self.client_secret:
            basic = base64.b64encode(f"{self.client_id}:{self.client_secret}".encode()).decode()
            headers["Authorization"] = f"Basic {basic}"
        else:
            form["client_id"] = self.client_id
        token = self._json("POST", TOKEN_URL, headers=headers, body=urlencode(form))
        access_token = token.get("access_token")
        if not access_token:
            raise XError("X did not return an access token")
        me = self._json("GET", ME_URL, headers={"Authorization": f"Bearer {access_token}"}).get("data") or {}
        if not me.get("id") or not me.get("username"):
            raise XError("X did not return the signed-in user")
        return me["id"], me["username"]

    def following(self, username: str) -> list[dict[str, str | None]]:
        users: dict[str, dict[str, str | None]] = {}
        cursor = ""
        seen_cursors: set[str] = set()
        for _ in range(MAX_PAGES):
            query = {"userName": username, "pageSize": 200} | ({"cursor": cursor} if cursor else {})
            page = self._json("GET", f"{FOLLOWINGS_URL}?{urlencode(query)}", headers={"X-API-Key": self.graph_key})
            if page.get("status") == "error":
                raise XError("X following list request failed")
            entries = page.get("followings")
            if not isinstance(entries, list):
                raise XError("X following list returned an invalid page")
            for user in entries:
                handle = user.get("userName") or user.get("screen_name")
                user_id = str(user.get("id") or "") or (handle or "").lower()
                if not user_id:
                    raise XError("Following entry has no X ID")
                users[user_id] = {
                    "id": user_id,
                    "name": user.get("name") or handle or user_id,
                    "username": handle,
                    "profile_url": f"https://x.com/{handle}" if handle else None,
                }
            if page.get("has_next_page") is False:
                return list(users.values())
            cursor = page.get("next_cursor") or ""
            if not cursor or cursor in seen_cursors:
                raise XError("X following list pagination stopped before completion")
            seen_cursors.add(cursor)
        raise XError("Following list exceeded the demo's page limit")

    def _json(self, method: str, url: str, *, headers: dict[str, str], body: str | None = None) -> dict:
        try:
            response = self.http.request(method, url, headers=headers, body=body)
        except urllib3.exceptions.HTTPError as error:
            raise XError("X request failed") from error
        if response.status == 429:
            raise XError("X is rate limited", 429, response.headers.get("retry-after"))
        if response.status >= 400:
            raise XError(f"X request failed with HTTP {response.status}", 502 if response.status >= 500 else 400)
        try:
            return json.loads(response.data)
        except ValueError as error:
            raise XError("X returned invalid JSON") from error
