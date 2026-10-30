///|
/// Bounded tone set of the host contract. An unrecognised kind is still a
/// perfectly good update, so it renders with the neutral tone instead of being
/// dropped or given a colour the stylesheet does not define.
fn ticket_progress_kind(kind : String) -> String {
  match kind {
    "milestone" | "attention" | "blocked" => kind
    _ => "normal"
  }
}

///|
/// Human label of one update tone. The word carries the meaning, so colour is
/// never the only signal.
fn ticket_progress_kind_label(kind : String) -> String {
  match kind {
    "milestone" => "Milestone"
    "attention" => "Attention"
    "blocked" => "Blocked"
    _ => "Update"
  }
}

///|
/// Identity of one update for seen tracking. The host may rewrite its bounded
/// progress list between snapshots, so updates are matched by content rather
/// than by index: the same update delivered twice is still one update.
fn ticket_progress_key(update : TicketProgress) -> String {
  "\{update.task_id}|\{update.at_ms}|\{update.kind}|\{update.message}"
}

///|
/// The progress list newest first. The replica's own array is detached, so
/// ordering never leaks into a previous model.
fn ticket_progress_latest_first(
  updates : Array[TicketProgress],
) -> Array[TicketProgress] {
  let ordered = updates.copy()
  ordered.sort_by((left, right) => right.at_ms.compare(left.at_ms))
  ordered
}

///|
/// Seen set for a set of updates. It is rebuilt from the current list instead
/// of accumulated, so identities the host dropped never linger.
fn ticket_progress_seen(updates : Array[TicketProgress]) -> Map[String, Bool] {
  let seen : Map[String, Bool] = Map([])
  for update in updates {
    seen[ticket_progress_key(update)] = true
  }
  seen
}

///|
/// Keep only the seen identities that are still in the authoritative list. A
/// torn-down worker's updates leave the inbox and their keys leave the model.
fn ticket_progress_retain_seen(
  seen : Map[String, Bool],
  updates : Array[TicketProgress],
) -> Map[String, Bool] {
  let kept : Map[String, Bool] = Map([])
  for update in updates {
    let key = ticket_progress_key(update)
    if seen.contains(key) {
      kept[key] = true
    }
  }
  kept
}

///|
/// Short "how long ago" label for one update. The observation time is passed
/// in so the inbox stays a pure projection and tests can pin it; anything older
/// than a month falls back to UTC civil time instead of an implausible count.
fn ticket_progress_age(at_ms : Int64, now_ms : Int64) -> String {
  let age = now_ms - at_ms
  if age < 3600000L {
    if age < 60000L {
      "just now"
    } else {
      "\{age / 60000L}m ago"
    }
  } else if age < 86400000L {
    "\{age / 3600000L}h ago"
  } else if age < 2592000000L {
    "\{age / 86400000L}d ago"
  } else {
    utc_timestamp(at_ms)
  }
}

///|
/// One inbox update row with everything the renderer needs already resolved.
/// Keeping this projection pure lets tests pin the rendered text and tone
/// without a DOM.
priv struct InboxUpdate {
  task_id : String
  /// Ticket title, or the id when the replica cannot resolve the task.
  title : String
  kind : String
  kind_label : String
  message : String
  at_ms : Int64
  time_label : String
  unseen : Bool
}

///|
/// The update rows the inbox renders, newest first.
fn inbox_updates(model : Model, now_ms : Int64) -> Array[InboxUpdate] {
  ticket_progress_latest_first(model.tickets.progress).map(update => {
    let seen = model.ticket_seen_updates.contains(ticket_progress_key(update))
    {
      task_id: update.task_id,
      title: match task_by_id(model.replica, update.task_id) {
        Some(task) => task.title
        None => update.task_id
      },
      kind: update.kind,
      kind_label: ticket_progress_kind_label(update.kind),
      message: update.message,
      at_ms: update.at_ms,
      time_label: ticket_progress_age(update.at_ms, now_ms),
      unseen: !seen,
    }
  })
}

///|
/// The most recent update of one ticket, if its worker reported any. The
/// Activity dialog shows it above the live run so progress is visible where
/// the run is inspected.
fn ticket_latest_update(model : Model, task_id : String) -> TicketProgress? {
  let mut latest : TicketProgress? = None
  for update in model.tickets.progress {
    if update.task_id == task_id {
      match latest {
        Some(previous) if previous.at_ms >= update.at_ms => ()
        _ => latest = Some(update)
      }
    }
  }
  latest
}

///|
fn is_customer_question(question : TicketQuestion) -> Bool {
  question.audience == "customer" || question.audience == "sm"
}

///|
fn ticket_question_count(model : Model) -> Int32 {
  let mut count = 0
  for question in model.tickets.questions {
    if is_customer_question(question) {
      count += 1
    }
  }
  count
}

///|
/// Worker updates the user has not looked at yet. Opening the inbox records the
/// list that was on screen as seen; anything a worker reports afterwards is
/// unseen again until the next open.
fn ticket_unseen_update_count(model : Model) -> Int32 {
  let mut count = 0
  for update in model.tickets.progress {
    if !model.ticket_seen_updates.contains(ticket_progress_key(update)) {
      count += 1
    }
  }
  count
}

///|
/// The inbox badge counts both things waiting for a human: open questions that
/// need an answer, and worker updates that arrived since the inbox was opened.
fn ticket_inbox_count(model : Model) -> Int32 {
  ticket_question_count(model) + ticket_unseen_update_count(model)
}

///|
/// Header and section wording for the unseen updates. Plain words, never a raw
/// count with no noun.
fn ticket_update_count_label(count : Int32) -> String {
  if count == 1 {
    "1 new update"
  } else {
    "\{count} new updates"
  }
}

///|
/// Total update count for the header chip, separate from the unseen count so
/// the inbox still reports how much the workers said when nothing is new.
fn ticket_update_total_label(count : Int32) -> String {
  if count == 1 {
    "1 update"
  } else {
    "\{count} updates"
  }
}

