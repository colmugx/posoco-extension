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
- Binary discovery (order below; the first existing candidate wins; `.cjs` /
  `.mjs` / `.js` entries run through `node`, overridable via `ZCODE_NODE`).
  `ZCODE_BIN` (and `config.bin`) is trusted without any probe. There is no
  compile-time platform switch — env is injected, so a host simply misses the
  candidates that do not apply:

  | # | Tier | Candidates |
  |---|---|---|
  | 1 | `config.bin` | trusted as-is, no probe |
  | 2 | `ZCODE_BIN` | trusted as-is, no probe |
  | 3 | `PATH` | unix: `<entry>/zcode` per `:`-separated entry; Windows (env `OS=Windows_NT` or `ProgramFiles` set): `<entry>\zcode`, `<entry>\zcode.exe`, `<entry>\zcode.cmd` per `;`-separated entry |
  | 4 | Linux `.desktop` (skipped on Windows-shaped env) | scan `$HOME/.local/share/applications` first, then each `XDG_DATA_DIRS` entry (default `/usr/local/share:/usr/share`); read `*zcode*.desktop` / `*ZCode*.desktop` files, take their `Exec=` token and probe its siblings: `<dir>/zcode.cjs`, `<dir>/../resources/glm/zcode.cjs`, `<dir>/resources/glm/zcode.cjs` |
  | 5 | Symlink (unix, skipped on Windows-shaped env) | for each PATH entry, the readlink-resolved `zcode`'s siblings (same sibling set as tier 4) |
  | 6 | darwin bundles | `/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs`, `<HOME|USERPROFILE>/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs` |
  | 7 | Windows bundles | `<LOCALAPPDATA ?? <home>\AppData\Local>\Programs\ZCode\resources\glm\zcode.cjs`, `<ProgramFiles>\ZCode\resources\glm\zcode.cjs`, `<ProgramFiles(x86)>\ZCode\resources\glm\zcode.cjs` (each only when its env root is set) |
  | 8 | Linux bundles | `/opt/ZCode/resources/glm/zcode.cjs`, `/usr/share/zcode/resources/glm/zcode.cjs`, `<ZCODE_INSTALL_DIR>/resources/glm/zcode.cjs` |

  A PATH-entry hit (`…/zcode`, or a Windows `zcode`/`zcode.exe`/`zcode.cmd`
  shim) spawns as its bare/probed command; only the desktop-tiers' `.cjs`
  siblings and the fixed `.cjs` bundles get the node interpreter prefix.
  The enumeration is IO-free and public (`zcode_candidate_paths` for the
  static tiers, `zcode_probe_paths` with injected read/list/realpath for the
  full list), so hosts can probe the paths through their own filesystem port.
  Known limits: Windows `reg query` uninstall-string lookup is a possible
  future tier (the Program Files candidates above cover standard installs);
  AppImage installs cannot be discovered statically — set `ZCODE_BIN`.
- Credentials path override: `ZCODE_CREDS`; the default is
  `<HOME|USERPROFILE>/.zcode/v2/config.json`.
- Live wire test (makes one real GLM call, ~30k input tokens):
  `ZCODE_EXT_LIVE=1 moon test src --target native`.

## Provenance

Protocol facts reverse-engineered and live-probed from zcode 0.16.5 (the
app-server protocol is an undocumented internal contract); the regression
guard is the env-gated live test above — re-run it after upgrading zcode.
Design and evidence live in the posoco repository:
`docs/cetas-zcode-design.md`, `docs/zcode-ext-implementation.md`,
`docs/zcode/round1-plan.md`.
