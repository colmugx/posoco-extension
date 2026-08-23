///|
/// Flusher poll interval (upstream THREAD_SYNC_DEBOUNCE_MS = 750; plan D3
/// turns the debounce into a polling loop).
const NMEM_FLUSHER_INTERVAL_MS : Int = 750

///|
/// The Nowledge Mem agent extension — one struct, many port views:
///
/// - `Lifecycle` — `on_start` resolves the config (env + home config file
///   through the runner), reads the startup context degradation chain, and
///   warms the system-prompt cache; `on_shutdown` stops the flusher and
///   performs the final drain;
/// - `Hook` — `before_model` passthrough that snapshots the model-visible
///   transcript (D2: what the model sees is what syncs);
/// - `Observer` — records the current session from the `TurnStarted` scope,
///   completes the snapshot with each committed assistant reply, marks the
///   lane dirty on `TurnCompleted` / `TurnFailed` (D3: the observer slot
///   is synchronous, so it only stages work), and follows
///   `SessionRedirect` by staging the old session's snapshot and switching
///   to the new session id;
/// - `SystemPromptContributor` — the cached context bundle plus the startup
///   guidance;
/// - `ToolProvider` — the §5 tool set over the `nmem` CLI (the official MCP
///   names read_context_bundle / read_working_memory / memory_search /
///   thread_search / memory_add plus posoco-native additions;
///   memory_search goes straight to the server; memory_add enters through
///   MemoryPort's single write path);
/// - `MemoryPort` — the D8 passive surface: synchronous local-copy
///   store/search/delete whose writes drain to the CLI after the thread
///   lanes;
/// - `CommandPort` — `/memory status|flush|refresh`, the user-facing
///   diagnostics over the same state (lane last_errors, queue depth,
///   index size, connectivity).
///
/// The background flusher is deliberately NOT spawned from `on_start`:
/// `moonbitlang/async` has no detached spawn — every task lives in a
/// host-owned `TaskGroup`. Hosts call `attach` inside their `with_task_group`
/// scope (mcp / ratelimit precedent); `flush_pending` serves hosts and tests
/// that prefer explicit draining.
pub struct NowledgeMem {
  mut config : NmemConfig?
  mut startup : StartupContext
  /// Latest model-visible transcript snapshot (before_model) completed with
  /// the committed assistant replies; the unit the sync engine flushes.
  mut transcript : Array[@posoco.Message]
  mut current_session : String?
  engine : SyncEngine
  transport : &NmemTransport
  runner : &NmemRunner
  mut prompt_cache : String
  mut timeout_ms : Int
  /// Host product identity: prefixes synced thread ids, scopes the CLI
  /// `--source-app` reads, and labels user-visible copy. The extension is a
  /// reusable library, so this comes from the constructor — never hardcoded.
  source_app : String
  /// Local memory copy + write-after queue (D8); the MemoryPort slots read
  /// and append synchronously, the drain replays against the CLI.
  mem : MemoryState
  /// Whether `memory_delete` appears in the tool surface. Deleting is a
  /// destructive remote operation, so the model only sees it when the host
  /// opts in.
  expose_delete_tool : Bool
}

///|
/// Build a Nowledge Mem extension over an injected transport (thread sync
/// HTTP) and runner (nmem CLI + home-file access). `source_app~` is the host
/// product identity (e.g. cetas passes `"cetas"`): it prefixes synced thread
/// ids and labels user-visible copy, and `NMEM_PLUGIN_SOURCE_APP` can still
/// override it. Production hosts pass `HttpNmemTransport` and `PlatformRunner`;
/// tests script both seams.
///
/// # Example
/// ```mbt check
/// test "nowledge mem exposes guidance before on_start" {
///   let ext = NowledgeMem::new(
///     source_app="cetas",
///     transport=HttpNmemTransport::HttpNmemTransport() as &NmemTransport,
///     runner=PlatformRunner::PlatformRunner() as &NmemRunner,
///   )
///   assert_true(ext.system_prompt().contains("## Nowledge Mem Guidance"))
///   assert_true(ext.system_prompt().contains("Cetas"))
///   assert_false(ext.system_prompt().contains("Context Bundle"))
/// }
/// ```
pub fn NowledgeMem::new(
  source_app~ : String,
  transport~ : &NmemTransport,
  runner~ : &NmemRunner,
  expose_delete_tool? : Bool = false,
) -> NowledgeMem {
  {
    config: None,
    startup: { context: None, degraded_reason: None },
    transcript: [],
    current_session: None,
    engine: SyncEngine::new(),
    transport,
    runner,
    prompt_cache: "",
    timeout_ms: DEFAULT_THREAD_SYNC_TIMEOUT_MS,
    mem: MemoryState::MemoryState(),
    source_app,
    expose_delete_tool,
  }
}

///|
/// Agent boot (inside the first `run_turn`): resolve config and sync
/// timeout, run the startup-context degradation chain, cache the prompt
/// sections, pull the server memories into the local index (D8 passive-read
/// warm-up), then drain once — a host that staged state before boot loses
/// nothing, and one that never calls `attach` still gets boundary syncs via
/// the next `flush_pending`.
pub impl @posoco.Lifecycle for NowledgeMem with fn on_start(self : NowledgeMem) -> Unit {
  let config = NmemConfig::resolve(
    runner_get_env,
    NmemRunner::read_home_file(self.runner, ".nowledge-mem/config.json"),
    source_app=self.source_app,
  )
  self.config = Some(config)
  self.timeout_ms = resolve_thread_sync_timeout_ms(
    runner_get_env("NMEM_SYNC_TIMEOUT_MS"),
  )
  self.startup = read_startup_context(self.runner, config)
  self.prompt_cache = assemble_prompt_sections(self.startup, config.source_app)
  self.refresh_memory_index()
  self.engine.drain_once(self.transport, timeout_ms=self.timeout_ms)
}

///|
/// Agent shutdown: stop the flusher loop, then flush whatever the last turns
/// staged — the boundary flush upstream performs on session close — including
/// any memory writes still queued (D8 final drain).
pub impl @posoco.Lifecycle for NowledgeMem with fn on_shutdown(
  self : NowledgeMem,
) -> Unit {
  self.engine.stop()
  self.engine.drain_once(self.transport, timeout_ms=self.timeout_ms)
  self.drain_memory_ops()
}

///|
/// Hand the extension the host's long-lived task group and start the flusher
/// loop on it (750ms poll — the debounce made structural). Call inside the
/// host's `with_task_group` scope; the loop runs until `on_shutdown` stops
/// the engine, so the group must stay open for the agent's lifetime.
pub fn[G] NowledgeMem::attach(
  self : NowledgeMem,
  group : @async.TaskGroup[G],
) -> Unit {
  group.spawn_bg(() => self.run_flusher())
}

///|
/// The flusher loop body; also directly runnable for hosts that own their
/// own scheduling loop. Each tick drains the thread lanes first, then the
/// memory write-after queue (D8: one loop, two channels).
pub async fn NowledgeMem::run_flusher(self : NowledgeMem) -> Unit {
  while !self.engine.stopped {
    self.engine.drain_once(self.transport, timeout_ms=self.timeout_ms)
    self.drain_memory_ops()
    @async.sleep(NMEM_FLUSHER_INTERVAL_MS) catch {
      _ => ()
    }
  }
}

///|
/// Force one drain of every dirty lane and every queued memory op now (test
/// hook and host escape hatch for "flush before I inspect").
pub async fn NowledgeMem::flush_pending(self : NowledgeMem) -> Unit {
  self.engine.drain_once(self.transport, timeout_ms=self.timeout_ms)
  self.drain_memory_ops()
}

///|
/// Passthrough that snapshots the model-visible transcript (D2). The final
/// assistant reply of a turn is never model-visible — the pump terminates
/// after it — so `record_assistant` completes the snapshot from
/// `ModelResponseReceived` events; without it every sync would lag one
/// assistant message behind.
pub impl @posoco.Hook for NowledgeMem with fn before_model(
  self : NowledgeMem,
  messages : Array[@posoco.Message],
) -> Array[@posoco.Message] {
  self.transcript = messages.copy()
  messages
}

///|
fn NowledgeMem::record_assistant(
  self : NowledgeMem,
  message : @posoco.Message,
) -> Unit {
  match message {
    @posoco.Message::AssistantMessage(..) => {
      let last = self.transcript.length() - 1
      if last < 0 || self.transcript[last] != message {
        self.transcript.push(message)
      }
    }
    _ => ()
  }
}

///|
/// Stage the current transcript as the lane's pending flush (D3: synchronous
/// observer slot — marking dirty only). A snapshot without a user/assistant
/// pair never enters the queue (shouldSync gate inside build_sync_request).
fn NowledgeMem::stage_turn_sync(self : NowledgeMem, reason : String) -> Unit {
  match self.current_session {
    Some(session_id) => self.stage_session_sync(session_id, reason)
    None => ()
  }
}

///|
/// Stage the current transcript under an explicit session id — the
/// SessionRedirect path stages the snapshot under the OLD id (the snapshot
/// may belong to the redirecting session; staging is best-effort, the
/// flusher does the rest).
fn NowledgeMem::stage_session_sync(
  self : NowledgeMem,
  session_id : String,
  reason : String,
) -> Unit {
  match self.config {
    Some(config) =>
      match
        build_sync_request(
          self.transcript,
          session_id~,
          config~,
          sync_reason=reason,
        ) {
        Some(request) => self.engine.mark_dirty(request)
        None => ()
      }
    None => ()
  }
}

///|
pub impl @posoco.Observer for NowledgeMem with fn on_event_at(
  self : NowledgeMem,
  scope : @posoco.EventScope?,
  event : @posoco.TurnEvent,
) -> Unit {
  match event {
    @posoco.TurnEvent::TurnStarted =>
      match scope {
        Some(scope) => self.current_session = Some(scope.session_id.to_string())
        None => ()
      }
    @posoco.TurnEvent::ModelResponseReceived(message~, ..) =>
      self.record_assistant(message)
    @posoco.TurnEvent::SessionRedirect(from~, to~, ..) => {
      // The snapshot may belong to the old session, so stage it under the
      // old id (best effort — the observer slot cannot flush), then follow
      // the redirect: subsequent turns sync into the new session's lane.
      self.stage_session_sync(from, "session_redirect")
      self.current_session = Some(to)
    }
    @posoco.TurnEvent::TurnCompleted => self.stage_turn_sync("turn_completed")
    @posoco.TurnEvent::TurnFailed(_) => self.stage_turn_sync("turn_failed")
    _ => ()
  }
}

///|
/// Cached `on_start` result. Before boot (or when the host never runs turns)
/// the fallback is pure guidance with no context section — an empty string
/// would drop the guidance entirely, and un-booted must not mean un-guided.
pub impl @posoco.SystemPromptContributor for NowledgeMem with fn system_prompt(
  self : NowledgeMem,
) -> String {
  if self.prompt_cache != "" {
    self.prompt_cache
  } else {
    assemble_prompt_sections(
      { context: None, degraded_reason: None },
      self.source_app,
    )
  }
}

///|
pub impl @posoco.Extension for NowledgeMem with fn extension_id(
  _self : NowledgeMem,
) -> String {
  NMEM_EXTENSION_ID
}

///|
/// Ports the extension contributes: Hook (transcript snapshot), Observer
/// (dirty marking + session-redirect follow), Lifecycle (boot + final
/// drain), SystemPromptContributor (context bundle + guidance),
/// ToolProvider (§5 tool set), MemoryPort (D8 local copy + write-after
/// queue — declaring it here is what wires core's MemoryRetrievalHook), and
/// CommandPort (`/memory` diagnostics: status / flush / refresh) — all
/// views of one state.
pub impl @posoco.Extension for NowledgeMem with fn manifest(self : NowledgeMem) -> @posoco.ExtensionManifest {
  {
    id: NMEM_EXTENSION_ID,
    models: [],
    tools: [self],
    sessions: [],
    observers: [self],
    hooks: [self],
    memory: [self],
    lifecycle: [self],
    commands: [self],
    ui: [],
    prompt_contributors: [self],
    requires: [],
  }
}

///|
pub extend NowledgeMem with @posoco.Extension::{extension_id, manifest}

///|
pub extend NowledgeMem with @posoco.SystemPromptContributor::{system_prompt}
