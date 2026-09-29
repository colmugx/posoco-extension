///|
/// Serialized rate-limit runtime. RecoveryState has exactly one writer: the
/// Fuwaroid command fold. Timers and Agent resume calls are supervised async
/// effects that can only report back through runtime messages.

priv enum RecoveryCommand {
  RateLimitObserved(
    session_id~ : String,
    reset_at_ms~ : Int64?,
    provider_code~ : String?,
    window_label~ : String?,
    encountered_at_ms~ : Int64,
  )
  TurnFailed(session_id~ : String)
  TurnCompleted(session_id~ : String)
  TimerFired(epoch~ : Int, deadline~ : Int64)
  ResumeCompleted(ticket~ : RecoveryTicket)
  ResumeFailed(ticket~ : RecoveryTicket, error~ : String)
  CancelPending
  Stop
}

priv enum RecoveryQuery {
  Snapshot
  Status
  IsStopped
}

priv enum RecoveryReply {
  SnapshotReply(Array[RateLimitPending])
  StatusReply(RecoveryStatus?)
  StoppedReply(Bool)
}

priv struct RecoveryState {
  pending : Array[RecoveryEntry]
  attempts : Map[String, Int]
  mut epoch : Int
  mut inflight : RecoveryTicket?
  mut stopped : Bool
}

priv struct RuntimeEffects {
  supervisor : @fuwaroid.Supervisor[Unit]
  sleep_ms : async (Int) -> Unit
  resume : async (String) -> Unit
  trace : (String) -> Unit
}

priv struct RateLimitRuntime {
  actor : @fuwaroid.Fuwaroid[RecoveryCommand, RecoveryQuery, RecoveryReply]
  effects : RuntimeEffects
  policy : RecoveryPolicy
}

///|
fn delay_ms(deadline : Int64, now_ms : Int64) -> Int {
  let delta = deadline - now_ms
  if delta <= 0L {
    1
  } else if delta > 2147483647L {
    2147483647
  } else {
    delta.to_int()
  }
}

///|
/// Spawn a stale-safe one-shot timer. We intentionally do not cancel older
/// timers when the schedule moves: their epoch/deadline is validated by the
/// actor when they wake.
fn spawn_timer(
  ctx : @fuwaroid.Ctx[RecoveryCommand, RecoveryQuery, RecoveryReply],
  effects : RuntimeEffects,
  epoch : Int,
  deadline : Int64,
  now_ms : Int64,
) -> Unit {
  let wait = delay_ms(deadline, now_ms)
  let address = ctx.address
  let spawned = effects.supervisor.spawn(
    async fn() {
      (effects.sleep_ms)(wait)
      let _ = address.tell(TimerFired(epoch~, deadline~))
    },
    label="ratelimit-timer",
  )
  match spawned {
    Ok(_) => ()
    Err(_) => (effects.trace)("rate-limit timer refused after supervisor shutdown")
  }
}

///|
fn earliest_armed_deadline(state : RecoveryState) -> Int64? {
  let mut found : Int64? = None
  for entry in state.pending {
    if entry.recovery_ready {
      match found {
        Some(current) =>
          if entry.resume_at_ms < current {
            found = Some(entry.resume_at_ms)
          }
        None => found = Some(entry.resume_at_ms)
      }
    }
  }
  found
}

///|
/// Start at most one recovery. All admission decisions happen in the actor;
/// workers never mutate RecoveryState.
fn dispatch_due(
  ctx : @fuwaroid.Ctx[RecoveryCommand, RecoveryQuery, RecoveryReply],
  state : RecoveryState,
  effects : RuntimeEffects,
  now_ms : Int64,
) -> Unit {
  if state.stopped || state.inflight is Some(_) {
    return
  }
  let mut selected : RecoveryEntry? = None
  for entry in state.pending {
    if entry.recovery_ready && entry.resume_at_ms <= now_ms {
      match selected {
        Some(current) =>
          if entry.resume_at_ms < current.resume_at_ms {
            selected = Some(entry)
          }
        None => selected = Some(entry)
      }
    }
  }
  let entry = match selected {
    Some(entry) => entry
    None => return
  }
  let ticket : RecoveryTicket = {
    session_id: entry.session_id,
    epoch: state.epoch,
    attempt: entry.attempts,
  }
  state.inflight = Some(ticket)
  state.pending = state.pending.filter(fn(item) {
    item.session_id != entry.session_id
  })
  let address = ctx.address
  let resume = effects.resume
  let trace = effects.trace
  let spawned = effects.supervisor.spawn(
    async fn() {
      let outcome : Result[Unit, Error] = Ok(resume(ticket.session_id)) catch {
        error => Err(error)
      }
      match outcome {
        Ok(_) => {
          let _ = address.tell(ResumeCompleted(ticket~))
        }
        Err(error) => {
          let _ = address.tell(
            ResumeFailed(ticket~, error=error.to_string()),
          )
        }
      }
    },
    label="ratelimit-resume",
  )
  match spawned {
    Ok(_) => ()
    Err(_) => {
      state.inflight = None
      trace("rate-limit resume refused after supervisor shutdown")
    }
  }
}

///|
fn record_limit(
  ctx : @fuwaroid.Ctx[RecoveryCommand, RecoveryQuery, RecoveryReply],
  state : RecoveryState,
  effects : RuntimeEffects,
  policy : RecoveryPolicy,
  session_id : String,
  reset_at_ms : Int64?,
  provider_code : String?,
  window_label : String?,
  encountered_at_ms : Int64,
) -> Unit {
  if state.stopped {
    return
  }
  // A late 429 from a recovery invalidated by CancelPending/Stop must never
  // recreate work in the new epoch.
  match state.inflight {
    Some(ticket) if ticket.session_id == session_id &&
      ticket.epoch != state.epoch => {
      (effects.trace)("ignored stale rate-limit failure for session {session_id}")
      return
    }
    _ => ()
  }
  let attempt = match state.attempts.get(session_id) {
    Some(count) => count + 1
    None => 1
  }
  state.attempts[session_id] = attempt
  match policy.schedule(reset_at_ms, attempt, encountered_at_ms) {
    Exhausted => {
      state.pending = state.pending.filter(fn(entry) {
        entry.session_id != session_id
      })
      (effects.trace)(
        "rate-limit resume gave up on session {session_id} after {attempt} attempts",
      )
    }
    Unschedulable => ()
    Scheduled(resume_at_ms) => {
      let entry : RecoveryEntry = {
        session_id,
        encountered_at_ms,
        reset_at_ms,
        resume_at_ms,
        attempts: attempt,
        provider_code,
        window_label,
        recovery_ready: false,
      }
      match find_recovery_index(state.pending, session_id) {
        Some(index) => state.pending[index] = entry
        None => state.pending.push(entry)
      }
      (effects.trace)(
        "rate limit on session {session_id} (code={Repr(provider_code)}), encountered_at_ms={encountered_at_ms}, reset_at_ms={Repr(reset_at_ms)}, resume scheduled at {resume_at_ms}",
      )
      spawn_timer(
        ctx,
        effects,
        state.epoch,
        resume_at_ms,
        encountered_at_ms,
      )
    }
  }
}

///|
fn recovery_fold_cmd(
  ctx : @fuwaroid.Ctx[RecoveryCommand, RecoveryQuery, RecoveryReply],
  state : RecoveryState,
  cmd : RecoveryCommand,
  effects : RuntimeEffects,
  policy : RecoveryPolicy,
) -> RecoveryState {
  match cmd {
    RateLimitObserved(
      session_id~,
      reset_at_ms~,
      provider_code~,
      window_label~,
      encountered_at_ms~,
    ) =>
      record_limit(
        ctx,
        state,
        effects,
        policy,
        session_id,
        reset_at_ms,
        provider_code,
        window_label,
        encountered_at_ms,
      )
    TurnFailed(session_id~) => {
      match find_recovery_index(state.pending, session_id) {
        Some(index) => {
          state.pending[index].recovery_ready = true
          let deadline = state.pending[index].resume_at_ms
          spawn_timer(ctx, effects, state.epoch, deadline, (effects.now_ms)())
        }
        None => ()
      }
    }
    TurnCompleted(session_id~) => {
      state.attempts.remove(session_id)
      state.pending = state.pending.filter(fn(entry) {
        entry.session_id != session_id
      })
      match state.inflight {
        Some(ticket) if ticket.session_id == session_id => state.inflight = None
        _ => ()
      }
      dispatch_due(ctx, state, effects, 9223372036854775807L)
    }
    TimerFired(epoch~, deadline~) => {
      if epoch == state.epoch {
        let still_relevant = state.pending.any(fn(entry) {
          entry.recovery_ready && entry.resume_at_ms == deadline
        })
        if still_relevant {
          dispatch_due(ctx, state, effects, deadline)
        }
      }
    }
    ResumeCompleted(ticket~) => {
      match state.inflight {
        Some(current) if current == ticket => {
          state.inflight = None
          if ticket.epoch == state.epoch {
            state.attempts.remove(ticket.session_id)
            dispatch_due(ctx, state, effects, 9223372036854775807L)
          }
        }
        _ => ()
      }
    }
    ResumeFailed(ticket~, error~) => {
      match state.inflight {
        Some(current) if current == ticket => {
          state.inflight = None
          if ticket.epoch == state.epoch {
            let re_recorded = find_recovery_index(
              state.pending,
              ticket.session_id,
            ) is Some(_)
            if re_recorded {
              (effects.trace)(
                "rate-limit recovery for session {ticket.session_id} hit another rate limit",
              )
            } else {
              (effects.trace)(
                "rate-limit recovery failed without retry for session {ticket.session_id}: {error}",
              )
            }
            dispatch_due(ctx, state, effects, 9223372036854775807L)
          }
        }
        _ => ()
      }
    }
    CancelPending => {
      state.epoch = state.epoch + 1
      state.pending = []
      state.attempts.clear()
      (effects.trace)("rate-limit recovery pending work cancelled")
    }
    Stop => {
      state.stopped = true
      state.epoch = state.epoch + 1
      state.pending = []
      state.attempts.clear()
    }
  }
  state
}

///|
fn recovery_fold_query(
  _ctx : @fuwaroid.Ctx[RecoveryCommand, RecoveryQuery, RecoveryReply],
  state : RecoveryState,
  query : RecoveryQuery,
) -> (RecoveryState, RecoveryReply) {
  let reply = match query {
    Snapshot => SnapshotReply(recovery_snapshot(state.pending))
    Status => StatusReply(recovery_status(state.pending))
    IsStopped => StoppedReply(state.stopped)
  }
  (state, reply)
}

///|
fn RateLimitRuntime::start(
  group~ : @async.TaskGroup[Unit],
  policy~ : RecoveryPolicy,
  sleep_ms~ : async (Int) -> Unit,
  resume~ : async (String) -> Unit,
  trace~ : (String) -> Unit,
) -> RateLimitRuntime {
  let supervisor : @fuwaroid.Supervisor[Unit] = @fuwaroid.Supervisor(group~)
  let effects : RuntimeEffects = { supervisor, now_ms, sleep_ms, resume, trace, }
  let init : RecoveryState = {
    pending: [],
    attempts: Map::from_array([]),
    epoch: 0,
    inflight: None,
    stopped: false,
  }
  {
    actor: @fuwaroid.Fuwaroid::spawn(
      group~,
      init~,
      on_cmd=fn(ctx, state, cmd) {
        recovery_fold_cmd(ctx, state, cmd, effects, policy)
      },
      on_query=recovery_fold_query,
    ),
    effects,
    policy,
  }
}

///|
fn RateLimitRuntime::tell(
  self : RateLimitRuntime,
  cmd : RecoveryCommand,
) -> Unit {
  let _ = self.actor.tell(cmd)
}

///|
async fn RateLimitRuntime::snapshot(
  self : RateLimitRuntime,
) -> Array[RateLimitPending] {
  match self.actor.ask(Snapshot, timeout_ms=5000) {
    Ok(SnapshotReply(value)) => value
    _ => []
  }
}

///|
async fn RateLimitRuntime::status(
  self : RateLimitRuntime,
) -> RecoveryStatus? {
  match self.actor.ask(Status, timeout_ms=5000) {
    Ok(StatusReply(value)) => value
    _ => None
  }
}

///|
async fn RateLimitRuntime::shutdown(
  self : RateLimitRuntime,
  timeout_ms : Int,
) -> Unit {
  self.tell(Stop)
  self.actor.close()
  let _ = self.effects.supervisor.shutdown(timeout_ms~)
  let _ = self.actor.join()
}
