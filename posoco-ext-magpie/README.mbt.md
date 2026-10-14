# posoco-ext-magpie

Independent Gateway-aware Model Manager for Posoco, not a provider hosted by
`posoco-ext-llm`.

## Implemented in this PR

- Typed gateway URL, local/remote authentication and redacted configuration.
- `GET /api/hello` identity verification and `GET /v1/models` catalog refresh.
- Injectable transport and deterministic fake gateway tests.
- Atomic refresh, last-known-good catalog and explicit offline/error status.
- Provider-neutral `ModelManagerControl` selection, opaque IDs and effort levels.
- Raw catalog entries retained alongside manager-neutral model projections.

Use `MagpieConfig::MagpieConfig(...)` and
`MagpieManager::MagpieManager(config=...)`, then call
`manager.refresh()` before offering models to users.

## Deliberately not implemented yet

This is a **control-plane foundation**, not a functioning Posoco `ModelPort`.
No inference, streaming, session affinity, active route observability, quota
telemetry, usage reporting, protocol planning or automatic upstream protocol
selection is implemented here. Do not present a successful catalog refresh as
proof that a model is available for inference.

A follow-up must integrate the existing `posoco-kit-messages`,
`posoco-kit-responses`, and `posoco/kit-chat-completions` according to
Magpie's `native_endpoints`, while preserving model/group identity and making
translation risk explicit.

## Catalog limitations

The parser preserves each raw Magpie JSON entry, including `magpie_label`,
`native_endpoints`, `context_length`, `max_input_tokens`,
`max_output_tokens` and future extension fields. Only a conservative subset
is projected into `ManagerModelInfo`. Missing `native_endpoints` does not
mean that the gateway cannot translate requests to a given model.

Current deterministic tests exercise synthetic representative catalog rows.
The complete user-provided 78-model fixture and protocol planning are not
included in this PR and must be regression-tested before the execution layer
is called feature complete.

## Testing

From the workspace root, run `moon check --target native`,
`moon check --target js`, `moon check --target wasm`,
`moon test --target native -p colmugx/posoco-ext-magpie`, and `moon info`.
