const http = require("http");

const accounts = {
  acc_first: "ig_first",
  acc_second: "ig_second",
  acc_limited: "ig_limited",
};
const users = {
  shared: { id: "ig_shared", object: "User", type: "individual", display_name: "Shared Friend", public_identifier: "sharedfriend" },
  first: { id: "ig_first_only", object: "User", type: "individual", display_name: "First Only" },
  second: { id: "ig_second_only", object: "User", type: "individual", display_name: "Second Only" },
};
let linkNumber = 0;

const server = http.createServer((req, res) => {
  const url = new URL(req.url, "http://mock");
  const parts = url.pathname.split("/").filter(Boolean);
  const send = (status, body, headers = {}) => {
    res.writeHead(status, { "Content-Type": "application/json", ...headers });
    res.end(JSON.stringify(body));
  };
  if (parts[0] !== "v2") return send(501, { error: "unmodeled path" });
  if (req.method === "POST" && parts[1] === "auth" && parts[2] === "link") {
    let body = "";
    req.on("data", (chunk) => { body += chunk; });
    req.on("end", () => {
      const payload = JSON.parse(body);
      const accountId = ["acc_first", "acc_second", "acc_limited"][Math.min(linkNumber++, 2)];
      const callback = new URL(payload.redirect_uri);
      callback.searchParams.set("state", payload.state);
      callback.searchParams.set("provider", "instagram");
      callback.searchParams.set("account_id", accountId);
      send(200, { object: "HostedAuthLink", link: callback.toString() });
    });
    return;
  }
  if (req.method !== "GET") return send(501, { error: "unmodeled method" });
  if (parts[1] === "accounts" && parts.length === 3) {
    const userId = accounts[parts[2]];
    if (!userId) return send(404, { error: "account not found" });
    return send(200, {
      object: "Account", id: parts[2], user_id: userId, application_id: "app_demo",
      created_at: "2026-10-25T00:00:00Z", status: "running", provider: "instagram", is_locked: false, metadata: {},
    });
  }
  if (parts[2] === "users" && parts[3] === "me" && parts[4] === "following") {
    if (parts[1] === "acc_limited") {
      return send(429, { type: "api/too_many_requests", title: "Rate limited" }, { "retry-after": "120" });
    }
    if (parts[1] === "acc_first") {
      if (url.searchParams.get("cursor") === "page2") return send(200, { data: [users.first] });
      if (url.searchParams.has("cursor")) return send(400, { error: "bad cursor" });
      return send(200, { data: [users.shared], next_cursor: "page2" });
    }
    if (parts[1] === "acc_second") {
      if (url.searchParams.get("offset") === "0") return send(200, { data: [users.shared, users.second], total_count: 2 });
      return send(200, { data: [] });
    }
  }
  return send(501, { error: "unmodeled endpoint" });
});

server.listen(process.env.PORT);
