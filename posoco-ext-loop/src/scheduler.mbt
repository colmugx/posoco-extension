///|
/// A single-writer, session-scoped recurring task scheduler. All user-facing
/// mutations and timer/worker completions are serialized by a Fuwaroid actor.
/// The ticker is a supervised effect; it never mutates state directly.
priv enum LoopSignal {
  Tick(now_ms~ : Int64)
  Finished(id~ : String, generation~ : Int32, result~ : DispatchResult)
  Bound(session_id~ : String?)
  Halt
}

///|
priv enum DispatchResult {
  Done
  Busy
  Error(String)
}

///|
priv enum LoopRequest {
  Add(session_id~ : String, interval_ms~ : Int64, prompt~ : String)
  Pause(id~ : String)
  Resume(id~ : String)
  Stop(id~ : String)
  List
}

///|
priv enum LoopReply {
  Action(Result[String, String])
  Jobs(Array[LoopJob])
}

///|
priv struct LoopState {
  mut jobs : Array[LoopEntry]
  mut sequence : Int32
  mut bound_session : String?
  mut stopped : Bool
}

///|
priv struct LoopEffects {
  supervisor : @fuwaroid.Supervisor[Unit]
  now_ms : () -> Int64
  execute : async (String, String) -> DispatchResult
  trace : (String) -> Unit
  max_failures : Int32
}

///|
priv struct LoopRuntime {
  actor : @fuwaroid.Fuwaroid[LoopSignal, LoopRequest, LoopReply]
  effects : LoopEffects
}

///|
fn loop_find(jobs : Array[LoopEntry], id : String) -> LoopEntry? {
  for job in jobs {
    if job.id == id {
      return Some(job)
    }
  }
  None
}

///|
fn loop_snapshot(jobs : Array[LoopEntry]) -> Array[LoopJob] {
  jobs.map(fn(job) { job.snapshot() })
}

///|
fn loop_next_due(now_ms : Int64, interval_ms : Int64) -> Int64 {
  // A fixed DELAY from the latest settled invocation, not a catch-up clock.
  now_ms + interval_ms
}

///|
/// Schedule a worker only after admission through the actor. The Posoco
/// single-operation guard enforces agent exclusivity: Busy is not a failure.
fn loop_dispatch(
  ctx : @fuwaroid.Ctx[LoopSignal, LoopRequest, LoopReply],
  job : LoopEntry,
  effects : LoopEffects,
) -> Unit {
  let address = ctx.address
  let id = job.id
  let generation = job.generation
  let session_id = job.session_id
  let prompt = job.prompt
  let result = effects.supervisor.spawn(
    async fn() {
      let outcome : DispatchResult = (effects.execute)(session_id, prompt)
      let _ = address.tell(Finished(id~, generation~, result=outcome))
    },
    label="loop-turn",
  )
  match result {
    Ok(_) => ()
    Err(_) => {
      job.status = "paused"
      job.failure_count = job.failure_count + 1
      (effects.trace)("loop supervisor rejected worker for " + id)
    }
  }
}

///|
/// The tick never blocks on a model call. Overdue jobs schedule once and are
/// then marked running; no interval catch-up or overlapping job execution.
fn loop_tick(
  ctx : @fuwaroid.Ctx[LoopSignal, LoopRequest, LoopReply],
  state : LoopState,
  effects : LoopEffects,
  now_ms : Int64,
) -> Unit {
  if state.stopped {
    return
  }
  for job in state.jobs {
    if job.status == "scheduled" && job.next_due_at_ms <= now_ms &&
      state.bound_session == Some(job.session_id) {
      job.status = "running"
      loop_dispatch(ctx, job, effects)
    }
  }
}

///|
fn loop_finished(
  state : LoopState,
  effects : LoopEffects,
  id : String,
  generation : Int32,
  result : DispatchResult,
) -> Unit {
  let job = match loop_find(state.jobs, id) {
    Some(value) => value
    None => return
  }
  if state.stopped || job.generation != generation || job.status != "running" {
    return
  }
  let now_ms = (effects.now_ms)()
  match result {
    Done => {
      job.run_count = job.run_count + 1
      job.failure_count = 0
      job.status = "scheduled"
      job.next_due_at_ms = loop_next_due(now_ms, job.interval_ms)
    }
    Busy => {
      // The user turn (or another extension) owns the Agent. Retry only
      // admission, without duplicating a turn or charging a failure.
      job.status = "scheduled"
      job.next_due_at_ms = now_ms + 500L
    }
    Error(reason) => {
      job.run_count = job.run_count + 1
      job.failure_count = job.failure_count + 1
      (effects.trace)("loop " + id + " failed: " + reason)
      if job.failure_count >= effects.max_failures {
        job.status = "paused"
      } else {
        job.status = "scheduled"
        job.next_due_at_ms = loop_next_due(now_ms, job.interval_ms)
      }
    }
  }
}

///|
fn loop_fold_signal(
  ctx : @fuwaroid.Ctx[LoopSignal, LoopRequest, LoopReply],
  state : LoopState,
  cmd : LoopSignal,
  effects : LoopEffects,
) -> LoopState {
  match cmd {
    Tick(now_ms~) => loop_tick(ctx, state, effects, now_ms)
    Finished(id~, generation~, result~) =>
      loop_finished(state, effects, id, generation, result)
    Bound(session_id~) => {
      // Jobs for other sessions stay dormant. Returning to a session
      // causes at most one overdue run, never a missed-tick avalanche.
      state.bound_session = session_id
    }
    Halt => state.stopped = true
  }
  state
}

///|
fn loop_fold_request(
  _ctx : @fuwaroid.Ctx[LoopSignal, LoopRequest, LoopReply],
  state : LoopState,
  request : LoopRequest,
  effects : LoopEffects,
) -> (LoopState, LoopReply) {
  let reply = if state.stopped {
    Action(Err("loop scheduler has shut down"))
  } else {
    match request {
      List => Jobs(loop_snapshot(state.jobs))
      Add(session_id~, interval_ms~, prompt~) => {
        if state.bound_session != Some(session_id) {
          Action(Err("loop session is not active"))
        } else if interval_ms < 1000L || interval_ms > 86400000L ||
          prompt.trim() == "" {
          Action(Err("invalid loop interval or empty task"))
        } else {
          let live = state.jobs.filter(fn(job) { job.status != "stopped" })
          if live.length() >= 16 {
            Action(Err("loop limit reached (16 active jobs)"))
          } else {
            // Retire stopped entries as needed to keep actor state bounded.
            state.jobs = live
            state.sequence = state.sequence + 1
            let id = "loop_" + state.sequence.to_string()
            let entry : LoopEntry = {
              id,
              session_id,
              prompt,
              interval_ms,
              next_due_at_ms: loop_next_due((effects.now_ms)(), interval_ms),
              status: "scheduled",
              generation: 1,
              run_count: 0,
              failure_count: 0,
            }
            state.jobs.push(entry)
            Action(Ok(id))
          }
        }
      }
      Pause(id~) =>
        match loop_find(state.jobs, id) {
          Some(job) if job.status == "scheduled" || job.status == "running" => {
            job.generation = job.generation + 1
            job.status = "paused"
            Action(Ok("paused " + id))
          }
          Some(job) if job.status == "paused" =>
            Action(Ok("already paused " + id))
          _ => Action(Err("loop is not active: " + id))
        }
      Resume(id~) =>
        match loop_find(state.jobs, id) {
          Some(job) if job.status == "paused" => {
            job.generation = job.generation + 1
            job.failure_count = 0
            job.status = "scheduled"
            job.next_due_at_ms = loop_next_due(
              (effects.now_ms)(),
              job.interval_ms,
            )
            Action(Ok("resumed " + id))
          }
          _ => Action(Err("loop is not paused: " + id))
        }
      Stop(id~) =>
        match loop_find(state.jobs, id) {
          Some(job) if job.status != "stopped" => {
            job.generation = job.generation + 1
            job.status = "stopped"
            Action(Ok("stopped " + id))
          }
          _ => Action(Err("loop not found or already stopped: " + id))
        }
    }
  }
  (state, reply)
}

///|
/// The caller owns the TaskGroup, matching posoco-ext-ratelimit's lifetime
/// convention. No Agent is invoked from a timer or the Fuwaroid reducer.
fn LoopRuntime::start(
  group~ : @async.TaskGroup,
  now_ms~ : () -> Int64,
  sleep_ms~ : async (Int32) -> Unit,
  execute~ : async (String, String) -> DispatchResult,
  trace~ : (String) -> Unit,
  max_failures~ : Int32,
  bound_session~ : String?,
) -> LoopRuntime {
  let supervisor : @fuwaroid.Supervisor[Unit] = @fuwaroid.Supervisor(group~)
  let effects : LoopEffects = {
    supervisor,
    now_ms,
    execute,
    trace,
    max_failures,
  }
  let initial : LoopState = {
    jobs: [],
    sequence: 0,
    bound_session,
    stopped: false,
  }
  let actor = @fuwaroid.Fuwaroid::spawn(
    group~,
    init=initial,
    on_cmd=fn(ctx, state, cmd) {
      loop_fold_signal(ctx, state, cmd, effects)
    },
    on_query=fn(ctx, state, query) {
      loop_fold_request(ctx, state, query, effects)
    },
  )
  let ticker_actor = actor
  // One bounded supervised ticker. Unlike a timer per edited job, repeated
  // pause/resume cannot accumulate arbitrarily many sleeping tasks.
  let ticker = supervisor.spawn(
    async fn() {
      while true {
        sleep_ms(250)
        let _ = ticker_actor.tell(Tick(now_ms=now_ms()))
      }
    },
    label="loop-ticker",
  )
  match ticker {
    Ok(_) => ()
    Err(_) => trace("loop ticker failed to start")
  }
  { actor, effects }
}

///|
async fn LoopRuntime::change(
  self : LoopRuntime,
  request : LoopRequest,
) -> Result[String, String] {
  match self.actor.ask(request, timeout_ms=5000) {
    Ok(Action(result)) => result
    _ => Err("loop scheduler unavailable")
  }
}

///|
async fn LoopRuntime::jobs(self : LoopRuntime) -> Array[LoopJob] {
  match self.actor.ask(List, timeout_ms=5000) {
    Ok(Jobs(jobs)) => jobs
    _ => []
  }
}

///|
fn LoopRuntime::bind(self : LoopRuntime, session_id : String?) -> Unit {
  let _ = self.actor.tell(Bound(session_id~))
}

///|
/// Exposed for deterministic tests and external clocks. Ordinary hosts use
/// the supervised 250ms tick; no background polling runs outside its scope.
async fn LoopRuntime::poll(self : LoopRuntime) -> Unit {
  let _ = self.actor.tell(Tick(now_ms=(self.effects.now_ms)()))
  ignore(self.jobs())
}

///|
async fn LoopRuntime::shutdown(self : LoopRuntime) -> Unit {
  let _ = self.actor.tell(Halt)
  self.actor.close()
  let _ = self.effects.supervisor.shutdown(timeout_ms=5000)
  let _ = self.actor.join()
}
