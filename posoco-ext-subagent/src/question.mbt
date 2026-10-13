///|
/// Parent-agent question channel: the subagent side of the ask-a-question
/// round trip. Children spawned with an interactive tool face route their
/// `ask_question_child` calls through `ParentQuestionChannel::ask`, which
/// parks until the spawning parent agent answers via the `answer_question`
/// tool, the answer deadline expires, or the wait is cancelled.
///
/// This extension owns the broker; the ask-question extension owns the tool
/// face. The two never import each other — host glue (cetas-js/cetas-native)
/// adapts one to the other, and both sides speak core `UiRequest`/`UiResponse`
/// as the payload vocabulary.

///|
/// Error surface mirrored from the ask-question extension's endpoint
/// contract (same shape, independent definition; host glue maps between
/// them).
pub(all) suberror QuestionError {
  Unsupported(String)
  Cancelled
  TimedOut
  Io(String)
} derive(Eq, @debug.Debug)

///|
pub extend QuestionError with Eq::{not_equal, equal}

///|
pub extend QuestionError with @debug.Debug::{to_repr}

///|
/// One registered question: everything the parent model needs to answer,
/// plus the identity the runtime filled in.
pub(all) struct QuestionInfo {
  /// Opaque answer key, minted by the broker.
  id : String
  /// Child session that asked.
  child_session : String
  /// Asking tool call id inside the child (audit trail).
  origin_call : String
  /// The question itself, in core request vocabulary.
  req : @posoco.UiRequest
} derive(@debug.Debug)

///|
pub extend QuestionInfo with @debug.Debug::{to_repr}

///|
/// Terminal state of one parked ask.
priv enum AskOutcome {
  Answered(@posoco.UiResponse)
  TimedOut
  Cancelled
}

///|
priv struct PendingQuestion {
  child_session : String
  req : @posoco.UiRequest
  mut outcome : AskOutcome?
  cell : @async.Semaphore
}

///|
/// One-shot signal the spawning `agent` tool races on: released exactly when
/// the child registers its first question while the tool call is still live.
priv struct ArmedWaiter {
  mut info : QuestionInfo?
  cell : @async.Semaphore
}

///|
/// Broker for parent-child questions. Standalone so host glue can construct
/// it once and inject the same instance into both `SubagentTools` (parent
/// side: answer tool, injection, race) and the child composer (the channel
/// view). `answer_timeout_ms` bounds each question's wait; `0` disables the
/// deadline (waits still end on cancel or shutdown).
pub struct QuestionBroker {
  priv answer_timeout_ms : Int64
  priv mut counter : Int32
  priv pending : Map[String, PendingQuestion]
  priv armed : Map[String, ArmedWaiter]
  priv mut queued : Array[QuestionInfo]
  priv queued_hooks : Array[(QuestionInfo) -> Unit]
}

///|
pub fn QuestionBroker::QuestionBroker(
  answer_timeout_ms~ : Int64 = 600000L,
) -> QuestionBroker {
  {
    answer_timeout_ms,
    counter: 0,
    pending: Map::from_array([]),
    armed: Map::from_array([]),
    queued: [],
    queued_hooks: [],
  }
}

///|
/// Child-side view of the broker. One channel serves every child of the
/// parent agent; the adapter binds the per-child identity at each call.
pub struct ParentQuestionChannel {
  priv broker : QuestionBroker
}

///|
pub fn QuestionBroker::channel(self : QuestionBroker) -> ParentQuestionChannel {
  { broker: self, }
}

///|
/// Subscribe to every question that lands in the injection queue (no live
/// spawning-tool race carries it in-wave). Hooks run synchronously inside
/// the asking child's task body and must not raise; the subagent tools use
/// this to project the registry and schedule a wakeup turn.
pub fn QuestionBroker::on_queued(
  self : QuestionBroker,
  cb : (QuestionInfo) -> Unit,
) -> Unit {
  self.queued_hooks.push(cb)
}

///|
fn QuestionBroker::fire_queued(
  self : QuestionBroker,
  info : QuestionInfo,
) -> Unit {
  for cb in self.queued_hooks {
    cb(info)
  }
}

///|
/// Register one question: mint the id, park the entry, and either hand it
/// to a live spawning-tool race (the receipt carries it in-wave) or queue it
/// for `before_model` injection.
fn QuestionBroker::register(
  self : QuestionBroker,
  child_session : String,
  origin_call : String,
  req : @posoco.UiRequest,
) -> QuestionInfo {
  self.counter = self.counter + 1
  let id = "question-\{self.counter}"
  let info : QuestionInfo = { id, child_session, origin_call, req, }
  self.pending[id] = {
    child_session,
    req,
    outcome: None,
    cell: @async.Semaphore(1, initial_value=0),
  }
  match self.armed.get(child_session) {
    Some(waiter) =>
      match waiter.info {
        None => {
          // Live race: the receipt carries this question in-wave; no hook.
          waiter.info = Some(info)
          waiter.cell.release()
          self.armed.remove(child_session)
        }
        Some(_) => {
          self.queued.push(info)
          self.fire_queued(info)
        }
      }
    None => {
      self.queued.push(info)
      self.fire_queued(info)
    }
  }
  info
}

///|
/// Arm the spawning tool's race for one child. The latest arm wins; a
/// superseded waiter is never released (its coroutine is cancelled with the
/// race it belonged to).
fn QuestionBroker::arm(
  self : QuestionBroker,
  child_session : String,
) -> ArmedWaiter {
  let waiter : ArmedWaiter = {
    info: None,
    cell: @async.Semaphore(1, initial_value=0),
  }
  self.armed[child_session] = waiter
  waiter
}

///|
async fn ArmedWaiter::wait(self : ArmedWaiter) -> QuestionInfo {
  self.cell.acquire()
  match self.info {
    Some(info) => info
    None => abort("armed waiter released without a question")
  }
}

///|
/// Park one ask until answered, expired, or cancelled. Cancellation of the
/// asking coroutine withdraws the question so no late answer can land;
/// cancellation is never converted into a normal return — `pause()`
/// re-raises the pending cancellation after the sync cleanup.
pub async fn ParentQuestionChannel::ask(
  self : ParentQuestionChannel,
  child_session~ : String,
  origin_call~ : String,
  req~ : @posoco.UiRequest,
) -> @posoco.UiResponse raise QuestionError {
  let broker = self.broker
  let info = broker.register(child_session, origin_call, req)
  // `handle_cancellation` erases the closure's typed raise, so the typed
  // errors are re-mapped here; cancellation never flows through this catch
  // (it surfaces as `None` below).
  let outcome : @posoco.UiResponse? = @async.handle_cancellation(async fn() {
    let wait : async () -> @posoco.UiResponse = async fn() {
      let entry = match broker.pending.get(info.id) {
        Some(entry) => entry
        None => raise QuestionError::Cancelled
      }
      entry.cell.acquire()
      match entry.outcome {
        Some(AskOutcome::Answered(response)) => response
        Some(AskOutcome::TimedOut) => raise QuestionError::TimedOut
        Some(AskOutcome::Cancelled) | None => raise QuestionError::Cancelled
      }
    }
    if broker.answer_timeout_ms > 0L {
      @async.with_timeout(broker.answer_timeout_ms.to_int(), wait) catch {
        error =>
          if error is @async.TimeoutError {
            // An answer may have landed before the timer won.
            broker.expire(info.id)
            match broker.lookup_outcome(info.id) {
              Some(AskOutcome::Answered(response)) => response
              _ => raise QuestionError::TimedOut
            }
          } else {
            raise error
          }
      }
    } else {
      wait()
    }
  }) catch {
    QuestionError::Unsupported(detail) =>
      raise QuestionError::Unsupported(detail)
    QuestionError::Cancelled => raise QuestionError::Cancelled
    QuestionError::TimedOut => raise QuestionError::TimedOut
    QuestionError::Io(detail) => raise QuestionError::Io(detail)
    error => raise QuestionError::Io(error.to_string())
  }
  match outcome {
    Some(response) => response
    None => {
      broker.withdraw(info.id)
      // The pending cancellation reasserts itself here; the typed error
      // below is only reachable if nothing is pending after cleanup.
      @async.pause()
      raise QuestionError::Cancelled
    }
  }
}

///|
/// Mark an unresolved entry timed out (the asker saw the deadline first);
/// late answers for it are rejected with an explicit reason.
fn QuestionBroker::expire(self : QuestionBroker, id : String) -> Unit {
  match self.pending.get(id) {
    Some(entry) =>
      if entry.outcome is None {
        entry.outcome = Some(AskOutcome::TimedOut)
      }
    None => ()
  }
}

///|
/// Remove one ask entirely (the asking coroutine was cancelled): no answer
/// can resolve it afterwards, and an un-injected queue entry disappears.
fn QuestionBroker::withdraw(self : QuestionBroker, id : String) -> Unit {
  self.pending.remove(id)
  let kept : Array[QuestionInfo] = []
  for info in self.queued {
    if info.id != id {
      kept.push(info)
    }
  }
  self.queued = kept
}

///|
/// Resolve one question with the parent agent's answer. `Ok` releases the
/// parked ask; every rejection carries an explicit reason the answer tool
/// surfaces verbatim.
fn QuestionBroker::resolve(
  self : QuestionBroker,
  id : String,
  response : @posoco.UiResponse,
) -> Result[Unit, String] {
  match self.pending.get(id) {
    None =>
      Err(
        "unknown question id '\{id}' — it was never asked, or the asking child went away",
      )
    Some(entry) =>
      match entry.outcome {
        Some(AskOutcome::Answered(_)) =>
          Err("question '\{id}' is already answered")
        Some(AskOutcome::TimedOut) =>
          Err("question '\{id}' expired waiting for an answer")
        Some(AskOutcome::Cancelled) => Err("question '\{id}' was cancelled")
        None => {
          entry.outcome = Some(AskOutcome::Answered(response))
          entry.cell.release()
          Ok(())
        }
      }
  }
}

///|
/// Cancel every still-pending question of one child (wave cancel, child
/// terminal) and drop its un-injected queue entries.
fn QuestionBroker::reject_child(
  self : QuestionBroker,
  child_session : String,
) -> Unit {
  for entry in self.pending.values() {
    if entry.child_session == child_session && entry.outcome is None {
      entry.outcome = Some(AskOutcome::Cancelled)
      entry.cell.release()
    }
  }
  let kept : Array[QuestionInfo] = []
  for info in self.queued {
    if info.child_session != child_session {
      kept.push(info)
    }
  }
  self.queued = kept
}

///|
/// Shutdown sweep: cancel every pending ask. Waits end as `Cancelled`, not
/// as hangs.
fn QuestionBroker::reject_all(self : QuestionBroker) -> Unit {
  for entry in self.pending.values() {
    if entry.outcome is None {
      entry.outcome = Some(AskOutcome::Cancelled)
      entry.cell.release()
    }
  }
  self.queued = []
}

///|
/// Terminal bookkeeping hook: after a child reaches a terminal state no
/// entry of its own may stay parked (unresolved ones become `Cancelled`).
fn QuestionBroker::drop_child(
  self : QuestionBroker,
  child_session : String,
) -> Unit {
  self.reject_child(child_session)
  let stale : Array[String] = []
  for id, entry in self.pending {
    if entry.child_session == child_session && entry.outcome is Some(_) {
      stale.push(id)
    }
  }
  for id in stale {
    self.pending.remove(id)
  }
}

///|
fn QuestionBroker::lookup_outcome(
  self : QuestionBroker,
  id : String,
) -> AskOutcome? {
  match self.pending.get(id) {
    Some(entry) => entry.outcome
    None => None
  }
}

///|
/// Answer-side view of one question id: still open, already resolved (with
/// a reason word for the rejection message), or unknown to this broker.
priv enum QuestionLookup {
  Open(QuestionInfo)
  Resolved(String)
  Unknown
}

///|
/// Answer-side lookup for validation and rejection text. The origin call id
/// stays out of the answer-side projection; the parent model answers by
/// id and type.
fn QuestionBroker::lookup(self : QuestionBroker, id : String) -> QuestionLookup {
  match self.pending.get(id) {
    None => QuestionLookup::Unknown
    Some(entry) =>
      match entry.outcome {
        None =>
          QuestionLookup::Open({
            id,
            child_session: entry.child_session,
            origin_call: "",
            req: entry.req,
          })
        Some(AskOutcome::Answered(_)) =>
          QuestionLookup::Resolved("already answered")
        Some(AskOutcome::TimedOut) =>
          QuestionLookup::Resolved("expired waiting for an answer")
        Some(AskOutcome::Cancelled) => QuestionLookup::Resolved("cancelled")
      }
  }
}

///|
/// Drain every un-injected question for `before_model` delivery. Each id
/// leaves the queue exactly once.
fn QuestionBroker::take_queued(self : QuestionBroker) -> Array[QuestionInfo] {
  let out = self.queued
  self.queued = []
  out
}
