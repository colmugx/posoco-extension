# posoco-ext-credentials

Provider-credential persistence for Posoco hosts.

- **Storage boundary**: `@oauth.ProviderCredentialStore` (from
  `posoco-ext-oauth`). This package does not invent a new storage trait —
  OS secret-manager backends (Keychain, Secret Service, …) plug in through
  the same trait later.
- **Backend-neutral codec** (`record.mbt`): every backend persists the same
  tagged JSON record; `encode_provider_credential` /
  `parse_provider_credential(_text)` are the single source of truth for the
  durable shape. Malformed records are typed errors, never silent fallbacks.
- **File backend** (`file_store.mbt`): `FileProviderCredentialStore` stores
  one tagged record per provider below a host-injected directory, on top of
  the `WorkspaceFs` boundary (`posoco-ext-workspace`) — no target-specific IO
  of its own, so native and js hosts share it. Writes are atomic
  (temp-file + rename, owner-only permissions).

```mbt nocheck
let store = @credentials.FileProviderCredentialStore(
  @workspace.NativeWorkspaceFs(),
  "/path/to/credentials",
)
```
