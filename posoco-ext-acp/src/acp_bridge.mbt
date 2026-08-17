///|
/// AcpBridge — Agent Client Protocol (ACP v1) bridge for Posoco agents.
///
/// One struct, many port views: `Observer` projects turn events into ACP
/// `session/update` notifications, `Hook::before_tool` gates every tool call
/// through an ACP `session/request_permission` reverse request, and
/// `Lifecycle::on_shutdown` releases the attached session. Hosts (a future
/// cetas-acp) own the acp.mbt endpoint and stdio runtime and `attach` the
/// typed `AgentContext` plus ACP session id per prompt turn; while detached
/// the bridge is inert — it approves every tool and drops every event.
///
/// The observer path is synchronous, so events are enqueued on an async
/// queue; `flush` (deterministic, call it at turn end) and `spawn_pump`
/// (concurrent, for real-time streaming) are the two drain strategies and
/// may coexist — each queued update is delivered exactly once.
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
///   let bridge = AcpBridge::new()
///   inspect(bridge.flush(), content="0")
///   assert_true(bridge.stop_reason() is @acp.StopReason::EndTurn)
///   assert_true(bridge.take_failure() is None)
/// }
/// ```
pub struct AcpBridge {
  /// Host-supplied policy: which tool calls must be asked about. Read-only
  /// tool filtering belongs here, not in the wire mapping.
  needs_permission : (@posoco.ToolCall) -> Bool
  /// Outbound update queue. Sync `try_put` from the observer, async `get`
  /// from flush/pump. `close` closes it; the next `attach` reopens a fresh
  /// queue, so a host can scope one pump per prompt turn.
  mut queue : @aqueue.Queue[@acp.SessionUpdate]
  mut queue_closed : Bool
  // Host-pushed per-session state (the host bridge attaches/detaches these).
  mut context : @acp.AgentContext?
  mut session_id : String?
  // Self-collected per-turn state (via Observer events).
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
/// Canonical constructor. `needs_permission` decides which tool calls go
/// through an ACP permission request; it defaults to asking for every call.
/// Read-only tools can be exempted with e.g. a policy built on
/// `acp_tool_kind` that asks only for non-`Read`/`Search`/`Think` tools.
pub fn AcpBridge::new(
  needs_permission? : (@posoco.ToolCall) -> Bool = _ => true,
) -> AcpBridge {
  {
    needs_permission,
    queue: @aqueue.Queue(kind=Unbounded),
    queue_closed: false,
    context: None,
    session_id: None,
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
/// Attach the ACP outbound context and session id for the session (or the
/// single prompt turn) the host is about to drive. Updates queued before
/// `attach` are stamped with the session id at send time, so a host that
/// attaches first and runs the turn second needs no extra ordering care.
pub fn AcpBridge::attach(
  self : AcpBridge,
  context~ : @acp.AgentContext,
  session_id~ : String,
) -> Unit {
  // Reopen after a `close` so a per-prompt pump lifecycle (spawn pump →
  // run turn → flush → close) works across successive prompts.
  if self.queue_closed {
    self.queue = @aqueue.Queue(kind=Unbounded)
    self.queue_closed = false
  }
  self.context = Some(context)
  self.session_id = Some(session_id)
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
          Some(update) => {
            context.session_update({ session_id, update, meta: Omitted }) catch {
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
      let update = self.queue.get() catch { _ => break }
      match (self.context, self.session_id) {
        (Some(context), Some(session_id)) =>
          context.session_update({ session_id, update, meta: Omitted }) catch {
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
/// Enqueue one update. Never blocks; the queue only rejects after `close`.
fn AcpBridge::enqueue(self : AcpBridge, update : @acp.SessionUpdate) -> Unit {
  ignore(self.queue.try_put(update) catch { _ => false })
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
      self.ingest_model_response(message, usage)
    StreamChunkReceived(chunk~) => self.ingest_stream_chunk(chunk)
    TurnFailed(message) => self.last_failure = Some(message)
    TurnCompleted
    | SessionRedirect(..)
    | ConfigWarning(..)
    | ConfigChanged(..)
    | Custom(..) => ()
  }
}

///|
/// Reset per-model-round streaming state. Called at `TurnStarted` and after
/// each `ModelResponseReceived` so a tool-loop turn streams every round.
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
) -> Unit {
  match chunk {
    TextDelta(token~) => {
      self.enqueue(
        AgentMessageChunk({
          content: Text({ annotations: Omitted, text: token, meta: Omitted }),
          message_id: Value(self.text_message_id()),
          meta: Omitted,
        }),
      )
      self.text_streamed = true
    }
    ReasoningDelta(token~) => {
      self.enqueue(
        AgentThoughtChunk({
          content: Text({ annotations: Omitted, text: token, meta: Omitted }),
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
) -> Unit {
  match message {
    AssistantMessage(content~, tool_calls=_, reasoning~, finish_reason~) => {
      self.last_finish = Some(finish_reason)
      if !self.thought_streamed {
        match reasoning {
          Some(r) =>
            if r.content != "" {
              self.enqueue(
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
