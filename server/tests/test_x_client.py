import json

import pytest

from bump_server.x_client import XClient, XError


class Response:
    def __init__(self, body: dict, status: int = 200) -> None:
        self.status = status
        self.data = json.dumps(body).encode()
        self.headers = {}


class HTTP:
    def __init__(self, responses: list[Response]) -> None:
        self.responses = iter(responses)

    def request(self, method: str, url: str, **kwargs) -> Response:
        return next(self.responses)


def test_following_requires_last_page() -> None:
    client = XClient("client", "", "key")
    client.http = HTTP(
        [
            Response({"followings": [{"id": "1", "screen_name": "one"}], "has_next_page": True, "next_cursor": "next"}),
            Response({"followings": [{"id": "2", "screen_name": "two"}], "has_next_page": False}),
        ]
    )
    assert [user["id"] for user in client.following("owner")] == ["1", "2"]


def test_following_rejects_incomplete_page() -> None:
    client = XClient("client", "", "key")
    client.http = HTTP([Response({"followings": [{"id": "1"}], "has_next_page": True})])
    with pytest.raises(XError, match="before completion"):
        client.following("owner")
