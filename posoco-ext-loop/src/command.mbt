///|
/// A single raw positional argument preserves the user's exact task wording.
/// JS hosts already support this shape; other hosts can call the same
/// CommandPort with {"input":"5m check CI"}.
pub impl @posoco.CommandPort for LoopExtension with fn commands(
  _self : LoopExtension,
) -> Array[@posoco.CommandDef] {
  [
    @posoco.CommandDef::{
      id: "loop",
      label: "Recurring Tasks",
      description: "Schedule repeated tasks: /loop 5m <task>, /loop list, /loop pause|resume|stop <id>",
      category: "automation",
      ctype: @posoco.CommandType::Action,
      params: [
        @posoco.CommandParam::{
          name: "input",
          label: "Loop instruction",
          description: "Interval and task or a loop management action",
          ptype: @posoco.ParamType::Str,
          required: false,
          default: None,
          choices: None,
          positional: true,
        },
      ],
      aliases: [],
      shortcut: None,
      icon: None,
      visible: true,
      metadata: None,
    },
  ]
}

///|
pub extend LoopExtension with @posoco.CommandPort::{commands, invoke}

///|
fn loop_raw_args(args : Json) -> Result[String, String] {
  match args {
    Json::Null => Ok("")
    Json::String(raw) => Ok(raw)
    Json::Object(fields) => {
      let raw = match fields.get("input") {
        Some(value) => Some(value)
        None => fields.get("_positional")
      }
      match raw {
        Some(Json::String(value)) => Ok(value)
        None => Ok("")
        _ => Err("loop input must be a string")
      }
    }
    _ => Err("loop expects a string or an object with input")
  }
}

///|
async fn loop_runtime_change_safe(
  runtime : LoopRuntime,
  request : LoopRequest,
) -> Result[String, String] {
  runtime.change(request) catch {
    error => Err(error.to_string())
  }
}

///|
fn loop_job_json(job : LoopJob) -> Json {
  Json::object({
    "id": Json::string(job.id),
    "session_id": Json::string(job.session_id),
    "prompt": Json::string(job.prompt),
    "interval_ms": Json::number(job.interval_ms.to_double()),
    "next_due_at_ms": Json::number(job.next_due_at_ms.to_double()),
    "status": Json::string(job.status),
    "run_count": Json::number(job.run_count.to_double()),
    "failure_count": Json::number(job.failure_count.to_double()),
  })
}

///|
fn loop_action_success(
  message : String,
  jobs : Array[LoopJob],
) -> @posoco.CommandOutcome {
  @posoco.CommandOutcome::Success(
    feedback=message,
    structured=Some(
      Json::object({
        "kind": Json::string("posoco_loop"),
        "jobs": Json::array(jobs.map(fn(job) { loop_job_json(job) })),
      }),
    ),
    ui_hint=Some(@posoco.UiHint::Toast),
  )
}

///|
fn loop_job_list_text(jobs : Array[LoopJob]) -> String {
  if jobs.is_empty() {
    return "No loops in this Agent lifetime."
  }
  let out = StringBuilder()
  for job in jobs {
    out.write_string(
      job.id + " [" + job.status + "] every " +
      (job.interval_ms / 1000L).to_string() + "s" +
      " (runs=" + job.run_count.to_string() + ") " +
      job.prompt + "\n",
    )
  }
  out.to_string()
}

///|
pub impl @posoco.CommandPort for LoopExtension with fn invoke(
  self : LoopExtension,
  id : String,
  args : Json,
) -> @posoco.CommandOutcome raise @posoco.CommandError {
  if id != "loop" {
    raise @posoco.CommandError::NotFound(id)
  }
  let raw = match loop_raw_args(args) {
    Ok(value) => value
    Err(reason) => return @posoco.CommandOutcome::Failure(reason~)
  }
  let action = match parse_loop_action(raw) {
    Ok(action) => action
    Err(reason) => return @posoco.CommandOutcome::Failure(reason~)
  }
  let runtime = match self.runtime {
    Some(runtime) => runtime
    None =>
      return @posoco.CommandOutcome::Failure(
        reason="loop scheduler not started: host must call loop.start(group~, agent~)",
      )
  }
  let outcome : Result[String, String] = match action {
    ListJobs => Ok("list")
    CreateJob(interval_ms~, prompt~) =>
      match self.session_id {
        Some(session_id) =>
          loop_runtime_change_safe(runtime, Add(session_id~, interval_ms~, prompt~))
        None => Err("no active session: host must call loop.set_session(id)")
      }
    PauseJob(id~) => loop_runtime_change_safe(runtime, Pause(id~))
    ResumeJob(id~) => loop_runtime_change_safe(runtime, Resume(id~))
    StopJob(id~) => loop_runtime_change_safe(runtime, Stop(id~))
  }
  match outcome {
    Err(reason) => @posoco.CommandOutcome::Failure(reason~)
    Ok(result) => {
      let jobs = runtime.jobs() catch { _ => [] }
      let feedback = match action {
        ListJobs => loop_job_list_text(jobs)
        CreateJob(..) => "created recurring task " + result
        PauseJob(..) | ResumeJob(..) | StopJob(..) => result
      }
      loop_action_success(feedback, jobs)
    }
  }
}
