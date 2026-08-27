# posoco-ext-llm

`posoco-ext-llm` is a provider-agnostic model router. It does not construct
HTTP adapters and it does not depend on DeepSeek, Kimi, or OpenAI. Provider
extensions construct their own `ProviderModelCatalog` values; the host only
assembles those catalogs.

```moonbit
let provider = make_provider_port()
let catalog = provider.model_catalog()
let router = @llm.RouterModelPort::from_catalogs(catalogs=[catalog])
```

`RouterModelPort` delegates `ModelPort` calls to the active slot. Provider
catalogs advertise effort choices and provide a rebuild hook, so
`/model {slot, effort}` validates and applies effort without the host knowing
provider request fields.

The router also declares two commands:

- `/model [slot]` lists the slot catalog or switches the active slot.
- `/model {slot, effort}` additionally selects a provider-advertised effort.
- `/login [provider]` lists provider authentication capabilities or runs the
  selected injected provider login flow. Use
  `/login {provider: "kimi", method: "oauth"}` or
  `/login {provider: "deepseek", method: "api_key"}`.

Authentication is explicit and provider-neutral. OAuth uses a
`CredentialStore`, an `AuthInteraction`, an `OAuthProvider` on the slot, and,
when credentials change adapter configuration, a `rebuild_on_credential`
factory. API-key login uses an `ApiKeyStore`, an `AuthPromptInteraction`, an
`ApiKeyFactory`, and `rebuild_on_api_key`. The router persists credentials and
replaces every matching slot that declares the corresponding factory. Missing
dependencies fail as `CommandError::ExecutionFailed`; no silent fallback is
used. API-key secrets are never included in diagnostic text.

Provider adapters and catalogs live in separate extensions such as
`posoco-ext-openai`, `posoco-ext-deepseek`, and `posoco-ext-kimi`. Kimi's
catalog intentionally advertises chat/streaming/reasoning only; it has no FIM
capability.

Providers with authenticated model discovery may additionally implement the
optional async `RefreshableProviderFactory` seam. Hosts invoke it explicitly
(for example at startup or immediately after login); normal catalog composition
remains a pure snapshot build and `/model` never performs an implicit network
refresh. A refresh failure is typed and observable rather than hidden behind a
stale/static fallback.
