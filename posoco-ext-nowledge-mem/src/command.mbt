///|
/// Timeout for the `/memory status` MCP connectivity probe — a diagnostics
/// surface should fail faster than the tool budget.
const NMEM_COMMAND_STATUS_TIMEOUT_MS : Int = 10000

///|
/// Thread id of a lane key: the segment after the NUL separator (the sha256
/// hex prefix never contains NUL, so the first NUL is the boundary).
fn lane_thread_id(lane_key : String) -> String {
  match lane_key.find("\u{0}") {
    Some(at) => lane_key[at + 1:].to_owned()
    None => lane_key
  }
}

///|
/// Cap on the status probe excerpt embedded in the report line.
const NMEM_STATUS_REPORT_CHARS : Int = 200

///|
/// `/memory status`: one MCP probe plus the extension's own state —
/// connectivity, one line per thread lane, the write-after queue depth, and
/// the passive-read gate. Returns the text report and its structured twin.
async fn NowledgeMem::memory_status_report(
  self : NowledgeMem,
) -> (String, Json) {
  let probe : Result[String, String] = try
    self.mcp.probe(timeout_ms=NMEM_COMMAND_STATUS_TIMEOUT_MS)
  catch {
    err => Err("probe raised: " + err.to_string())
  } noraise {
    value => value
  }
  let lines : Array[String] = []
  let lanes_json : Array[Json] = []
  let connectivity = match probe {
    Ok(report) => {
      let excerpt = take_prefix(
        report.trim().to_owned(),
        NMEM_STATUS_REPORT_CHARS,
      )
      lines.push("nowledge-mem: connected (\{excerpt})")
      true
    }
    Err(detail) => {
      lines.push(
        "nowledge-mem: unreachable (\{take_prefix(detail, NMEM_TOOL_ERROR_CHARS)})",
      )
      false
    }
  }
  if self.engine.lanes.length() == 0 {
    lines.push("thread lanes: none yet")
  } else {
    lines.push("thread lanes:")
    for lane_key, lane in self.engine.lanes {
      let acknowledged = match lane.acknowledged {
        Some(acked) => acked.count
        None => 0
      }
      let last_error = match lane.last_error {
        Some(err) => err
        None => "none"
      }
      lines.push(
        "  \{lane_thread_id(lane_key)}: created=\{lane.created}, acknowledged=\{acknowledged}, pending=\{lane.pending is Some(_)}, last_error=\{last_error}",
      )
      lanes_json.push(
        Json::object({
          "thread_id": Json::string(lane_thread_id(lane_key)),
          "created": Json::boolean(lane.created),
          "acknowledged": Json::number(acknowledged.to_double()),
          "pending": Json::boolean(lane.pending is Some(_)),
          "last_error": match lane.last_error {
            Some(err) => Json::string(err)
            None => Json::null()
          },
        }),
      )
    }
  }
  lines.push("memory queue: \{self.mem.queue.length()} pending write(s)")
  lines.push(
    "passive read: \{if self.passive_read_done { "done" } else { "pending" }}",
  )
  match self.mem.last_error {
    Some(err) => lines.push("memory last_error: \{err}")
    None => ()
  }
  let structured = Json::object({
    "nmem_connected": Json::boolean(connectivity),
    "lanes": Json::array(lanes_json),
    "queue_depth": Json::number(self.mem.queue.length().to_double()),
    "passive_read_done": Json::boolean(self.passive_read_done),
    "memory_last_error": match self.mem.last_error {
      Some(err) => Json::string(err)
      None => Json::null()
    },
  })
  (lines.join("\n"), structured)
}

///|
/// `/memory` usage — the outcome for a bare invocation or an unknown
/// subcommand.
fn memory_usage() -> String {
  (
    #|/memory — Nowledge Mem diagnostics
    #|  /memory status   nmem connectivity, thread lanes, write queue, passive-read gate
    #|  /memory flush    drain pending thread lanes and queued memory writes now
  )
}

///|
/// Optional subcommand: no arguments, a bare string, or an `{action}`
/// object (same contract shape as /plan).
fn parse_memory_action(args : Json) -> String? raise @posoco.CommandError {
  match args {
    Json::Null => None
    Json::String(value) => {
      let trimmed = value.trim().to_owned()
      if trimmed == "" {
        None
      } else {
        Some(trimmed)
      }
    }
    Json::Object(fields) =>
      match fields.get("action") {
        None => None
        Some(Json::String(value)) => {
          let trimmed = value.trim().to_owned()
          if trimmed == "" {
            None
          } else {
            Some(trimmed)
          }
        }
        Some(_) =>
          raise @posoco.CommandError::InvalidArgs(
            reason="/memory: 'action' must be a string",
          )
      }
    _ =>
      raise @posoco.CommandError::InvalidArgs(
        reason="/memory expects no arguments, an action string, or {action}",
      )
  }
}

///|
/// Count lanes with a pending flush.
fn pending_lane_count(engine : SyncEngine) -> Int {
  let mut count = 0
  for _, lane in engine.lanes {
    if lane.pending is Some(_) {
      count = count + 1
    }
  }
  count
}

///|
/// `/memory` — the synchronous diagnostics surface over the extension's own
/// state (the Observer port is core-to-extension read-only, so without this
/// command a lane's `last_error` would live only in memory). `status`
/// reports connectivity + lanes + queue + the passive-read gate; `flush`
/// forces one drain. Connection management (endpoint switching for nmem
/// cloud and friends) lives on the sibling `/nmem` command.
pub impl @posoco.CommandPort for NowledgeMem with fn commands(
  _self : NowledgeMem,
) -> Array[@posoco.CommandDef] {
  [
    @posoco.CommandDef::{
      id: "memory",
      label: "Nowledge Mem",
      description: "Inspect and maintain Nowledge Mem: status (connectivity, thread lanes, write queue), flush pending writes",
      category: "memory",
      ctype: @posoco.CommandType::Action,
      params: [
        @posoco.CommandParam::{
          name: "action",
          label: "Action",
          description: "status / flush (default: usage)",
          ptype: @posoco.ParamType::Str,
          required: false,
          default: None,
          choices: Some(["status", "flush"]),
          positional: true,
        },
      ],
      aliases: [],
      shortcut: None,
      icon: None,
      visible: true,
      metadata: None,
    },
    nmem_command_def(),
  ]
}

///|
pub impl @posoco.CommandPort for NowledgeMem with fn invoke(
  self : NowledgeMem,
  id : String,
  args : Json,
) -> @posoco.CommandOutcome raise @posoco.CommandError {
  match id {
    "memory" => self.invoke_memory(args)
    "nmem" => self.invoke_nmem(args)
    _ => raise @posoco.CommandError::NotFound(id)
  }
}

///|
/// The `/memory` body behind the id dispatch.
async fn NowledgeMem::invoke_memory(
  self : NowledgeMem,
  args : Json,
) -> @posoco.CommandOutcome raise @posoco.CommandError {
  match parse_memory_action(args) {
    None =>
      @posoco.CommandOutcome::Success(
        feedback=memory_usage(),
        structured=None,
        ui_hint=None,
      )
    Some("status") => {
      let reported : (String, Json)? = try self.memory_status_report() catch {
        _ => None
      } noraise {
        pair => Some(pair)
      }
      match reported {
        Some((report, structured)) =>
          @posoco.CommandOutcome::Success(
            feedback=report,
            structured=Some(structured),
            ui_hint=None,
          )
        None =>
          @posoco.CommandOutcome::Failure(
            reason="/memory status failed: the nmem status probe raised",
          )
      }
    }
    Some("flush") => {
      let lanes_attempted = pending_lane_count(self.engine)
      let flushed : Bool = try {
        self.flush_pending()
        true
      } catch {
        _ => false
      } noraise {
        ok => ok
      }
      if !flushed {
        return @posoco.CommandOutcome::Failure(
          reason="/memory flush failed: the drain raised",
        )
      }
      let remaining = self.mem.queue.length()
      let feedback = if remaining == 0 {
        "memory flush complete: \{lanes_attempted} lane(s) attempted, write queue empty"
      } else {
        "memory flush attempted: \{lanes_attempted} lane(s), \{remaining} write(s) still queued (failures retry on the next drain)"
      }
      @posoco.CommandOutcome::Success(
        feedback~,
        structured=Some(
          Json::object({
            "lanes_attempted": Json::number(lanes_attempted.to_double()),
            "queue_remaining": Json::number(remaining.to_double()),
          }),
        ),
        ui_hint=Some(@posoco.UiHint::Toast),
      )
    }
    Some(other) =>
      @posoco.CommandOutcome::Failure(
        reason="unknown /memory action '\{other}'\n\{memory_usage()}",
      )
  }
}

///|
pub extend NowledgeMem with @posoco.CommandPort::{commands, invoke}
