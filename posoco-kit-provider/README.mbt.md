# posoco-kit-provider

Canonical ownership of the reusable **Native Provider contracts**: the
provider-side construction seam shared by every Model Manager. Provider
extensions implement these contracts to build `ProviderModelCatalog` values;
Model Managers consume those catalogs without owning the contracts.

## Architectural boundary

- **This kit** owns `ProviderFactory`, `RefreshableProviderFactory`,
  `OAuthFactory`, `ApiKeyFactory`, `ProviderConfigSource`,
  `ProviderBuildResult`, `ModelSlot`, `ProviderModelCatalog`, and
  `AuthMethod` — plus the slot-level context-window helpers
  (`context_window_integer`, `cached_provider_context_window`,
  `with_cached_context_windows`). It depends only on `colmugx/posoco` (typed
  composition errors) and `posoco/ext-oauth` (credential types). It does not
  depend on `posoco/ext-llm`, on any concrete Provider extension, or on any
  host.
- **`posoco-ext-llm`** remains the local Model Manager: it consumes catalogs
  built against these contracts and re-exports the names under `@llm` as
  public type aliases, so existing consumers keep compiling against the same
  types (aliasing preserves type identity — there is no parallel
  representation).
- **A future `posoco-ext-magpie`** can consume Native Provider catalogs by
  depending on this kit alone.
- **`posoco-kit-model-management`** stays zero-dependency and independent of
  this kit; manager control and provider construction are separate seams.

## Canonical ownership

| Declaration | Owner before | Owner now |
|---|---|---|
| `ProviderFactory` / `RefreshableProviderFactory` | posoco-ext-llm | posoco-kit-provider |
| `OAuthFactory` / `ApiKeyFactory` / `AuthMethod` | posoco-ext-llm | posoco-kit-provider |
| `ProviderConfigSource` / `ProviderBuildResult` | posoco-ext-llm | posoco-kit-provider |
| `ModelSlot` / `ProviderModelCatalog` | posoco-ext-llm | posoco-kit-provider |
| slot-level context-window helpers | posoco-ext-llm | posoco-kit-provider |
| `RouterModelPort`, commands, quota/status, model metadata lookup | posoco-ext-llm | posoco-ext-llm (unchanged) |

Compatibility notes:

- Validation semantics are preserved verbatim, including the diagnostic
  `manifest_id` strings (e.g. `"posoco_ext_llm.credentials"` in
  `effective_credential`): they are observable error payloads, and renaming
  them would be a behavior change for existing hosts.
- `ModelSlot` keeps its provider-owned `rebuild_on_effort` /
  `rebuild_on_credential` / `rebuild_on_api_key` hooks and offline
  cached-window restoration unchanged.
- `ModelSlot` gained a `kind` field (`Chat` default / `Decision`) and a
  `decision_port` field. A provider labels a slot `Decision` only when its
  own extension serves the `DecisionPort` for it; the catalog constructor
  rejects a decision slot without its port and a chat slot carrying one, so
  the `/model` and `/decision` selections can never blur into each other.
