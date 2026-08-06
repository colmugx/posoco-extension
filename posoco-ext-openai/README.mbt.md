# colmugx/posoco-ext-openai

OpenAI Responses API and Codex OAuth adapters for Posoco.

The public provider factory exposes both API-key and Codex subscription
authentication. Codex OAuth uses OpenAI's explicit device-code protocol:
Cetas displays the verification URL and user code, then the extension polls
the device-token endpoint and exchanges the returned authorization code. The
poll parser follows pi's current status/payload semantics (HTTP 403/404
pending, string or `{error:{code}}` errors, `slow_down`, and numeric/string
intervals). Browser callback OAuth is intentionally not part of this adapter's
current capability surface.

Codex token responses are fail-fast: access/refresh tokens and a finite
positive integer `expires_in` are required. The JWT claim
`https://api.openai.com/auth.chatgpt_account_id` is persisted as credential
metadata and sent as `chatgpt-account-id` on subscription requests. OAuth HTTP
uses the shared injectable transport with a 30-second deadline; tests can
inject a fake transport to inspect device, poll, exchange, and refresh wire
requests without network access.

## Explicit model refresh

`OpenAIProvider` implements `RefreshableProviderFactory`. The host must call
the refresh seam explicitly; normal provider construction never performs a
network request. API-key credentials use the standard `{data:[{id}]}`
endpoint, while Codex OAuth uses the provider-specific
`/models?client_version=0.146.0` endpoint and `models[]` metadata. Codex
reasoning levels are copied in server order, and hidden or
`supported_in_api=false` records are excluded from selectable slots. The
provider-owned HTTP transport is injectable for deterministic tests. The
standard API envelope is validated as `{object: "list", data: [...]}` before
any model records are accepted; Codex keeps its independent `models[]` schema.
