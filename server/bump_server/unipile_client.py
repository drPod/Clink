from datetime import datetime

import unipile
from unipile.models.create_auth_link_request import CreateAuthLinkRequest

PAGE_LIMIT = 20
MAX_PAGES = 100


class UnipileDataError(RuntimeError):
    pass


class InstagramClient:
    def __init__(self, api_key: str, *, base_url: str = "https://api.unipile.com") -> None:
        config = unipile.Configuration()
        config.api_key["apiKey"] = api_key
        config.host = base_url.rstrip("/")
        config.retries = 0
        self.api_client = unipile.ApiClient(config)
        self.auth = unipile.HostedAuthApi(self.api_client)
        self.accounts = unipile.AccountsApi(self.api_client)
        self.users = unipile.UsersApi(self.api_client)

    def create_link(self, *, callback: str, state: str, expires_on: datetime) -> str:
        payload = CreateAuthLinkRequest.from_dict(
            {"providers": "instagram", "redirect_uri": callback, "expires_on": expires_on.isoformat(), "state": state}
        )
        return self.auth.create_auth_link(payload, _request_timeout=30).link

    def verify_account(self, account_id: str) -> tuple[str, str]:
        account = self.accounts.get_account(account_id, _request_timeout=30)
        if account.id != account_id or account.provider != "instagram" or account.status != "running":
            raise UnipileDataError("Instagram account is not ready")
        return account.id, account.user_id

    def following(self, account_id: str) -> list[dict[str, str | None]]:
        users: dict[str, dict[str, str | None]] = {}
        seen_cursors: set[str] = set()
        cursor: str | None = None
        offset = 0
        for _ in range(MAX_PAGES):
            kwargs = {"cursor": cursor} if cursor else {"offset": offset, "limit": PAGE_LIMIT}
            page = self.users.list_user_following(
                "me", account_id, _request_timeout=30, _headers={"Cache-Control": "max-age=3600"}, **kwargs
            )
            before = len(users)
            for user in page.data:
                if not user.id:
                    raise UnipileDataError("Following entry has no provider ID")
                users[user.id] = {
                    "id": user.id,
                    "name": user.display_name,
                    "username": user.public_identifier,
                    "profile_url": user.profile_url,
                }
            if page.next_cursor:
                if page.next_cursor in seen_cursors:
                    raise UnipileDataError("Unipile repeated a pagination cursor")
                seen_cursors.add(page.next_cursor)
                cursor = page.next_cursor
                continue
            if cursor or not page.data or (page.total_count is not None and len(users) >= page.total_count):
                return list(users.values())
            if len(users) == before:
                raise UnipileDataError("Unipile repeated a page without progress")
            offset += PAGE_LIMIT
        raise UnipileDataError("Following list exceeded the demo's 100-page limit")
