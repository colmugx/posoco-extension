# posoco-ext-board-native

Native-only MoonBack standalone presentation for `posoco-ext-board`.

- `BoardBackend` remains a transport-free, native/JS headless service.
- `BoardRuntime` owns optional presentation composition and its Supervisor.
- `NativeBoardWebServer` uses MoonBack 0.8.6 for routing, query parsing,
  response helpers, WebSocket upgrades, connection ownership and shutdown.
- `NativeBrowserOpener` remains a separate standalone UX adapter.

This is a separate module because MoonBack 0.8.6 is not JS-compatible and the
MoonBit package dependency graph does not isolate imports by source-file target.
Embedded web/desktop hosts use `colmugx/posoco-ext-board/backend` directly and
need neither this module nor a browser opener.

## Native host composition

Import `colmugx/posoco-ext-board-native` as `@board_native`:

```mbt nocheck
let board = @board_native.board_extension()
@async.with_task_group(group => {
  board.attach(group)
  // /board lazily starts the localhost host and opens diagnostics.
  // Run the existing host loop here.
  board.runtime().shutdown()
})
```

The factory composes the existing Board extension with FileBoardStore,
Unix-epoch clock, MoonBack localhost server and native opener. Custom adapters
can still use `@runtime.BoardRuntime::with_adapters(backend~, server~, opener~)`.
Native callers of the former `@runtime.NativeBoardWebServer` and
`@runtime.NativeBrowserOpener` should import those types from this module.

`set_backend` is required by the server contract and occurs before bind. A
missing backend fails before listening. Binding fixes one authoritative backend;
replacement while bound/running is ignored. After close and worker settlement,
a stopped server may accept a backend and bind again.

The listener uses only `127.0.0.1:0`, a fresh OS-entropy 256-bit hex token per
bind, exact Host and optional exact Origin gates. GET routes are `/`, `/health`,
`/api/bootstrap`, `/ws`; only health is token-free. Responses remain `no-store`
and `nosniff`, endpoint/status/bootstrap metadata never reveal the token, and
the diagnostics HTML is unchanged. Board owns Hello/text/frame/version gates,
authoritative snapshot/replay, bounded mailboxes and durable commands.

MoonBack owns connection tasks and listener teardown within the runtime worker.
Its explicit stop timeout is 1 second, below BoardRuntime's 5-second settle
bound. `board.close` closes active sockets and subscriptions, not BoardBackend;
headless mutations remain usable and reopen snapshots show their committed state.

No MoonBack DI, unstable static middleware, Rabbita/Warren, Cetas integration,
Agent execution, scheduling or workflow dependency is introduced.
