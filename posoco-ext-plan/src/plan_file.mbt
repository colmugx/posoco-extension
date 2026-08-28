///|
/// Plan-file persistence — "一边计划一边写进计划文件".
///
/// With a `WorkspaceFs` injected, planning is not in-memory only: the
/// assistant's planning narrative accumulates into a session-scoped draft
/// (`.cetas/plan/<session>.md`, rewritten whole each planning round), and
/// when the model submits the plan through the exit tool it also gives the
/// plan a name — the final file lands as
/// `.cetas/plan/<name>_<session>.md` and the draft is removed. Persistence
/// is best-effort: a filesystem failure never fails the tool call, the
/// result text just omits the saved-path line.

///|
/// Directory convention under the workspace root.
fn plan_dir() -> String {
  ".cetas/plan"
}

///|
/// Session label used in file names; "session" when the host never set one.
fn PlanMode::session_label(self : PlanMode) -> String {
  if self.session_name.length() == 0 {
    "session"
  } else {
    self.session_name
  }
}

///|
/// Reduce a model-chosen plan name to a filename-safe slug: whitespace and
/// path/hostile characters become `-`, runs collapse, edges trim, the
/// result caps at 80 chars; `plan` when nothing usable remains.
fn sanitize_plan_name(name : String) -> String {
  let collapsed = StringBuilder::new()
  let mut previous_dash = true // true skips a leading dash
  for ch in name {
    let code = ch.to_int()
    let dash = code < 0x20 ||
      code == 0x7f ||
      ch is ('/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' | ' ' | '\t')
    if dash {
      if !previous_dash {
        collapsed.write_char('-')
      }
      previous_dash = true
    } else {
      collapsed.write_char(ch)
      previous_dash = false
    }
  }
  let slug = collapsed.to_string()
  // previous_dash == true at the end also means no trailing dash was
  // written; the only leftover case is an all-dash slug like "-" itself.
  let bounded = if slug.length() > 80 {
    slug.sub(end=80).to_owned()
  } else {
    slug
  }
  if bounded.length() == 0 || bounded == "-" {
    "plan"
  } else {
    bounded
  }
}

///|
fn draft_file_path(session : String) -> String {
  "\{plan_dir()}/\{sanitize_plan_name(session)}.md"
}

///|
fn final_file_path(name : String, session : String) -> String {
  "\{plan_dir()}/\{sanitize_plan_name(name)}_\{sanitize_plan_name(session)}.md"
}

///|
/// Capture assistant narrative not yet recorded into the in-memory draft.
/// Called from `before_model` on planning rounds; message-kind filtering
/// keeps injected reminders (user messages) out. A shrunken transcript
/// (compaction) resets the counter instead of mis-aligning.
fn PlanMode::record_draft_delta(
  self : PlanMode,
  messages : Array[@kernel.Message],
) -> Unit {
  let mut total = 0
  let block = StringBuilder::new()
  for msg in messages {
    if msg is AssistantMessage(..) {
      if total >= self.draft_recorded {
        match msg {
          AssistantMessage(content~, ..) => {
            if block.to_string().length() > 0 {
              block.write_string("\n\n")
            }
            for part in content {
              match part {
                Text(text) => block.write_string(text)
                _ => ()
              }
            }
          }
          _ => ()
        }
      }
      total += 1
    }
  }
  if total < self.draft_recorded {
    // Compaction shrank the transcript; resume from the new tail.
    self.draft_recorded = total
  } else if block.to_string().length() > 0 {
    if self.draft.length() > 0 {
      self.draft = self.draft + "\n\n"
    }
    self.draft = self.draft + block.to_string()
    self.draft_recorded = total
  }
}

///|
/// Rewrite the session draft file with the accumulated narrative. Whole
/// rewrite per round keeps the IO surface to `write_file` only.
async fn PlanMode::write_draft(self : PlanMode) -> Unit noraise {
  match self.fs {
    Some(fs) =>
      if self.draft.length() > 0 {
        let path = draft_file_path(self.session_label())
        fs.mkdir(plan_dir(), recursive=true) catch {
          _ => return
        }
        fs.write_file(path, self.draft) catch {
          _ => return
        }
      }
    None => ()
  }
}

///|
/// Write the final named plan file and drop the draft. Returns the path on
/// success, None on any filesystem failure (best-effort persistence).
async fn PlanMode::save_final_plan(
  self : PlanMode,
  name : String,
  plan : String,
) -> String? noraise {
  match self.fs {
    Some(fs) => {
      let path = final_file_path(name, self.session_label())
      fs.mkdir(plan_dir(), recursive=true) catch {
        _ => return None
      }
      fs.write_file(path, "# \{name}\n\n\{plan}") catch {
        _ => return None
      }
      fs.remove(draft_file_path(self.session_label())) catch {
        _ => ()
      }
      Some(path)
    }
    None => None
  }
}
