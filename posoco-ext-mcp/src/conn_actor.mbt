///|
/// Per-connection serial fold (round-1 Wave A2): generation, health, and
/// in-flight admission pairing live inside one fuwaroid loop per
/// connection; every kind of IO stays in the caller's async task. Reports
/// (`EndCall`/`EndReconnect`) carry the generation they belong to, and a
/// stale generation is a structural no-op — a late timeout can never smear
/// its stigma onto a newer connection.
///
/// `ClientT` is the client-payload seam: `@client.MCPClient`'s constructor
/// is private to the mcp package (only `connect_http`/`connect_stdio`
/// build one), so the actor is generic over the token it holds and hands
/// out. Production wires `ConnActor[@client.MCPClient]`; the fold rules are
/// client-agnostic. Wave 3 does the integration.

///|
/// Connection health folded by the actor.
priv enum ConnHealth {
  Fresh
  NeedsReconnect
  Reconnecting
}

///|
/// Outcome of one admitted call, reported back with `EndCall`. Only
/// `TimedOut` stigmatizes its connection (stale-response safety).
priv enum CallOutcome {
  CallOk
  RemoteFail
  TransportFail
  TimedOut
}

///|
/// Why an `Acquire` was denied.
priv enum ConnDeny {
  /// The current generation is already marked NeedsReconnect; run
  /// `BeginReconnect` before acquiring again.
  ReconnectFirst
  /// A reconnect is in flight for this connection.
  ReconnectInProgress
}

///|
/// Admission granted by `Acquire`: the client to use and the generation
/// the caller must stamp on its eventual `EndCall`.
priv struct ConnPermit[ClientT] {
  client : ClientT
  generation : Int
}

///|
/// Read-only folded view (Inspect reply; close/join and status display).
priv struct ConnView {
  health : ConnHealth
  generation : Int
  in_flight : Int
}

///|
/// Queries: synchronous folds that answer.
priv enum ConnQuery {
  Acquire
  BeginReconnect
  Inspect
}

///|
/// Commands: fire-and-forget folds stamped with a generation; a report
/// whose generation is no longer current is a no-op. `EndReconnect`
/// carries the replacement client, installed only when `ok` is true and
/// the generation matches the reconnecting one.
priv enum ConnCmd[ClientT] {
  EndCall(generation~ : Int, outcome~ : CallOutcome)
  EndReconnect(generation~ : Int, ok~ : Bool, client~ : ClientT?)
}

///|
/// Replies for all three queries. No `derive(Eq)`: production wires
/// `ConnReply[@client.MCPClient]`, and `@client.MCPClient` has no `Eq`, so
/// a derived instance could never exist for the production instantiation —
/// the fold tests compare the Int-token instantiation instead, through the
/// test-build-only impl in the white-box test files.
priv enum ConnReply[ClientT] {
  Permit(ConnPermit[ClientT])
  Denied(ConnDeny)
  Granted(generation~ : Int)
  Busy
  View(ConnView)
}

///|
/// Actor-owned fold state. All mutation happens inside the handlers.
priv struct ConnState[ClientT] {
  mut client : ClientT
  mut generation : Int
  mut health : ConnHealth
  mut in_flight : Int
}

///|
/// Fold one query (pure, no IO):
/// - `Acquire`: Fresh -> Permit(client, gen) with in_flight+1;
///   NeedsReconnect -> Denied(ReconnectFirst); Reconnecting ->
///   Denied(ReconnectInProgress).
/// - `BeginReconnect`: non-Reconnecting -> mint gen+1, enter Reconnecting,
///   reply Granted(gen+1); Reconnecting -> Busy (single winner).
/// - `Inspect`: reply the read-only view, fold nothing.
fn[ClientT] conn_fold_query(
  _ctx : @fuwaroid.Ctx[ConnCmd[ClientT], ConnQuery, ConnReply[ClientT]],
  state : ConnState[ClientT],
  query : ConnQuery,
) -> (ConnState[ClientT], ConnReply[ClientT]) {
  match query {
    Acquire =>
      match state.health {
        Fresh => {
          state.in_flight = state.in_flight + 1
          (
            state,
            Permit({ client: state.client, generation: state.generation, }),
          )
        }
        NeedsReconnect => (state, Denied(ReconnectFirst))
        Reconnecting => (state, Denied(ReconnectInProgress))
      }
    BeginReconnect =>
      if state.health is Reconnecting {
        (state, Busy)
      } else {
        state.generation = state.generation + 1
        state.health = Reconnecting
        (state, Granted(generation=state.generation))
      }
    Inspect =>
      (
        state,
        View({
          health: state.health,
          generation: state.generation,
          in_flight: state.in_flight,
        }),
      )
  }
}

///|
/// Fold one command (pure, no IO). A generation mismatch is always a
/// no-op. On a match:
/// - `EndCall` returns the admission (in_flight-1); a `TimedOut` outcome
///   additionally folds Fresh/NeedsReconnect -> NeedsReconnect, and never
///   regresses a Reconnecting connection.
/// - `EndReconnect` fires only while Reconnecting on the matching
///   generation: install the carried client (success reports only), fold
///   to Fresh, and zero in_flight — every leftover report of older
///   generations is thereby invalidated.
fn[ClientT] conn_fold_cmd(
  _ctx : @fuwaroid.Ctx[ConnCmd[ClientT], ConnQuery, ConnReply[ClientT]],
  state : ConnState[ClientT],
  cmd : ConnCmd[ClientT],
) -> ConnState[ClientT] {
  match cmd {
    EndCall(generation=g, outcome~) => {
      if g == state.generation {
        state.in_flight = state.in_flight - 1
        // Only a timeout stigmatizes its connection (stale-response safety);
        // every observable outcome still returns its admission.
        let stigmatizes = match outcome {
          TimedOut => true
          CallOk | RemoteFail | TransportFail => false
        }
        if stigmatizes && !(state.health is Reconnecting) {
          state.health = NeedsReconnect
        }
      }
      state
    }
    EndReconnect(generation=g, ok~, client=maybe) => {
      if g == state.generation && state.health is Reconnecting {
        match (ok, maybe) {
          (true, Some(replacement)) => state.client = replacement
          _ => ()
        }
        state.health = Fresh
        state.in_flight = 0
      }
      state
    }
  }
}

///|
/// Handle over one per-connection fuwaroid loop. Thin forwards only:
/// `ask` failures surface as `@fuwaroid.AskFailure` for the caller to
/// classify (never swallowed into success), and the ask timeout stays the
/// caller's decision.
priv struct ConnActor[ClientT] {
  actor : @fuwaroid.Fuwaroid[ConnCmd[ClientT], ConnQuery, ConnReply[ClientT]]
}

///|
/// Spawn the fold loop on the host's task group with the initial client
/// (production passes the freshly connected `@client.MCPClient`) at
/// generation 0, Fresh, empty in-flight. The mailbox is the default
/// Unbounded: this round serializes state arbitration, not admission.
fn[ClientT] ConnActor::start(
  group~ : @async.TaskGroup[Unit],
  client~ : ClientT,
) -> ConnActor[ClientT] {
  let init : ConnState[ClientT] = {
    client,
    generation: 0,
    health: Fresh,
    in_flight: 0,
  }
  {
    actor: @fuwaroid.Fuwaroid::spawn(
      group~,
      init~,
      on_cmd=conn_fold_cmd,
      on_query=conn_fold_query,
    ),
  }
}

///|
/// Ask for one call admission.
async fn[ClientT] ConnActor::acquire(
  self : ConnActor[ClientT],
  timeout_ms~ : Int,
) -> Result[ConnReply[ClientT], @fuwaroid.AskFailure] {
  self.actor.ask(Acquire, timeout_ms~)
}

///|
/// Ask for exclusive ownership of one reconnect.
async fn[ClientT] ConnActor::begin_reconnect(
  self : ConnActor[ClientT],
  timeout_ms~ : Int,
) -> Result[ConnReply[ClientT], @fuwaroid.AskFailure] {
  self.actor.ask(BeginReconnect, timeout_ms~)
}

///|
/// Ask for the read-only folded view.
async fn[ClientT] ConnActor::inspect(
  self : ConnActor[ClientT],
  timeout_ms~ : Int,
) -> Result[ConnReply[ClientT], @fuwaroid.AskFailure] {
  self.actor.ask(Inspect, timeout_ms~)
}

///|
/// Fire-and-forget the end of an admitted call, stamped with its
/// generation.
fn[ClientT] ConnActor::end_call(
  self : ConnActor[ClientT],
  generation~ : Int,
  outcome~ : CallOutcome,
) -> Result[Unit, @fuwaroid.SendRefusal] {
  self.actor.tell(EndCall(generation~, outcome~))
}

///|
/// Fire-and-forget the end of a reconnect; carry the replacement client
/// on success.
fn[ClientT] ConnActor::end_reconnect(
  self : ConnActor[ClientT],
  generation~ : Int,
  ok~ : Bool,
  client~ : ClientT?,
) -> Result[Unit, @fuwaroid.SendRefusal] {
  self.actor.tell(EndReconnect(generation~, ok~, client~))
}

///|
/// Graceful mailbox stop; the queued backlog still drains in FIFO order.
fn[ClientT] ConnActor::close(self : ConnActor[ClientT]) -> Unit {
  self.actor.close()
}

///|
/// Wait for the loop task to terminate and report why.
async fn[ClientT] ConnActor::join(
  self : ConnActor[ClientT],
) -> @fuwaroid.StopReason {
  self.actor.join()
}

///|
/// Synchronous, read-only mailbox diagnostics.
fn[ClientT] ConnActor::snapshot(
  self : ConnActor[ClientT],
) -> @fuwaroid.Snapshot {
  self.actor.snapshot()
}
