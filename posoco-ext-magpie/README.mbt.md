# posoco-ext-magpie

Magpie Gateway integration for [Posoco](https://github.com/colmugx/posoco). Provides a model manager, a multi-protocol model port, and gateway observability. It is independent of `posoco-ext-llm`.

## Configuration

Add `colmugx/posoco-ext-magpie` to your MoonBit module dependencies and import the package.

```mbt nocheck
let runtime = @magpie.MagpieRuntime::activate(
  settings=Some(settings_json),
  transport=@magpie.magpie_http_transport(timeout_ms=120000),
)
let agent = @posoco.Agent::Agent(
  exts=[runtime],
  config=agent_config,
)
```

Example settings:

```json
{
  "base_url": "http://127.0.0.1:3425",
  "enabled": true,
  "model": "provider/model-id",
  "effort": "high"
}
```

`base_url` defaults to `http://127.0.0.1:3425`. A remote gateway requires a `gateway_key` supplied securely by the Host. Do not store credentials in source code, logs, or project files.

`model` is an optional opaque catalog ID, including routing-group IDs. `effort` must be offered by the selected model. Invalid settings leave the gateway disabled and expose an `unconfigured_reason`.

Construction does not perform network I/O. The Posoco Agent invokes `on_start` automatically before its first turn. You can use `magpie_refresh` to load models before that turn.

## Model execution

The extension selects an endpoint using catalog metadata and protocol requirements:

- Anthropic Messages: `/v1/messages`
- OpenAI Responses: `/v1/responses`
- OpenAI Chat Completions: `/v1/chat/completions`

Model IDs pass through unchanged. Declared-native protocols are preferred where fidelity is required. Gateway translation requires an explicit policy and records fidelity risks. Unsupported requirements are rejected before inference. A model explicitly declaring text-only input rejects image requests.

`X-Magpie-Session` preserves gateway routing affinity across calls within the same Posoco session. Posoco does not duplicate Magpie's provider selection, upstream fallback, quotas, or pricing.

## Commands

| Command | Purpose |
| --- | --- |
| `magpie_model` | List models or select a model and effort |
| `magpie_status` | Gateway, catalog, selection, and service status |
| `magpie_refresh` | Refresh the model catalog |
| `magpie_route` | Inspect routing for a session |
| `magpie_quotas` | Inspect quota cards |
| `magpie_limit` | Inspect the current gateway key limit |
| `magpie_usage` | Inspect usage and reported cost |
| `magpie_requests` | List request history |
| `magpie_concurrency` | Inspect gateway concurrency |
| `magpie_usage_recent` | Inspect the runtime's recent model executions |

Observability endpoints can require separate permissions. A forbidden quota or usage request does not disable inference. A Posoco Agent composes one ModelPort; to host another model manager, use a separate Agent or a Host-owned routing adapter.

## Lifecycle and security

`MagpieRuntime::activate` constructs the manager, ModelPort, and intelligence client. First-turn startup refreshes the catalog; an unreachable Gateway does not crash startup. `on_shutdown` deactivates commands and clears recent execution reports. A shut-down Posoco Agent is terminal; create a new Agent to restart.

Errors avoid returning request bodies, credentials, or session identifiers. HTTP streaming closes its connection after normal completion, failure, or cancellation. Inference is never retried automatically after an ambiguous failure.

Cache read/write counts and costs use gateway-reported evidence. Missing price or cache-TTL information is not filled with estimates. Signed thinking and cache-control fidelity require compatible native protocol support.

## Verification

Offline tests use a scripted Gateway:

```sh
moon test --target native -p colmugx/posoco-ext-magpie
moon test --target js -p colmugx/posoco-ext-magpie
moon test --target wasm -p colmugx/posoco-ext-magpie
moon info
```

Run read-only checks against a locally running Gateway:

```sh
MAGPIE_LIVE_URL=http://127.0.0.1:3425 moon run --target native posoco-ext-magpie/src/harness
```

Optional live inference can incur charges. It requires `MAGPIE_LIVE_INFER=1`; use `MAGPIE_LIVE_KEY` for remote authentication. The harness enforces a bounded request count. One-hour cache probes additionally require `MAGPIE_LIVE_CACHE_1H=1`. Skipped live checks do not establish compatibility.

The module does not implement a separate scheduler, gateway administration, or upstream account management.
