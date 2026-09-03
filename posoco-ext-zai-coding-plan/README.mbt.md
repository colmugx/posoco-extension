# posoco-ext-zai-coding-plan

> **Targets: native + js** — protocol transport lives in
> `posoco-ext-zai` (`moonbitlang/async/http`); wasm-gc is not in the
> supported matrix.

GLM Coding Plan subscription for
[Posoco](https://mooncakes.io/docs/colmugx/posoco): the plan-only coding
endpoints of Z.ai and BigModel, with the shared GLM wire protocol (thinking
effort, tool calls, streaming, typed 429 quota verdicts) reused from
`posoco-ext-zai`. The general platform APIs (pay-as-you-go balance) are
**not** served here — use `posoco-ext-zai`.

## Ports contributed

Two structs, one layer each:

| Struct | Port | Responsibility |
|--------|------|----------------|
| `ZaiCodingPlanModelPort` | `ModelPort` | chat (streaming and buffered) plus client-side compact, delegated to the shared GLM port |
| `ZaiCodingPlanModelPort` | `Extension` | composes into `Agent(exts=[...])` as a model extension |
| `ZaiCodingPlanProvider` | `llm.ProviderFactory` / `llm.ApiKeyFactory` | host-side provider registration: builds ports from generic settings/secret sources and runs the key-only login |

## Usage

```bash
moon add colmugx/posoco-ext-zai-coding-plan
```

```moonbit
// moon.pkg: "colmugx/posoco-ext-zai-coding-plan" @zai_coding_plan
// moon.pkg: "colmugx/posoco-ext-zai" @zai

let config = @zai.ZaiConfig::for_model(
  "sk-...",
  "glm-5.3", // default; catalog also serves glm-5.3-flash / 5.2 / 4.5-air
  base_url="https://api.z.ai",
  endpoint_prefix="/api/coding/paas/v4",
)
let port = @zai_coding_plan.ZaiCodingPlanModelPort(config)
let agent = @posoco.Agent(exts=[port, ..other_extensions], config~)
```

In Cetas hosts the provider is registered by name (`zai-coding-plan`);
`/login zai-coding-plan` collects the plan key, `/model` lists the GLM
catalog.

## Endpoints

| `profile` | base | notes |
| --- | --- | --- |
| `coding` (default) | `https://api.z.ai/api/coding/paas/v4` | plan quota |
| `cn_coding` | `https://open.bigmodel.cn/api/coding/paas/v4` | China coding plan |

A `base_url` setting overrides the host but keeps the profile's path prefix
unless the URL carries its own path. The profile — not the login — selects
the platform.

## Login

Plan keys come from the coding-plan console; login prompts once for the key
(no platform picker). Keys travel as `Authorization: Bearer`, and an OAuth
credential is a typed composition failure.

## Behavior

The model list is a preset (the GLM releases the plan serves), not a
discovery endpoint — the coding endpoints expose no `/models` list, so the
catalog never depends on a network request.

All wire behavior is inherited from the shared GLM protocol in
`posoco-ext-zai`: `thinking` / `reasoning_effort` handling,
`reasoning_content` resends with `tool_calls`, `tool_stream` gating for
glm-4.6+, and the typed 429 quota-verdict classification (codes
1308/1310/1316–1321 with flush-time parsing) — pair with posoco-ext-ratelimit
for automatic resume.

## Quota readings

`ZaiCodingPlanProvider::quota_source(source)` returns a
`devkit.QuotaSource` (or `None` when the provider is unconfigured) backed
by the account-level monitor endpoint
`GET {profile-base}/api/monitor/usage/quota/limit`. It reuses the same
settings + credential as the model catalog, so a host wires one key and
gets both. Unlike the chat endpoint, the monitor endpoint wants the plan
key as a bare `Authorization` value (no `Bearer` prefix).

Readings are provider-stated, never estimated: each `data.limits[]` entry
maps onto a `devkit.QuotaReading` with its official `percentage` and
`nextResetTime` (unix milliseconds). `TOKENS_LIMIT` windows are identified
by `(unit, number)` — `3/5` is the 5-hour window, `6/1` the weekly one;
anything else (including `TIME_LIMIT`, the monthly MCP-tool allowance)
stays `Other(label)` verbatim. Entries stating neither a percentage nor a
reset time are skipped, and a `success: false` envelope is an `Err`, not a
zero reading.

```moonbit nocheck
let probe = provider.quota_source(source) // : ZaiCodingPlanQuotaSource?
match probe {
  Some(source) => match QuotaSource::read(source) {
    Ok(readings) => // inspect used_percent / reset_at_ms per window
    Err(reason) => // reading unavailable; never fall back to estimates
  }
  None => // provider not configured
}
```

## Settings

| key | meaning |
| --- | --- |
| `api_key` | secret used when no credential is stored |
| `model` | default `glm-5.3` |
| `profile` | `coding` or `cn_coding` |
| `base_url` | endpoint override (keeps the profile prefix on bare hosts) |
| `reasoning_effort` | picker effort; `off` disables thinking |

## Dependencies

- `colmugx/posoco` — ModelPort trait + types
- `colmugx/posoco-ext-zai` — shared GLM protocol, catalog, config
- `colmugx/posoco-devkit` — `ExtContext` logger helper
- `colmugx/posoco-ext-llm` — provider-neutral catalog/router
- `colmugx/posoco-ext-oauth` — credential store / auth prompt seams
- `moonbitlang/async` — async test runtime
