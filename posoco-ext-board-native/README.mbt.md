# posoco-ext-board-native

Native-only MoonBack standalone presentation for `posoco-ext-board`.

- `BoardBackend` remains a transport-free, native/JS headless service.
- `BoardRuntime` owns optional presentation composition and its Supervisor.
- `NativeBoardWebServer` uses MoonBack 0.8.6 for routing, WebSocket upgrades,
  connection lifecycle, graceful shutdown and in-memory static assets.
- `posoco-ext-board-web` supplies the embedded Rabbita task dashboard; task,
  dependency, manual attempt lifecycle and explicit review decision intents use
  the existing authenticated WebSocket commands. Recording Approved or
  ChangesRequested is separate from finishing an attempt or moving a task;
  none of these controls executes an Agent.
- `NativeBrowserOpener` remains a separate standalone UX adapter.

This is a separate module because MoonBack 0.8.6 is not JS-compatible and the
MoonBit package dependency graph does not isolate imports by source-file target.
Embedded SvelteKit or Proton-style desktop hosts consume Board's headless/wire
contract through their own adapters. They neither import this module or Rabbita
nor embed the standalone page in an iframe.

## Native host composition

Import `colmugx/posoco-ext-board-native` as `@board_native`:

```mbt nocheck
let board = @board_native.board_extension()
@async.with_task_group(group => {
  board.attach(group)
  // /board lazily starts the localhost host and opens the dashboard.
  // Run the existing host loop here.
  board.runtime().shutdown()
})
```

The factory composes the existing Board extension with FileBoardStore,
Unix-epoch clock, MoonBack localhost server and native opener. Custom adapters
can use `@runtime.BoardRuntime::with_adapters(backend~, server~, opener~)`.

`set_backend` is required and occurs before bind. A missing backend fails before
listening. Binding fixes one authoritative backend; replacement while bound or
running is ignored. After close and worker settlement a server may bind again.

## Security and transport

The listener uses only `127.0.0.1:0` and a fresh OS-entropy 256-bit hex token per
bind. Every request must have the exact endpoint Host; WebSocket requests with
an Origin must match the exact endpoint origin.

`/`, `/index.html`, `/api/bootstrap` and `/ws` require the instance token.
`/health` and actual embedded asset paths other than the root document are
public behind the Host gate, so the page can load `/index.js` and `/board.css`
without copying its capability token into subresource URLs. File extensions do
not grant access. Unknown paths require a token, then fall through to 404; no
SPA history fallback is enabled. Responses retain `no-store` and `nosniff`.
Endpoint/status/bootstrap metadata and embedded files never contain the token.

The handwritten diagnostics client and its dedicated browser harness have been
removed. Client replica and Rabbita update tests, native static/security tests,
and existing native WebSocket tests cover their protocol responsibilities.
Board still owns Hello/text/frame/version gates, snapshots/replay, bounded
mailboxes and durable commands.

MoonBack owns connection tasks and listener teardown within the runtime worker.
Its stop timeout is 1 second, below BoardRuntime's 5-second settle bound.
`board.close` closes active sockets and subscriptions, not BoardBackend;
headless mutations remain usable and reopen snapshots show their committed state.

## Build embedded assets

From the extension workspace:

```bash
moon -C posoco-ext-board-native --target-dir _build/assets-builder run tools/embed-assets/build.mbtx --target native --output-json
moon -C posoco-ext-board-native run tools/embed-assets/generate.mbtx --target native --output-json -- _build/browser-assets-dist --check
```

The builder compiles the existing browser entry directly with Moon, copies public
resources, and embeds the result. It needs neither Warren nor Node/Bun. Nested
compiler and generator invocations use separate build directories rather than
the caller's workspace build lock.

Generated resources are build products, not Git source. The module's `.gitignore`
excludes `src/web_assets.generated.mbt`; `.moonignore` includes it in release
archives so downstream dependencies need no browser build or executable hook.
The package's development rule generates missing resources before native checks,
builds and tests. Package authors must build resources before packaging; inspect
`moon package --list` to verify the generated module is included.

The generator includes hidden and nested regular files, rejects symlinks/special
files and control-plane paths, sorts URL paths, and preserves raw bytes using
bounded literals instead of giant decimal arrays. It atomically replaces the
output; `--check` is read-only and fails on stale or missing output. Optional
positional arguments select input/output paths relative to the native module.
Required HTML, JS and CSS must be nonempty. MoonBack serves assets from memory,
without a runtime filesystem directory, base64 decoding or temporary files.

Generator regression checks (including compiled byte round trips):

```bash
moon -C posoco-ext-board-native run tools/embed-assets/check_generator.mbtx --target native --output-json
```

The embedded dashboard includes manual attempt lifecycle and one-shot review
decision controls. Review decisions are eligible only for Running Review attempts
with a Pending decision, and are observed through authoritative events rather
than optimistic UI updates. Finishing a Pending Review warns that its decision
can no longer be recorded afterwards. No native transport, authentication or
backend semantics change; there are no new HTTP mutation routes, Cetas
integration, Agent execution, scheduling or workflow dependencies.
