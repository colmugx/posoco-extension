///|
/// One queued outbound update plus the `_meta` computed at projection time.
/// Meta is derived exactly once — while the triggering turn event is still
/// in hand — so the async pump forwards what projection decided and never
/// re-derives it against a stale "current" event.
priv struct QueuedUpdate {
  update : @acp.SessionUpdate
  meta : Json?
}

///|
/// Map a projection-time `_meta` onto the wire's three-state field.
/// `Null` is never produced (the decorator has no explicit-null concept).
fn acp_wire_meta(meta : Json?) -> @acp.ProtocolNullable[Json] {
  match meta {
    Some(json) => Value(json)
    None => Omitted
  }
}

///|
/// AcpBridge — Agent Client Protocol (ACP v1) bridge for Posoco agents.
///
/// One bridge is bound to one ACP session for its whole life: attaching a
/// different session id aborts (cross-session wiring must fail loudly —
/// run one bridge per session), while re-attaching the bound session is
/// idempotent, so hosts may attach once per session or per prompt turn.
/// While detached the bridge is inert — it approves every tool and drops
/// every event.
///
/// One struct, many port views: `Observer` projects turn events into ACP
/// `session/update` notifications, `ApprovalSource::ask` translates
/// ext-permission approval asks into ACP `session/request_permission`
/// reverse requests (the gating policy itself is a composed
/// `@permission.PermissionPolicy`), `UiPort::request` maps interactive
/// requests onto ACP elicitations, and `Lifecycle::on_shutdown` closes the
/// outbound queue (so a long-lived pump exits) and releases the session
/// binding. Hosts (a future cetas-acp) own the acp.mbt endpoint and stdio
/// runtime and `attach` the typed `AgentContext` plus the ACP session id.
///
/// The observer path is synchronous, so events are enqueued on an async
/// queue; `flush` (deterministic, call it at turn end) and `spawn_pump`
/// (concurrent, for real-time streaming) are the two drain strategies and
/// may coexist — each queued update is delivered exactly once, carrying
/// the `_meta` its projection computed (the `meta~` constructor seam).
///
/// Cross-prompt state: `used_tokens` accumulates over the session (ACP
/// usage is session-cumulative) and `message_seq` keeps minted ids unique
/// for the session — `attach` deliberately preserves both, while it does
/// clear `last_failure` and the in-round streaming state.
///
/// Wire contract (ACP v1):
/// - `ToolCallPending` → `ToolCall` announcement (status `Pending`, kind,
///   title, raw input)
/// - `ToolCallResult` → `ToolCallUpdate` (status `Completed`/`Failed`, text
///   content)
/// - `ToolCallDeferred` → `ToolCallUpdate` (status `Pending`, deferred title)
/// - `StreamChunkReceived` text/reasoning deltas → streamed chunks sharing
///   one per-round `messageId`
/// - `ModelResponseReceived` → full `AgentThoughtChunk`/`AgentMessageChunk`
///   (suppressed when the same text or thought already streamed this model
///   round) plus a cumulative `UsageUpdate`
/// - `TurnFailed` → recorded for the host (`take_failure`); v1 has no
///   error-chunk update, turn errors belong on the `session/prompt` response
///
/// # Example
/// ```mbt check
/// async test "detached bridge stays inert" {
///   let bridge = AcpBridge()
///   inspect(bridge.flush(), content="0")
///   assert_true(bridge.stop_reason() is @acp.StopReason::EndTurn)
///   assert_true(bridge.take_failure() is None)
/// }
/// ```
pub struct AcpBridge {
  /// Outbound update queue. Sync `try_put` from the observer, async `get`
  /// from flush/pump. `close` closes it; the next `attach` reopens a fresh
  /// queue, so a host can scope one pump per prompt turn. Private because
  /// the element carries projection-time `_meta`, an implementation detail
  /// of the wire contract.
  priv mut queue : @aqueue.Queue[QueuedUpdate]
  mut queue_closed : Bool
  // Host-pushed per-session state (the host bridge attaches/detaches these).
  mut context : @acp.AgentContext?
  mut session_id : String?
  // `_meta` seam: pure decorator consulted once per queued update at
  // projection time with (triggering event, projected update).
  meta_decorator : ((@posoco.TurnEvent, @acp.SessionUpdate) -> Json?)?
  // Self-collected per-turn state (via Observer events). `message_seq` and
  // `used_tokens` persist across prompts (unique ids, session-cumulative
  // usage); everything below them is reset per turn or per attach.
  mut message_seq : Int
  mut current_text_id : String?
  mut current_thought_id : String?
  mut text_streamed : Bool
  mut thought_streamed : Bool
  mut used_tokens : Int
  mut last_finish : @posoco.FinishReason?
  mut last_failure : String?
}

///|
/// Canonical constructor. Which tools ask is not the bridge's concern: the
/// composed `@permission.PermissionPolicy` owns that policy and calls the
/// bridge's `ApprovalSource` implementation for pure wire translation.
///
/// `meta~` is the `_meta` decorator seam: a pure function consulted once
/// per queued update at projection time with (triggering turn event,
/// projected update). `Some(json)` is sent as the `_meta` of the
/// `session/update` frame; `None` omits it (no decorator behaves exactly
/// like today's wire).
pub fn AcpBridge::AcpBridge(
  meta? : ((@posoco.TurnEvent, @acp.SessionUpdate) -> Json?)? = None,
) -> AcpBridge {
  {
    queue: @aqueue.Queue(kind=Unbounded),
    queue_closed: false,
    context: None,
    session_id: None,
    meta_decorator: meta,
    message_seq: 0,
    current_text_id: None,
    current_thought_id: None,
    text_streamed: false,
    thought_streamed: false,
    used_tokens: 0,
    last_finish: None,
    last_failure: None,
  }
}

///|
/// Bind the ACP outbound context and session id for the session the host
/// is about to drive. Re-attaching the bound session id is idempotent
/// (per-prompt attach of the same session); attaching a different session
/// id while bound aborts — one bridge serves one session, and cross-session
/// wiring must fail loudly instead of mislabeling updates (`detach` is the
/// explicit teardown after which a bridge may be rebound). Updates queued
/// before `attach` are stamped with the session id at send time, so a host
/// that attaches first and runs the turn second needs no extra ordering
/// care. Each attach clears `last_failure` and the in-round streaming
/// state; `used_tokens` and `message_seq` persist (see the struct doc).
pub fn AcpBridge::attach(
  self : AcpBridge,
  context~ : @acp.AgentContext,
  session_id~ : String,
) -> Unit {
  match self.session_id {
    Some(bound) =>
      if bound != session_id {
        abort(
          "posoco-ext-acp: this AcpBridge is bound to ACP session '\{bound}'; refusing to attach session '\{session_id}' — one bridge serves one session, construct a separate bridge per session (call detach first only after teardown)",
        )
      }
    None => ()
  }
  // Reopen after a `close` so a per-prompt pump lifecycle (spawn pump →
  // run turn → flush → close) works across successive prompts.
  if self.queue_closed {
    self.queue = @aqueue.Queue(kind=Unbounded)
    self.queue_closed = false
  }
  self.context = Some(context)
  self.session_id = Some(session_id)
  self.last_failure = None
  self.reset_round()
}

///|
/// The ACP session id this bridge is bound to, or `None` while detached.
pub fn AcpBridge::session_id(self : AcpBridge) -> String? {
  self.session_id
}

///|
/// Release the attached context and session id. Items still queued when no
/// pump is running stay queued (and are stamped with the next attached
/// session); run `flush` first if pending updates must reach the old client.
pub fn AcpBridge::detach(self : AcpBridge) -> Unit {
  self.context = None
  self.session_id = None
}

///|
/// Close the outbound queue permanently — until the next `attach` reopens a
/// fresh one. `spawn_pump` drains and exits once the queue closes; `flush`
/// sends what remains and stops. Events enqueued while closed are dropped.
/// The session binding is untouched: rebinding to another session requires
/// an explicit `detach`.
pub fn AcpBridge::close(self : AcpBridge) -> Unit {
  self.queue.close()
  self.queue_closed = true
}

///|
/// Drain every queued update through the attached context now. Returns the
/// number of updates sent. A detached bridge sends nothing; a send failure
/// stops the drain early (a dead ACP connection fails every subsequent send
/// too) and leaves the unsent items queued.
pub async fn AcpBridge::flush(self : AcpBridge) -> Int noraise {
  match (self.context, self.session_id) {
    (Some(context), Some(session_id)) => {
      let mut sent = 0
      while true {
        let next = self.queue.try_get() catch { _ => None }
        match next {
          Some(item) => {
            context.session_update({
              session_id,
              update: item.update,
              meta: acp_wire_meta(item.meta),
            }) catch {
              _ => break
            }
            sent += 1
          }
          None => break
        }
      }
      sent
    }
    _ => 0
  }
}

///|
/// Spawn a concurrent pump that forwards queued updates the moment they
/// arrive — the real-time streaming path. The observer enqueue is
/// synchronous, so hosts that want live token streaming in the client run
/// this pump in a task group and additionally `flush` at turn end; the two
/// drains coexist because each queued update is consumed exactly once.
///
/// The pump exits when the queue is closed (`close`) or a send fails (dead
/// connection). Updates arriving while no session is attached are dropped.
pub fn[G] AcpBridge::spawn_pump(
  self : AcpBridge,
  group : @async.TaskGroup[G],
) -> Unit {
  group.spawn_bg(() => {
    while true {
      let item = self.queue.get() catch { _ => break }
      match (self.context, self.session_id) {
        (Some(context), Some(session_id)) =>
          context.session_update({
            session_id,
            update: item.update,
            meta: acp_wire_meta(item.meta),
          }) catch {
            _ => break
          }
        _ => ()
      }
    }
  })
}

///|
/// ACP stop reason for the turn that just ran, derived from the last
/// assistant finish reason the bridge observed.
pub fn AcpBridge::stop_reason(self : AcpBridge) -> @acp.StopReason {
  acp_stop_reason(self.last_finish)
}

///|
/// Consume the sanitized failure message of the last `TurnFailed` (if any).
/// v1 has no error-chunk session update, so the host reads this to fail the
/// `session/prompt` response.
pub fn AcpBridge::take_failure(self : AcpBridge) -> String? {
  let failure = self.last_failure
  self.last_failure = None
  failure
}

///|
/// Mint a fresh client-correlation id (`msg-1`, `msg-2`, ...). Ids are
/// unique per bridge lifetime, never reused across turns.
fn AcpBridge::mint_message_id(self : AcpBridge, prefix : String) -> String {
  self.message_seq += 1
  "\{prefix}-\{self.message_seq}"
}

///|
/// The current model round's agent-message id, minted on first use so all
/// chunks of one streamed message share one id.
fn AcpBridge::text_message_id(self : AcpBridge) -> String {
  match self.current_text_id {
    Some(id) => id
    None => {
      let id = self.mint_message_id("msg")
      self.current_text_id = Some(id)
      id
    }
  }
}

///|
/// The current model round's thought-message id, minted on first use.
fn AcpBridge::thought_message_id(self : AcpBridge) -> String {
  match self.current_thought_id {
    Some(id) => id
    None => {
      let id = self.mint_message_id("thought")
      self.current_thought_id = Some(id)
      id
    }
  }
}

///|
/// Enqueue one update, computing its `_meta` against the triggering event
/// while that event is still in hand (send paths only read it back). Never
/// blocks; the queue only rejects after `close`.
fn AcpBridge::enqueue(
  self : AcpBridge,
  trigger : @posoco.TurnEvent,
  update : @acp.SessionUpdate,
) -> Unit {
  let meta = match self.meta_decorator {
    Some(decorate) => decorate(trigger, update)
    None => None
  }
  ignore(self.queue.try_put({ update, meta, }) catch { _ => false })
}

///|
/// Project one turn event onto queued updates (Observer entry point).
fn AcpBridge::ingest(self : AcpBridge, event : @posoco.TurnEvent) -> Unit {
  match event {
    TurnStarted => {
      self.last_failure = None
      self.reset_round()
    }
    ToolCallPending(call) =>
      self.enqueue(
        event,
        ToolCall({
          tool_call_id: call.call_id.to_string(),
          title: acp_tool_title(call),
          kind: Value(acp_tool_kind(call.name.to_string())),
          status: Value(Pending),
          content: Omitted,
          locations: Omitted,
          raw_input: Value(call.arguments),
          raw_output: Omitted,
          meta: Omitted,
        }),
      )
    ToolCallResult(call~, result~, ..) =>
      self.enqueue(
        event,
        ToolCallUpdate({
          tool_call_id: call.call_id.to_string(),
          kind: Omitted,
          status: Value(acp_outcome_status(result)),
          title: Omitted,
          content: Value([
            Content({
              content: Text({
                annotations: Omitted,
                text: acp_outcome_text(result),
                meta: Omitted,
              }),
              meta: Omitted,
            }),
          ]),
          locations: Omitted,
          raw_input: Omitted,
          raw_output: Omitted,
          meta: Omitted,
        }),
      )
    ToolCallDeferred(call~, reason~) =>
      self.enqueue(
        event,
        ToolCallUpdate({
          tool_call_id: call.call_id.to_string(),
          kind: Omitted,
          status: Value(Pending),
          title: Value(
            "\{acp_tool_title(call)} — deferred: \{@devkit.sanitize_label(reason)}",
          ),
          content: Omitted,
          locations: Omitted,
          raw_input: Omitted,
          raw_output: Omitted,
          meta: Omitted,
        }),
      )
    ModelResponseReceived(message~, usage~) =>
      self.ingest_model_response(message, usage, event)
    StreamChunkReceived(chunk~) => self.ingest_stream_chunk(chunk, event)
    TurnFailed(message) => self.last_failure = Some(message)
    TurnCompleted
    | SessionRedirect(..)
    | ConfigWarning(..)
    | ConfigChanged(..)
    | StreamChunksDropped(..)
    | Custom(..) => ()
  }
}

///|
/// Reset per-model-round streaming state. Called at `TurnStarted`, after
/// each `ModelResponseReceived`, and on `attach` so a fresh prompt turn
/// starts a fresh round.
fn AcpBridge::reset_round(self : AcpBridge) -> Unit {
  self.current_text_id = None
  self.current_thought_id = None
  self.text_streamed = false
  self.thought_streamed = false
}

///|
/// Project one streamed model chunk. Text and reasoning deltas become
/// chunks sharing the round's message id; tool-call deltas, usage, and
/// finish markers arrive with strictly better data later
/// (`ToolCallPending` / `ModelResponseReceived`) and are not duplicated here.
fn AcpBridge::ingest_stream_chunk(
  self : AcpBridge,
  chunk : @posoco.StreamChunk,
  trigger : @posoco.TurnEvent,
) -> Unit {
  match chunk {
    TextDelta(token~) => {
      self.enqueue(
        trigger,
        AgentMessageChunk({
          content: Text({ annotations: Omitted, text: token, meta: Omitted, }),
          message_id: Value(self.text_message_id()),
          meta: Omitted,
        }),
      )
      self.text_streamed = true
    }
    ReasoningDelta(token~) => {
      self.enqueue(
        trigger,
        AgentThoughtChunk({
          content: Text({ annotations: Omitted, text: token, meta: Omitted, }),
          message_id: Value(self.thought_message_id()),
          meta: Omitted,
        }),
      )
      self.thought_streamed = true
    }
    ToolCallDelta(..) | Usage(..) | Finish(..) => ()
  }
}

///|
/// Project one committed model response. Tool calls on the message are
/// skipped deliberately — the kernel announces each call through
/// `ToolCallPending`, which carries the authoritative call id.
fn AcpBridge::ingest_model_response(
  self : AcpBridge,
  message : @posoco.Message,
  usage : @posoco.Usage?,
  trigger : @posoco.TurnEvent,
) -> Unit {
  match message {
    AssistantMessage(content~, tool_calls=_, reasoning~, finish_reason~) => {
      self.last_finish = Some(finish_reason)
      if !self.thought_streamed {
        match reasoning {
          Some(r) =>
            if r.content != "" {
              self.enqueue(
                trigger,
                AgentThoughtChunk({
                  content: Text({
                    annotations: Omitted,
                    text: r.content,
                    meta: Omitted,
                  }),
                  message_id: Value(self.thought_message_id()),
                  meta: Omitted,
                }),
              )
            }
          None => ()
        }
      }
      if !self.text_streamed {
        for block in content {
          self.enqueue(
            trigger,
            AgentMessageChunk({
              content: acp_content_block(block),
              message_id: Value(self.text_message_id()),
              meta: Omitted,
            }),
          )
        }
      }
      match usage {
        Some(u) => {
          let used = match u.total_tokens {
            Some(total) => total
            None => u.input_tokens.unwrap_or(0) + u.output_tokens.unwrap_or(0)
          }
          self.used_tokens += used
          self.enqueue(
            trigger,
            UsageUpdate({
              used: self.used_tokens.to_uint64(),
              size: 0, // posoco does not know the context window size here
              cost: Omitted,
              meta: Omitted,
            }),
          )
        }
        None => ()
      }
      self.reset_round()
    }
    _ => ()
  }
}
