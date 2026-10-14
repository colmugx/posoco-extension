///|
priv enum RegistryCmd {
  Release(id~ : Int32)
}

///|
priv enum RegistryQuery {
  Acquire
  Settle(id~ : Int32, outcome~ : @protocol.Outcome)
  Finish
}

///|
priv enum RegistryReply {
  Admitted(Int32, @aqueue.Queue[@protocol.Outcome])
  Acked
  Refused(String)
}

///|
priv struct Registry {
  pending : Map[Int32, @aqueue.Queue[@protocol.Outcome]]
  mut next_id : Int32
  mut closed : Bool
}

///|
// A timed-out query ends the invocation; it must never be retried, since
// fuwaroid may still process an already-admitted query after its timeout.
let registry_timeout_ms : Int32 = 5000

///|
fn registry_on_cmd(
  _ctx : @fuwaroid.Ctx[RegistryCmd, RegistryQuery, RegistryReply],
  state : Registry,
  cmd : RegistryCmd,
) -> Registry {
  match cmd {
    Release(id~) => state.pending.remove(id)
  }
  state
}

///|
fn registry_on_query(
  _ctx : @fuwaroid.Ctx[RegistryCmd, RegistryQuery, RegistryReply],
  state : Registry,
  query : RegistryQuery,
) -> (Registry, RegistryReply) {
  if state.closed {
    return (state, Refused("the request registry is closed"))
  }
  let reply = match query {
    Acquire =>
      if state.next_id == 2147483647 {
        Refused("request id exhausted")
      } else {
        let id = state.next_id
        state.next_id = id + 1
        let waiter = @aqueue.Queue(kind=Blocking(1))
        state.pending[id] = waiter
        Admitted(id, waiter)
      }
    Settle(id~, outcome~) =>
      match state.pending.get(id) {
        Some(waiter) => {
          state.pending.remove(id)
          // Each private waiter receives exactly once. Neither a closed nor
          // a full queue may silently discard an accepted reply.
          let delivered = waiter.try_put(outcome) catch {
            _ => abort("request registry waiter queue is closed")
          }
          if !delivered {
            abort("request registry waiter queue is full")
          }
          Acked
        }
        None => Refused("unknown or settled reply id")
      }
    Finish => {
      // Checking pending requests and closing admission is one atomic step.
      state.closed = true
      if state.pending.is_empty() {
        Acked
      } else {
        Refused("handler returned with pending requests")
      }
    }
  }
  (state, reply)
}

///|
fn registry_ask_failure(
  action : String,
  failure : @fuwaroid.AskFailure,
) -> String {
  let reason = match failure {
    NotDelivered(MailboxClosed) => "the registry is closed"
    NotDelivered(MailboxFull) => "the registry mailbox is full"
    TimedOut => "the registry did not answer in time"
    Stopped => "the registry stopped"
  }
  action + " because " + reason
}
