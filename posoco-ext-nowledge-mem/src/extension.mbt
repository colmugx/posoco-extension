///|
/// Flusher poll interval (upstream THREAD_SYNC_DEBOUNCE_MS = 750; plan D3
/// turns the debounce into a polling loop).
const NMEM_FLUSHER_INTERVAL_MS : Int = 750

///|
/// Minimum spacing between mid-turn drains (ms): `before_tool` drains only
/// shrink the crash window, so they run at the flusher's cadence, not per
/// tool call.
const NMEM_BEFORE_TOOL_DRAIN_INTERVAL_MS : Int64 = 750L

///|
/// The Nowledge Mem agent extension — one struct, many port views:
///
/// - `Lifecycle` — `on_start` resolves the config (env + home config file
///   through the runner) and drains once; `on_shutdown` stops the flusher
///   and performs the final drain;
/// - `PipelineHook` — `before_model` passthrough that snapshots the
///   model-visible transcript (D2: what the model sees is what syncs);
///   `before_tool` drains under a 750ms throttle; `on_turn_end` is the
///   load-bearing commit boundary;
/// - `Observer` — records the current session from the `TurnStarted` scope,
///   completes the snapshot with each committed assistant reply, marks the
///   lane dirty on `TurnCompleted` / `TurnFailed`, and follows
///   `SessionRedirect` by staging the old session's snapshot and switching
///   to the new session id;
/// - `SystemPromptContributor` — instructions only: what the plugin is,
///   when to search, when to save, routing, provenance. Recalled DATA
///   never travels here — the working-memory briefing arrives through the
///   `MemoryPort` section (core's `MemoryRetrievalHook`) at the session's
///   first turn, and the model re-reads deliberately via the tools;
/// - `ToolProvider` — the §5 tool set over the `nmem` CLI (the official MCP
///   names read_context_bundle / read_working_memory / memory_search /
///   thread_search / memory_add plus posoco-native additions);
/// - `MemoryPort` — the D9 passive surface: a one-shot gated working-memory
///   read (`wm read`) plus the store/delete write-after queue whose writes
///   drain to the CLI after the thread lanes;
/// - `CommandPort` — `/memory status|flush`, the user-facing diagnostics
///   over the same state (lane last_errors, queue depth, passive-read
///   gate, connectivity).
///
/// The background flusher is deliberately NOT spawned from `on_start`:
/// `moonbitlang/async` has no detached spawn — every task lives in a
/// host-owned `TaskGroup`. Hosts may call `attach` inside their
/// `with_task_group` scope (mcp / ratelimit precedent); `flush_pending`
/// serves hosts and tests that prefer explicit draining.
pub struct NowledgeMem {
  mut config : NmemConfig?
  /// Latest model-visible transcript snapshot (before_model) completed with
  /// the committed assistant replies; the unit the sync engine flushes.
  mut transcript : Array[@posoco.Message]
  mut current_session : String?
  engine : SyncEngine
  transport : &NmemTransport
  runner : &NmemRunner
  mut timeout_ms : Int
  /// Wall-clock ms (`@async.now`, Int64) of the last drain — start, turn
  /// end, or a `before_tool` throttle hit — gating the mid-turn drain
  /// cadence.
  mut last_drain_ms : Int64
  /// Host product identity: prefixes synced thread ids, scopes the CLI
  /// `--source-app` reads, and labels user-visible copy. The extension is a
  /// reusable library, so this comes from the constructor — never hardcoded.
  source_app : String
  /// Local memory write-after queue (D8); the MemoryPort store/delete slots
  /// append synchronously, the drain replays against the CLI. The server is
  /// the single read source — there is no local index.
  mem : MemoryState
  /// One-shot passive read gate (D9/M10): `false` until the first
  /// `MemoryPort::search` of this process run attempts the working-memory
  /// read; every later search returns empty without IO.
  mut passive_read_done : Bool
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
///   let ext = NowledgeMem::NowledgeMem(
///     source_app="cetas",
///     transport=HttpNmemTransport::HttpNmemTransport() as &NmemTransport,
///     runner=PlatformRunner::PlatformRunner() as &NmemRunner,
///   )
///   assert_true(ext.system_prompt().contains("## Nowledge Mem Guidance"))
///   assert_true(ext.system_prompt().contains("Cetas"))
///   assert_false(ext.system_prompt().contains("Context Bundle"))
/// }
/// ```
pub fn NowledgeMem::NowledgeMem(
  source_app~ : String,
  transport~ : &NmemTransport,
  runner~ : &NmemRunner,
  expose_delete_tool? : Bool = false,
) -> NowledgeMem {
  {
    config: None,
    transcript: [],
    current_session: None,
    engine: SyncEngine(),
    transport,
    runner,
    timeout_ms: DEFAULT_THREAD_SYNC_TIMEOUT_MS,
    last_drain_ms: 0L,
    mem: MemoryState::MemoryState(),
    passive_read_done: false,
    source_app,
    expose_delete_tool,
  }
}

///|
/// Agent boot (inside the first `run_turn`): resolve config and sync
/// timeout, then drain once — a host that staged state before boot loses
/// nothing, and one that never calls `attach` still gets every boundary
/// committed at turn end. Passive retrieval stays gated: the first model
/// call's read (not boot) spends it. The system-prompt contribution is
/// static guidance and needs no IO here.
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
  self.engine.drain_once(self.transport, timeout_ms=self.timeout_ms)
  self.last_drain_ms = @async.now()
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
/// One bounded, silent drain of both write channels: thread lanes, then the
/// memory queue, under a single `with_timeout(self.timeout_ms)` budget. Every
/// failure — transport raises and timeout cancellation included — is recorded
/// on the lane/memory state instead of raising: the silent-retry philosophy is
/// unchanged (visibility goes through `/memory status`), and the core's
/// secondary-failure channel stays reserved for genuine defects. `on_turn_end`
/// and the throttled `before_tool` drain share this path. Lanes carry full
/// snapshots, so a dropped in-flight request just waits for the next staging.
async fn NowledgeMem::drain_silent(self : NowledgeMem) -> Unit noraise {
  if self.config is None {
    return
  }
  self.last_drain_ms = @async.now()
  @async.with_timeout(self.timeout_ms, () => {
    self.engine.drain_once(self.transport, timeout_ms=self.timeout_ms)
    self.drain_memory_ops()
  }) catch {
    error => {
      let message = "drain failed: " + error.to_string()
      let lane_keys : Array[String] = []
      for lane_key, _lane in self.engine.lanes {
        lane_keys.push(lane_key)
      }
      for lane_key in lane_keys {
        self.engine.lanes[lane_key] = {
          ..self.engine.lanes[lane_key],
          last_error: Some(message),
        }
      }
      if !self.mem.queue.is_empty() {
        self.mem.last_error = Some(message)
      }
    }
  }
}

///|
/// Turn-end commit (plan D3, 2026-08-23 revision): core awaits this slot once
/// per `run_turn`, after the terminal observer projection and before the call
/// returns — on both the completed and the failed path. Any path that stops a
/// turn commits first, so a host that never calls `attach` and never shuts
/// down still gets its staged transcripts and memory writes submitted; the
/// crash window narrows to the turn in progress. The observer slot already
/// staged the snapshot (`TurnCompleted`/`TurnFailed` fire first), so this is
/// drain-only.
pub impl @posoco.PipelineHook for NowledgeMem with fn on_turn_end(
  self : NowledgeMem,
) -> Unit {
  self.drain_silent()
}

///|
/// `before_tool` passthrough that drains under a throttle: when the last
/// drain (start, turn end, or an earlier hit here) is at least
/// NMEM_BEFORE_TOOL_DRAIN_INTERVAL_MS old, run the same bounded silent drain
/// before approving. Long tool-heavy turns shed staged state mid-flight
/// instead of accumulating it until turn end, without paying a round trip on
/// every call.
pub impl @posoco.PipelineHook for NowledgeMem with fn before_tool(
  self : NowledgeMem,
  call : @posoco.ToolCall,
) -> @posoco.ToolDecision {
  if self.config is Some(_) {
    let now = @async.now()
    if now - self.last_drain_ms >= NMEM_BEFORE_TOOL_DRAIN_INTERVAL_MS {
      self.drain_silent()
    }
  }
  @posoco.ToolDecision::Approve(call~)
}

///|
/// Passthrough that snapshots the model-visible transcript (D2). The final
/// assistant reply of a turn is never model-visible — the pump terminates
/// after it — so `record_assistant` completes the snapshot from
/// `ModelResponseReceived` events; without it every sync would lag one
/// assistant message behind.
pub impl @posoco.PipelineHook for NowledgeMem with fn before_model(
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
/// The plugin's instructions, and nothing else: what Nowledge Mem is, when
/// to search, when to save, how to route, and the provenance this host's
/// synced threads carry. Recalled DATA never travels here — the
/// working-memory briefing arrives through the `MemoryPort` section
/// (core's `MemoryRetrievalHook`) at the session's first turn, and the
/// model re-reads deliberately via the `read_working_memory` /
/// `read_context_bundle` tools.
pub impl @posoco.SystemPromptContributor for NowledgeMem with fn system_prompt(
  self : NowledgeMem,
) -> String {
  let source_app = match self.config {
    Some(config) => config.source_app
    None => self.source_app
  }
  startup_guidance(source_app)
}

///|
pub impl @posoco.Extension for NowledgeMem with fn extension_id(
  _self : NowledgeMem,
) -> String {
  NMEM_EXTENSION_ID
}

///|
/// Ports the extension contributes: PipelineHook (transcript snapshot), Observer
/// (dirty marking + session-redirect follow), Lifecycle (boot + final
/// drain), SystemPromptContributor (context bundle + guidance),
/// ToolProvider (§5 tool set), MemoryPort (D9 one-shot server search +
/// write-after queue — declaring it here is what wires core's
/// MemoryRetrievalHook), and CommandPort (`/memory` diagnostics:
/// status / flush) — all views of one state.
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
