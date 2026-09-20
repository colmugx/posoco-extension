// MCP + OAuth end-to-end fixture for the js login test
// (cetas-js/lib/mcp_login_wbtest.mbt): one node process plays BOTH halves —
// an OAuth-protected legacy 2025-11-25 MCP resource server at /mcp, and the
// authorization server the device flow talks to (RFC 9728/8414 metadata,
// RFC 7591 dynamic registration, RFC 8628 device grant with auto-approve,
// RFC 6749 refresh grant). No deps beyond node builtins.
//
// Wire contract highlights (what the MoonBit stack actually reads):
// - Unauthenticated /mcp answers 401 with
//   `WWW-Authenticate: Bearer resource_metadata_uri="<well-known URL>"`;
//   posoco-ext-mcp's extract_resource_metadata_uri reads exactly that quoted
//   parameter out of the client's connect error.
// - With a valid token, any non-initialize first request (the modern
//   server/discover era probe) gets HTTP 400 with a plain-text body, which
//   the client's era probe classifies as "legacy server, fall back to
//   initialize". A modern JSON-RPC error body here would flip the verdict.
// - The refresh grant rotates the access token and REVOKES the one the
//   device flow issued, so post-refresh /mcp calls only succeed on the
//   refreshed token.
//
// Usage: node http_oauth_server.mjs <port-file> — the listening port is
// written to <port-file> (bare digits, no trailing newline) once the server
// is accepting connections.

import { createServer } from "node:http";
import { writeFileSync } from "node:fs";
import { randomUUID } from "node:crypto";

const PORT_FILE = process.argv[2];
const TOKEN_TTL_SECS = 3600;
const DEVICE_GRANT = "urn:ietf:params:oauth:grant-type:device_code";

let BASE_URL = ""; // set once the ephemeral port is known

// --- authorization-server state --------------------------------------------

let tokenSerial = 0;
let clientSerial = 0;
const deviceCodes = new Map(); // device_code -> { approved: bool }
const accessTokens = new Map(); // access_token -> { refresh_token, expires_at, revoked }
const refreshTokens = new Map(); // refresh_token -> { access_token }

function issueTokenPair() {
  tokenSerial += 1;
  const access = `at-${tokenSerial}-${randomUUID()}`;
  const refresh = `rt-${tokenSerial}-${randomUUID()}`;
  const expiresAt = Math.floor(Date.now() / 1000) + TOKEN_TTL_SECS;
  accessTokens.set(access, { refresh_token: refresh, expires_at: expiresAt, revoked: false });
  refreshTokens.set(refresh, { access_token: access });
  return { access, refresh };
}

function isTokenValid(token) {
  const record = accessTokens.get(token);
  return (
    record !== undefined && !record.revoked && Date.now() / 1000 < record.expires_at
  );
}

// --- HTTP helpers ------------------------------------------------------------

function readBody(req) {
  return new Promise((resolve) => {
    const chunks = [];
    req.on("data", (chunk) => chunks.push(chunk));
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf-8")));
    req.on("error", () => resolve(""));
  });
}

function sendJson(res, status, obj, headers = {}) {
  res.writeHead(status, { "Content-Type": "application/json", ...headers });
  res.end(JSON.stringify(obj));
}

function sendText(res, status, text) {
  res.writeHead(status, { "Content-Type": "text/plain" });
  res.end(text);
}

// --- resource server: MCP over legacy 2025-11-25 streamable HTTP --------------

const sessions = new Set();

function handleMcp(req, res, body) {
  // Real Bearer gate. The 401's WWW-Authenticate carries the well-known
  // parameter the bridge extracts as the auth challenge.
  const match = /^Bearer (.+)$/.exec(req.headers["authorization"] || "");
  const token = match ? match[1] : "";
  if (!isTokenValid(token)) {
    res.writeHead(401, {
      "Content-Type": "application/json",
      "WWW-Authenticate": `Bearer resource_metadata_uri="${BASE_URL}/.well-known/oauth-protected-resource"`,
    });
    res.end(JSON.stringify({ error: "unauthorized" }));
    return;
  }

  let msg;
  try {
    msg = JSON.parse(body);
  } catch {
    sendText(res, 400, "malformed JSON-RPC body");
    return;
  }
  const { id, method, params } = msg;

  if (id === undefined || id === null) {
    // JSON-RPC notification (e.g. notifications/initialized): 202, no body.
    res.writeHead(202);
    res.end();
    return;
  }

  if (method === "initialize") {
    const sessionId = randomUUID();
    sessions.add(sessionId);
    res.writeHead(200, {
      "Content-Type": "application/json",
      "Mcp-Session-Id": sessionId,
    });
    res.end(
      JSON.stringify({
        jsonrpc: "2.0",
        id,
        result: {
          protocolVersion: "2025-11-25",
          capabilities: { tools: {} },
          serverInfo: { name: "oauth-fixture", version: "1.0.0" },
        },
      }),
    );
    return;
  }

  // Legacy servers refuse any non-initialize first message. This is the
  // branch the modern server/discover era probe hits with a valid token:
  // the 400's plain body must NOT be a modern JSON-RPC error, or the probe
  // would classify the server as modern instead of falling back.
  const sessionId = req.headers["mcp-session-id"] || "";
  if (!sessions.has(sessionId)) {
    sendText(res, 400, "legacy 2025-11-25 server: send initialize first");
    return;
  }

  switch (method) {
    case "tools/list":
      sendJson(res, 200, {
        jsonrpc: "2.0",
        id,
        result: {
          tools: [
            {
              name: "oauth_tool",
              description: "The only tool; proves the Bearer token works.",
              inputSchema: { type: "object", properties: {} },
            },
          ],
        },
      });
      break;
    case "tools/call":
      if (params?.name !== "oauth_tool") {
        sendJson(res, 200, {
          jsonrpc: "2.0",
          id,
          error: { code: -32602, message: "unknown tool " + String(params?.name) },
        });
        break;
      }
      sendJson(res, 200, {
        jsonrpc: "2.0",
        id,
        result: {
          content: [{ type: "text", text: "oauth:ok" }],
          isError: false,
        },
      });
      break;
    case "ping":
      sendJson(res, 200, { jsonrpc: "2.0", id, result: {} });
      break;
    default:
      sendJson(res, 200, {
        jsonrpc: "2.0",
        id,
        error: { code: -32601, message: "unknown method " + String(method) },
      });
  }
}

function handleMcpDelete(req, res) {
  // Best-effort session teardown (the legacy transport's close sends this).
  const sessionId = req.headers["mcp-session-id"] || "";
  sessions.delete(sessionId);
  res.writeHead(200);
  res.end();
}

// --- authorization server endpoints -------------------------------------------

function handleProtectedResourceMetadata(res) {
  sendJson(res, 200, {
    resource: BASE_URL + "/mcp",
    authorization_servers: [BASE_URL],
    bearer_methods_supported: ["header"],
  });
}

function handleServerMetadata(res) {
  sendJson(res, 200, {
    issuer: BASE_URL,
    authorization_endpoint: BASE_URL + "/authorize",
    token_endpoint: BASE_URL + "/token",
    device_authorization_endpoint: BASE_URL + "/device_authorize",
    registration_endpoint: BASE_URL + "/register",
    grant_types_supported: [DEVICE_GRANT, "refresh_token"],
    token_endpoint_auth_methods_supported: ["none"],
  });
}

function handleRegister(res) {
  clientSerial += 1;
  sendJson(res, 201, {
    client_id: "client-" + clientSerial,
    client_id_issued_at: Math.floor(Date.now() / 1000),
    client_name: "cetas-js",
    grant_types: [DEVICE_GRANT, "authorization_code", "refresh_token"],
    token_endpoint_auth_method: "none",
  });
}

function handleDeviceAuthorize(res) {
  // Auto-approve immediately: NoopAuthInteraction means nobody will ever
  // visit the verification URI, so the first poll must already succeed.
  const deviceCode = "dev-" + randomUUID();
  deviceCodes.set(deviceCode, { approved: true });
  sendJson(res, 200, {
    device_code: deviceCode,
    user_code: "OAUTH-OK",
    verification_uri: BASE_URL + "/verify",
    verification_uri_complete: BASE_URL + "/verify?code=OAUTH-OK",
    expires_in: 600,
    interval: 1,
  });
}

function handleToken(res, body) {
  const form = new URLSearchParams(body);
  const grantType = form.get("grant_type") || "";

  if (grantType === DEVICE_GRANT) {
    const grant = deviceCodes.get(form.get("device_code") || "");
    if (grant === undefined) {
      sendJson(res, 400, { error: "invalid_grant" });
      return;
    }
    if (!grant.approved) {
      sendJson(res, 400, { error: "authorization_pending" });
      return;
    }
    const { access, refresh } = issueTokenPair();
    sendJson(res, 200, {
      access_token: access,
      token_type: "Bearer",
      expires_in: TOKEN_TTL_SECS,
      refresh_token: refresh,
    });
    return;
  }

  if (grantType === "refresh_token") {
    const presented = form.get("refresh_token") || "";
    const record = refreshTokens.get(presented);
    if (record === undefined) {
      sendJson(res, 400, { error: "invalid_grant" });
      return;
    }
    // Rotation with revocation: the access token bound to the presented
    // refresh token (the one the device flow issued) dies here, so /mcp
    // only accepts the freshly issued pair.
    const bound = accessTokens.get(record.access_token);
    if (bound !== undefined) {
      bound.revoked = true;
    }
    refreshTokens.delete(presented);
    const { access, refresh } = issueTokenPair();
    sendJson(res, 200, {
      access_token: access,
      token_type: "Bearer",
      expires_in: TOKEN_TTL_SECS,
      refresh_token: refresh,
    });
    return;
  }

  sendJson(res, 400, { error: "unsupported_grant_type" });
}

// --- server --------------------------------------------------------------------

const server = createServer((req, res) => {
  readBody(req).then((body) => {
    const pathname = new URL(req.url || "/", "http://fixture.invalid").pathname;
    if (pathname === "/mcp") {
      if (req.method === "DELETE") {
        handleMcpDelete(req, res);
      } else if (req.method === "POST") {
        handleMcp(req, res, body);
      } else {
        sendText(res, 405, "method not allowed");
      }
      return;
    }
    switch (pathname) {
      case "/.well-known/oauth-protected-resource":
        handleProtectedResourceMetadata(res);
        break;
      case "/.well-known/oauth-authorization-server":
        handleServerMetadata(res);
        break;
      case "/register":
        handleRegister(res);
        break;
      case "/device_authorize":
        handleDeviceAuthorize(res);
        break;
      case "/token":
        handleToken(res, body);
        break;
      case "/verify":
        sendText(res, 200, "device approved automatically by the fixture");
        break;
      default:
        sendText(res, 404, "not found");
    }
  });
});

server.listen(0, "127.0.0.1", () => {
  const port = server.address().port;
  BASE_URL = "http://127.0.0.1:" + port;
  writeFileSync(PORT_FILE, String(port));
});
