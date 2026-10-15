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
- Typed `MagpieModelMetadata`: `magpie_label`, `context_window`,
  `context_length`, `max_input_tokens`, `max_output_tokens`, declared input
  modalities, the `reasoning` declaration, `supported_reasoning_levels`
  (exact strings, server order), typed `native_endpoints` (unknown paths
  retained without a protocol), and routing-group identity via the `group/`
  id namespace. Optional fields distinguish unknown (`None`) from explicitly
  declared, including declared-empty; unknown extension metadata stays on
  the raw entry. Model IDs are never split or assumed to carry one slash.
- Typed protocol planning (`plan_protocol`, `evaluate_protocol`): Anthropic
  Messages, OpenAI Responses and OpenAI Chat Completions evaluated
  independently, composed under a caller preference and an explicit
  `MagpieTranslationPolicy` into either a structured plan or an explicit
  incompatibility with per-protocol blockers. Pure and deterministic.

Use `MagpieConfig::MagpieConfig(...)` and
`MagpieManager::MagpieManager(config=...)`, then call
`manager.refresh()` before offering models to users. `manager.catalog_entry(id)`
hands out an isolated typed entry for `plan_protocol`:

```mbt nocheck
let outcome = plan_protocol(
  entry,
  requirements=MagpieRequirements::MagpieRequirements(
    tools=true,
    streaming=true,
    signed_thinking_replay=true,
  ),
  preference=Prefer(Responses),
  policy=NativeOnly,
)
```

A `Planned` outcome carries the selected endpoint path, native vs
gateway-translated kind, confidence, a fixed-order capability matrix with
evidence source and status per requested feature, fidelity risks, explicit
unsupported requirements, and the selection reasons. Evidence tiers are
never mixed: `ProtocolNative`, `CatalogDeclared`, `GatewayLevel`, and
`Unknown`. Missing `native_endpoints` is unknown, never a prohibition.
Signed thinking and native prompt caching are protocol-native only through a
declared native Anthropic Messages endpoint, and routing groups never
inherit one — their upstream members may change per request. Declared-fact
rejections (images on a text-only model, an effort outside the advertised
ladder) block every policy; required-but-unguaranteed features are planned
only under `AllowTranslated`, with the risks kept on the plan.

### Capability matrix

`CatalogDeclared` rows depend on the model's catalog entry; everything the
gateway does by translation is `GatewayLevel` at best and never assumed to
preserve cache-control or thinking-signature semantics.

| Feature | Native Messages | Native Responses | Native Chat | Translated |
|---|---|---|---|---|
| Tool calls | ProtocolNative | ProtocolNative | ProtocolNative | GatewayLevel |
| Streaming | ProtocolNative | ProtocolNative | ProtocolNative | GatewayLevel |
| Images | CatalogDeclared | CatalogDeclared | CatalogDeclared | CatalogDeclared / Unknown |
| Reasoning output | CatalogDeclared | CatalogDeclared | CatalogDeclared | CatalogDeclared / Unknown |
| Signed thinking replay | ProtocolNative | Unknown | Unknown | GatewayLevel / Unknown |
| Reasoning effort | CatalogDeclared | CatalogDeclared | CatalogDeclared | CatalogDeclared / Unknown |
| Native prompt caching | ProtocolNative | Unknown | Unknown | Unknown |
| Token usage integrity | ProtocolNative | ProtocolNative | ProtocolNative | GatewayLevel |
| Cancellation | ProtocolNative | ProtocolNative | ProtocolNative | GatewayLevel |

## Deliberately not implemented yet

This is still a **control-plane foundation**, not a functioning Posoco
`ModelPort`. No inference, streaming, session affinity, active route
observability, quota telemetry, or usage reporting is implemented here. Do
not present a successful catalog refresh or a `Planned` outcome as proof
that a model is available for inference.

The follow-up executes the three protocols against the resulting typed plan,
integrating the existing `posoco-kit-messages`, `posoco-kit-responses`, and
`posoco/kit-chat-completions` according to Magpie's `native_endpoints`,
while preserving model/group identity and keeping translation risk visible.
Execution consumes the plan; it must not reimplement protocol selection.

## Catalog limitations

The parser preserves each raw Magpie JSON entry verbatim, including
`magpie_label`, `native_endpoints`, `context_length`, `max_input_tokens`,
`max_output_tokens` and future extension fields; the typed
`MagpieModelMetadata` projection sits next to the conservative
`ManagerModelInfo` subset. Missing `native_endpoints` does not mean that the
gateway cannot translate requests to a given model — planning reports it as
`Unknown` and lets the translation policy decide.

Deterministic tests exercise synthetic representative catalog rows for every
planning case, plus the complete real `/v1/models` response captured from
the local gateway as a frozen structural fixture: its assertions derive from
the fixture itself (decode, order, verbatim efforts, group identity, typed
endpoints, raw retention) and hardcode no catalog size or contents, so they
hold for any gateway configuration, a single-model gateway included. No test
touches a running gateway.

## Testing

From the workspace root, run `moon check --target native`,
`moon check --target js`, `moon check --target wasm`,
`moon test --target native -p colmugx/posoco-ext-magpie`, and `moon info`.
