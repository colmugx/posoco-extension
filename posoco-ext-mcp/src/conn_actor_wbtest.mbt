///|
/// ConnActor fold-table coverage (round-1 Wave A2). The client payload is
/// an Int identity token: `@client.MCPClient` cannot be constructed
/// outside the mcp package (its constructor is private to that package),
/// and the fold rules are client-agnostic, so the state machine is pinned
/// with cheap tokens. Ordering is deterministic: tells and asks share one
/// FIFO mailbox, so every assertion after an ask observes every prior
/// tell. The actor types carry no Eq (production instantiates
/// ConnReply[MCPClient], and MCPClient cannot implement Eq); the
/// test-build-only Eq impls for the Int-token instantiation live in
/// posoco_ext_mcp_wbtest.mbt, so assertions here use Eq-based helpers
/// instead of assert_eq.

///|
/// The folded view via the Inspect query.
async fn conn_actor_view(
  actor : ConnActor[Int],
  timeout_ms? : Int = 10_000,
) -> ConnView {
  let reply = actor.inspect(timeout_ms~)
  guard reply is Ok(View(view)) else {
    fail("ConnActor inspect did not return a view")
  }
  view
}

///|
/// True when the folded view is exactly this health/generation/in_flight.
async fn conn_view_is(
  actor : ConnActor[Int],
  health~ : ConnHealth,
  generation~ : Int,
  in_flight~ : Int,
) -> Bool {
  let view = conn_actor_view(actor)
  view.health == health &&
  view.generation == generation &&
  view.in_flight == in_flight
}

///|
/// True when the ask answered with exactly this reply.
fn conn_reply_is(
  got : Result[ConnReply[Int], @fuwaroid.AskFailure],
  want : ConnReply[Int],
) -> Bool {
  match got {
    Ok(reply) => reply == want
    Err(_) => false
  }
}

///|
/// The permit reply for one client/generation pair.
fn conn_permit_reply(client : Int, generation : Int) -> ConnReply[Int] {
  Permit({ client, generation, })
}

///|
/// True when the ask never entered the mailbox because it is closed.
fn conn_ask_refused_closed(
  got : Result[ConnReply[Int], @fuwaroid.AskFailure],
) -> Bool {
  match got {
    Err(
      @fuwaroid.AskFailure::NotDelivered(@fuwaroid.SendRefusal::MailboxClosed)
    ) => true
    _ => false
  }
}

///|
/// Acquire answers per health column, and in_flight pairs with EndCall:
/// Fresh -> Permit(client, gen); NeedsReconnect -> ReconnectFirst;
/// Reconnecting -> ReconnectInProgress. Fold table rows Acquire and
/// EndCall (Fresh column, both outcomes).
async test "conn_actor acquire answers per health and pairs in_flight with EndCall" {
  @async.with_task_group(group => {
    let actor = ConnActor::start(group~, client=100)
    assert_true(
      conn_reply_is(actor.acquire(timeout_ms=10_000), conn_permit_reply(100, 0)),
    )
    assert_true(
      conn_reply_is(actor.acquire(timeout_ms=10_000), conn_permit_reply(100, 0)),
    )
    assert_true(conn_view_is(actor, health=Fresh, generation=0, in_flight=2))
    // A clean outcome returns its admission only.
    let _ = actor.end_call(generation=0, outcome=CallOk)
    assert_true(conn_view_is(actor, health=Fresh, generation=0, in_flight=1))
    // A timeout on the owning generation also returns the admission and
    // additionally folds Fresh -> NeedsReconnect.
    let _ = actor.end_call(generation=0, outcome=TimedOut)
    assert_true(
      conn_view_is(actor, health=NeedsReconnect, generation=0, in_flight=0),
    )
    assert_true(
      conn_reply_is(actor.acquire(timeout_ms=10_000), Denied(ReconnectFirst)),
    )
    assert_true(
      conn_reply_is(
        actor.begin_reconnect(timeout_ms=10_000),
        Granted(generation=1),
      ),
    )
    assert_true(
      conn_reply_is(
        actor.acquire(timeout_ms=10_000),
        Denied(ReconnectInProgress),
      ),
    )
  })
}

///|
/// The core property: reports of a dead generation are structural no-ops.
/// A late TimedOut from gen 0 must not stain the freshly reconnected gen
/// 1, a stale clean report must not drive in_flight negative, and a stale
/// or duplicate EndReconnect must not re-fold. Fold table rows EndCall
/// (stale columns) and EndReconnect (guard clauses).
async test "conn_actor stale generation reports never touch the current state" {
  @async.with_task_group(group => {
    let actor = ConnActor::start(group~, client=100)
    assert_true(
      conn_reply_is(actor.acquire(timeout_ms=10_000), conn_permit_reply(100, 0)),
    )
    assert_true(
      conn_reply_is(
        actor.begin_reconnect(timeout_ms=10_000),
        Granted(generation=1),
      ),
    )
    let _ = actor.end_reconnect(generation=1, ok=true, client=Some(200))
    assert_true(conn_view_is(actor, health=Fresh, generation=1, in_flight=0))
    // Late timeout from the dead generation: the stigma stays with gen 0.
    let _ = actor.end_call(generation=0, outcome=TimedOut)
    assert_true(conn_view_is(actor, health=Fresh, generation=1, in_flight=0))
    // Stale non-timeout reports (remote/transport/clean) are equally
    // inert: in_flight never goes negative.
    let _ = actor.end_call(generation=0, outcome=RemoteFail)
    let _ = actor.end_call(generation=0, outcome=TransportFail)
    let _ = actor.end_call(generation=0, outcome=CallOk)
    assert_true(conn_view_is(actor, health=Fresh, generation=1, in_flight=0))
    // Stale EndReconnect (old generation) is a no-op.
    let _ = actor.end_reconnect(generation=0, ok=true, client=Some(300))
    assert_true(conn_view_is(actor, health=Fresh, generation=1, in_flight=0))
    // Duplicate completion of the CURRENT generation after the fold is
    // inert too: the fold fires only while Reconnecting.
    let _ = actor.end_reconnect(generation=1, ok=true, client=Some(300))
    assert_true(conn_view_is(actor, health=Fresh, generation=1, in_flight=0))
    assert_true(
      conn_reply_is(actor.acquire(timeout_ms=10_000), conn_permit_reply(200, 1)),
    )
  })
}

///|
/// BeginReconnect has exactly one winner and mints the next generation
/// from both Fresh and NeedsReconnect; the loser sees Busy. Fold table row
/// BeginReconnect.
async test "conn_actor begin_reconnect has one winner and mints the next generation" {
  @async.with_task_group(group => {
    let actor = ConnActor::start(group~, client=100)
    assert_true(
      conn_reply_is(
        actor.begin_reconnect(timeout_ms=10_000),
        Granted(generation=1),
      ),
    )
    assert_true(conn_reply_is(actor.begin_reconnect(timeout_ms=10_000), Busy))
    assert_true(
      conn_view_is(actor, health=Reconnecting, generation=1, in_flight=0),
    )
    let _ = actor.end_reconnect(generation=1, ok=false, client=None)
    // From NeedsReconnect the mint is the same +1 and still single-winner.
    assert_true(
      conn_reply_is(actor.acquire(timeout_ms=10_000), conn_permit_reply(100, 1)),
    )
    let _ = actor.end_call(generation=1, outcome=TimedOut)
    assert_true(
      conn_view_is(actor, health=NeedsReconnect, generation=1, in_flight=0),
    )
    assert_true(
      conn_reply_is(
        actor.begin_reconnect(timeout_ms=10_000),
        Granted(generation=2),
      ),
    )
    assert_true(conn_reply_is(actor.begin_reconnect(timeout_ms=10_000), Busy))
  })
}

///|
/// EndReconnect ok=true installs the carried client and folds Fresh with
/// in_flight zeroed (old-generation leftovers die with the counter);
/// ok=false folds Fresh but keeps the old client (calls fail fast on the
/// closed wire until a later reconnect succeeds), and a client payload on
/// a failure report is never installed. Fold table rows EndReconnect.
async test "conn_actor end_reconnect swaps client on success keeps old on failure" {
  @async.with_task_group(group => {
    let actor = ConnActor::start(group~, client=100)
    assert_true(
      conn_reply_is(actor.acquire(timeout_ms=10_000), conn_permit_reply(100, 0)),
    )
    assert_true(
      conn_reply_is(
        actor.begin_reconnect(timeout_ms=10_000),
        Granted(generation=1),
      ),
    )
    let _ = actor.end_reconnect(generation=1, ok=true, client=Some(200))
    assert_true(conn_view_is(actor, health=Fresh, generation=1, in_flight=0))
    assert_true(
      conn_reply_is(actor.acquire(timeout_ms=10_000), conn_permit_reply(200, 1)),
    )
    // The dead generation's leftover EndCall does not touch the zeroed
    // counter of the new generation.
    let _ = actor.end_call(generation=0, outcome=TimedOut)
    assert_true(conn_view_is(actor, health=Fresh, generation=1, in_flight=1))
    assert_true(
      conn_reply_is(
        actor.begin_reconnect(timeout_ms=10_000),
        Granted(generation=2),
      ),
    )
    let _ = actor.end_reconnect(generation=2, ok=false, client=None)
    assert_true(conn_view_is(actor, health=Fresh, generation=2, in_flight=0))
    assert_true(
      conn_reply_is(actor.acquire(timeout_ms=10_000), conn_permit_reply(200, 2)),
    )
    // Clients install on success reports only.
    assert_true(
      conn_reply_is(
        actor.begin_reconnect(timeout_ms=10_000),
        Granted(generation=3),
      ),
    )
    let _ = actor.end_reconnect(generation=3, ok=false, client=Some(999))
    assert_true(
      conn_reply_is(actor.acquire(timeout_ms=10_000), conn_permit_reply(200, 3)),
    )
  })
}

///|
/// Defensive pin for the EndCall/Reconnecting cell: a matching-generation
/// timeout while Reconnecting returns its admission but never regresses
/// the health out of Reconnecting; in_flight survives BeginReconnect and
/// is zeroed only by EndReconnect.
async test "conn_actor timed_out during reconnecting returns admission without health regress" {
  @async.with_task_group(group => {
    let actor = ConnActor::start(group~, client=100)
    assert_true(
      conn_reply_is(actor.acquire(timeout_ms=10_000), conn_permit_reply(100, 0)),
    )
    assert_true(
      conn_reply_is(
        actor.begin_reconnect(timeout_ms=10_000),
        Granted(generation=1),
      ),
    )
    assert_true(
      conn_view_is(actor, health=Reconnecting, generation=1, in_flight=1),
    )
    let _ = actor.end_call(generation=1, outcome=TimedOut)
    assert_true(
      conn_view_is(actor, health=Reconnecting, generation=1, in_flight=0),
    )
    // The reconnect of that generation still completes normally.
    let _ = actor.end_reconnect(generation=1, ok=true, client=Some(200))
    assert_true(conn_view_is(actor, health=Fresh, generation=1, in_flight=0))
  })
}

///|
/// Lifecycle: close refuses further tells with SendRefusal::MailboxClosed,
/// close+join terminates with StopReason::Graceful, and a post-stop ask
/// surfaces the refusal as AskFailure::NotDelivered(MailboxClosed) — the
/// wrapper never converts an admission refusal into success.
async test "conn_actor close refuses late tells joins gracefully and fails late asks" {
  @async.with_task_group(group => {
    let actor = ConnActor::start(group~, client=100)
    actor.close()
    assert_eq(
      actor.end_call(generation=0, outcome=CallOk),
      Err(@fuwaroid.SendRefusal::MailboxClosed),
    )
    let reason = actor.join()
    guard reason is Graceful else { fail("ConnActor join expected Graceful") }
    assert_true(conn_ask_refused_closed(actor.acquire(timeout_ms=10_000)))
  })
}

///|
/// Snapshot conservation: outstanding == accepted - processed - abandoned
/// at every observation, and a graceful termination closes the law with
/// abandoned == 0 and outstanding == 0. The mid-flight observation is
/// deterministic: tells and snapshot run in one uninterrupted scheduling
/// turn, so the loop cannot have served anything yet.
async test "conn_actor snapshot conserves accepted processed abandoned outstanding" {
  @async.with_task_group(group => {
    let actor = ConnActor::start(group~, client=100)
    let _ = actor.end_call(generation=0, outcome=CallOk)
    let _ = actor.end_call(generation=0, outcome=TimedOut)
    let early = actor.snapshot()
    assert_eq(early.accepted, 2L)
    assert_eq(early.processed, 0L)
    assert_eq(early.abandoned, 0L)
    assert_eq(early.outstanding, 2L)
    // The ask is a FIFO barrier: its reply proves the tells were served
    // (the TimedOut tell folded Fresh -> NeedsReconnect, hence the denial).
    assert_true(
      conn_reply_is(actor.acquire(timeout_ms=10_000), Denied(ReconnectFirst)),
    )
    let settled = actor.snapshot()
    assert_eq(settled.accepted, 3L)
    assert_eq(settled.processed, 3L)
    assert_eq(settled.abandoned, 0L)
    assert_eq(settled.outstanding, 0L)
    actor.close()
    let reason = actor.join()
    guard reason is Graceful else { fail("ConnActor join expected Graceful") }
    let after_stop = actor.snapshot()
    guard after_stop.lifecycle is Stopped(Graceful) else {
      fail("ConnActor expected Stopped(Graceful)")
    }
    assert_eq(after_stop.accepted, 3L)
    assert_eq(after_stop.processed, 3L)
    assert_eq(after_stop.abandoned, 0L)
    assert_eq(after_stop.outstanding, 0L)
  })
}
