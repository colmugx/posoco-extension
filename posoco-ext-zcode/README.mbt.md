# posoco-ext-zcode

Ports contributed (via `ZcodeExt`):

| Port | Face |
|---|---|
| `ToolProvider` | one `zcode` tool — delegate a task to the local [ZCode](https://zcode.z.ai) CLI |
| `Extension` | manifest id `posoco_ext_zcode` |

## What it does

The `zcode` tool hands a task to a freshly spawned `zcode app-server --stdio`
process (one process per task; session continuity via `session_id` +
`session/resume`), streams its `session/event` notifications, and returns the
final `turn.completed.response` as the tool result.

Wire behavior (live-verified against zcode 0.16.5; see the posoco repo's
`docs/zcode-ext-implementation.md` and `docs/fixtures/zcode-appserver-*`):

- **Provider registry bootstrap**: providers are read from
  `~/.zcode/v2/config.json` and pushed via `workspace/updateProviderRegistry`
  before `session/create` — the app-server does not load them itself. Each
  provider's `apiKey` travels as the inline union
  `{"source":"inline","value":…}`; providers with zero models or no key are
  skipped (the server rejects keyless inline entries and defaults to
  `providers[0]`).
- **Server reverse-requests are answered, not bridged**:
  `session/requestRuntimePreferences` gets the minimal fixed answer,
  `interaction/requestOfficialMcpAuthHeaders` an empty result, and
  **`interaction/requestPermission` / `interaction/requestUserInput` are always
  denied** — this extension never auto-approves anything. A denied ask is
  summarized into the tool result (`stop_reason: permission_denied`) so the
  caller can retry differently or surface it to a human.
- **Timeout** defaults to 30 minutes (`ZcodeConfig.timeout_ms`); the child is
  reaped via graceful cancel (SIGTERM → 5s → SIGKILL).

Tool arguments: `task` (required), `cwd` (default: current dir),
`session_id` (continue a previous delegation), `mode`
(`build|edit|plan|yolo`, default `edit`).

## Usage

```bash
moon add colmugx/posoco-ext-zcode
```

```moonbit nocheck
let agent = Agent(
  exts=[
    tk_ext(id="model", model=Some(model)),
    zcode_ext(), // contributes the `zcode` ToolProvider
  ],
  config=tk_config(),
)
```

## Configuration

- `ZcodeTools`/`ZcodeExt` constructors accept `ZcodeConfig` (bin / node /
  creds_path overrides, `default_mode`, `timeout_ms`).
- Binary discovery: `ZCODE_BIN` → `zcode` on `PATH` → the ZCode desktop-app
  bundle (`/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs` on
  macOS; `.cjs` entries run through `node`, overridable via `ZCODE_NODE`).
- Credentials path override: `ZCODE_CREDS`.
- Live wire test (makes one real GLM call, ~30k input tokens):
  `ZCODE_EXT_LIVE=1 moon test src --target native`.

## Provenance

Protocol facts reverse-engineered and live-probed from zcode 0.16.5 (the
app-server protocol is an undocumented internal contract); the regression
guard is the env-gated live test above — re-run it after upgrading zcode.
Design and evidence live in the posoco repository:
`docs/cetas-zcode-design.md`, `docs/zcode-ext-implementation.md`,
`docs/zcode/round1-plan.md`.
