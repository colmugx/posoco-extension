# posoco-ext-oauth

> **Targets: native + js ship the defaults.** The traits below compile on
> every target, but the default HTTP transport and the callback-server
> factories exist only on native and js; a wasm-gc host injects its own impls.

Shared OAuth machinery for Posoco providers — the
[`OAuthProvider`](https://mooncakes.io/docs/colmugx/posoco) contract,
credential stores, RFC 8628 device flow, RFC 6749 refresh, RFC 7591 dynamic
registration + metadata discovery, and a hardened PKCE authorization-code
browser flow. The package owns the shared flow logic; providers supply
endpoints and client config.

## Ports contributed

This package is a library, **not** an Agent extension: it defines no
`Extension`. Hosts and provider packages implement or consume these traits:

| Trait | Role |
|-------|------|
| `OAuthProvider` | the provider contract: `provider_id` / `login` / `refresh` / `to_auth` |
| `AuthInteraction` | host UI channel — `AuthUrl` / `DeviceCode` / `Progress` messages plus `is_cancelled` |
| `AuthPromptInteraction` | optional prompt seam (`Secret` / `Select`), kept separate from `AuthInteraction` so OAuth-only hosts stay source compatible |
| `CallbackServer` | local loopback callback seam for the PKCE browser flow |
| `OAuthHttpTransport` | HTTP seam used by every flow; `DefaultOAuthHttpTransport` ships on native + js only |
| `CredentialStore` / `ProviderCredentialStore` / `ApiKeyStore` | credential storage; `ProviderCredentialStore` keeps one tagged record per provider and preserves the user's explicit auth-method choice across restarts |

`NoopAuthInteraction`, `NoopAuthPromptInteraction`, and the `InMemory*`
stores ship for headless hosts and tests.

## Usage

```bash
moon add colmugx/posoco-ext-oauth
```

```moonbit nocheck
// moon.pkg: "colmugx/posoco-ext-oauth" @oauth

let server : &@oauth.CallbackServer = @oauth.create_callback_server()
let transport : &@oauth.OAuthHttpTransport =
  @oauth.DefaultOAuthHttpTransport::DefaultOAuthHttpTransport()
let credential = @oauth.run_pkce_browser_flow(
  {
    client_id: "your-client-id",
    authorize_url: "https://auth.example.com/authorize",
    token_url: "https://auth.example.com/token",
    redirect_uri: "http://localhost:1455/auth/callback",
    callback_port: 1455,
    scope: "openid profile email offline_access",
    extra_authorize_params: [],
    fallback_port: Some(1457),
  },
  interaction, // your &AuthInteraction impl
  server,
  transport,
)
```

## PKCE browser flow

`run_pkce_browser_flow` runs the full authorization-code grant with PKCE
(`S256`) against a local loopback callback server. Prefer it whenever the
provider's authorization server supports it — PKCE binds the authorization
request to a verifier known only to the client. The device flow below
remains the login path for providers that require it (Kimi Code subscription
login is RFC 8628 device flow).

### Configuration

`PkceFlowConfig` fields:

| Field | Meaning |
|-------|---------|
| `client_id` | public client id, sent in the authorize URL and the token exchange |
| `authorize_url` | provider authorization endpoint, e.g. `https://auth.openai.com/oauth/authorize` |
| `token_url` | provider token endpoint, e.g. `https://auth.openai.com/oauth/token` |
| `redirect_uri` | loopback callback URI, e.g. `http://localhost:1455/auth/callback` |
| `callback_port` | port the local callback server binds |
| `scope` | scope string, url-encoded into the authorize URL |
| `extra_authorize_params` | provider-specific authorize params (e.g. Codex's `originator`), appended url-encoded in array order |
| `fallback_port` | retry port when `callback_port` is occupied — see the rewrite rule below |

### How a run unfolds

1. Generate the PKCE pair and a random `state`.
2. Build the authorize URL: `response_type=code`, client id, url-encoded
   `redirect_uri` + `scope`, `code_challenge` + `code_challenge_method=S256`,
   `state`, then `extra_authorize_params`.
3. Start the callback server on `callback_port`; when that bind fails, retry
   `fallback_port` if configured and different.
4. Notify the host to open the URL (`AuthMessage::AuthUrl`).
5. Wait for the callback `(code, state)`; with `prompt?` a manual paste races
   the server (below).
6. Validate the state, then exchange code + verifier for tokens.
7. Stop the server on success **and** on every raise path after start — a
   state mismatch or a failed exchange still releases the port. `stop` is
   safe to call more than once.

**Fallback-port rule** — OAuth requires an identical `redirect_uri` in the
authorize request and the token exchange, so when the fallback port wins, the
port segment of `redirect_uri` is rewritten to the port actually bound; the
authorize URL and the exchange both carry it. If both binds fail, the primary
bind error is raised.

**State validation** — the received `state` (server callback or pasted) must
equal the generated one. A mismatch raises
`OAuthError::ParseError("oauth state mismatch")` before any token exchange.

**Token exchange** — a form-encoded `grant_type=authorization_code` POST
(carrying `code`, `code_verifier`, `redirect_uri`) over the injected
transport. The optional `parse_credential?` hook replaces the lenient default
parser, which maps an `invalid_grant` error to `OAuthError::InvalidGrant` and
fills missing `refresh_token` / `expires_in` / `token_type` with `""` / `3600`
/ `"Bearer"`.

### Manual-paste fallback

Pass `prompt? : &AuthPromptInteraction` and the flow races a paste prompt (an
`AuthPromptRequest::Secret` whose message carries the authorize URL) against
the callback server:

- Accepted input is a full callback URL containing `code` and `state` query
  params, or a bare `code=..&state=..` query string. A bare code without
  state is rejected.
- The pasted `state` is validated exactly like the server's.
- An unparseable paste (or a cancelled prompt) raises inside its race task;
  `@async.any(allow_failure=true)` ignores raised errors, so the pending
  callback wait continues and the server can still win.
- A winning paste stops the server itself before returning.

### Security properties

- **CSRF `state`** — base64url of 16 random bytes (22 chars), validated on
  callback; a forged state mints no credential and sends no token request.
- **PKCE verifier** — base64url of 48 random bytes (64 chars; RFC 7636 §4.1
  allows 43–128). The challenge is `base64url(sha256(verifier))`, method
  `S256`.
- **Entropy chain** — `oauth_random_bytes` probes the backend entropy source:
  native uses a C `getentropy` stub (256-byte chunks, `EINTR` retry, empty
  result on any failure or unsupported platform); js uses
  `crypto.getRandomValues`. A time-seeded LCG runs only when the probe
  returns anything but exactly `n` bytes — the wasm / failed-probe fallback,
  never the intended path for credential backends.
- **Bounded wait** — `wait_callback` raises `ExpiredToken` after the default
  5-minute deadline.
- **No leaked port** — the server stops on every exit path after start.

### The CallbackServer seam

`CallbackServer` is the IO seam that keeps the shared flow free of platform
HTTP APIs: `start(port)`, `wait_callback() -> (code, state)`, `stop()`. Each
target ships an impl plus a `create_callback_server` factory:

| Target | Impl | Mechanism |
|--------|------|-----------|
| native | `NativeCallbackServer` | `@http.Server` on `127.0.0.1`; `wait_callback` polls `accept` directly (no background accept loop), answers `200` "Login successful" on a code and `404` otherwise |
| js | `JsCallbackServer` | `Bun.serve`; its fetch handler writes `code`/`state` into the struct, returns `400` on an `error` param |

Other targets ship no impl — hosts implement the trait.

## Device flow (RFC 8628)

Device flow stays supported for providers whose authorization servers require
it:

```moonbit nocheck
// moon.pkg: "colmugx/posoco-ext-oauth" @oauth

let config = @oauth.DeviceFlowConfig(
  client_id="your-client-id",
  device_auth_endpoint="https://example.com/device/authorize",
  token_endpoint="https://example.com/token",
)
let credential = @oauth.run_device_flow(config, interaction)
```

- `DeviceFlowConfig::with_default_headers` merges provider identity headers
  into every device-flow POST; the flow's own `Content-Type` / `Accept`
  always override them.
- Polling sleeps `interval` seconds (response value, default 5) between
  polls, honours `slow_down` (server interval, or +5s), raises `ExpiredToken`
  at `expires_in` (default 900s), and checks `is_cancelled` between
  iterations.
- `verification_uri_complete` is preferred for display when present; only
  absolute `http`/`https` URIs without whitespace or control characters are
  accepted.
- `authorization_pending` / `slow_down` are control flow; `access_denied`,
  `expired_token`, and `invalid_grant` are typed failures. HTTP 400 bodies
  are parsed (RFC 8628 uses 400 for pending); status `>= 500` is terminal
  without parsing the body.
- `run_device_flow` constructs the default transport (native/js only); the
  wasm variant raises `Cancelled` — use `run_device_flow_with_transport` with
  a host-supplied transport there.
