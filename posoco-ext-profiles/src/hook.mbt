///|
/// before_model injection: the activation point. Every pending
/// activation — an `activate_profile` success whose header line is not yet
/// in the transcript — gets exactly one UserMessage appended here. The
/// `ProfilesActivated` event fires at this injection point too: the activation
/// knowledge lives in the hook, not in the tool's execute.

///|
/// Append one activation message per pending id. Idempotence is entirely
/// `find_pending_activations`' subtraction against the transcript scan; this
/// function keeps no memory and is safe to re-run before every model
/// request within a run.
impl @posoco.PipelineHook for Profiles with fn before_model(
  self : Profiles,
  messages : Array[@posoco.Message],
) -> Array[@posoco.Message] {
  // Compact may retain the frozen activation header but discard the manual.
  // Restore header-only records before processing new activations so resumed
  // model calls do not silently lose the instructions they depend on.
  for i, message in messages {
    match message {
      @posoco.Message::UserMessage(content~) =>
        match content {
          [@posoco.Content::Text(text), ..] =>
            for entry in self.entries() {
              if text == activation_header(entry.id) {
                messages[i] = self.activation_message(entry.id)
                break
              }
            }
          _ => ()
        }
      _ => ()
    }
  }
  let disclosed : Set[String] = Set([])
  for profile_id in scan_activated_profiles(messages) {
    match self.find_entry(profile_id) {
      Some(entry) =>
        for member in entry.members {
          disclosed.add(member)
        }
      None => ()
    }
  }
  for id in find_pending_activations(messages) {
    match self.find_entry(id) {
      Some(entry) => {
        messages.push(self.activation_message_with_disclosed(id, disclosed))
        for member in entry.members {
          disclosed.add(member)
        }
        self.publish_activated(id)
      }
      None => ()
    }
  }
  messages
}

///|
pub extend Profiles with @posoco.PipelineHook::{
  on_post_event,
  on_turn_begin,
  before_tool,
  on_turn_end,
}

///|
/// The one activation message both the meta-tool path and the manual
/// `/profiles` path converge on: one template, one invariant — "activated"
/// means this message exists in the transcript. First line is
/// the frozen header, then a blank line, then the manual.
///
/// Coverage = defer_set ∩ members, preventing
/// resident prompt sections from being re-injected: deferred members get their
/// captured manual text in fixed member order (catalog-independent);
/// members outside the deferral are already resident and only listed, never
/// re-injected.
fn Profiles::activation_message(
  self : Profiles,
  id : String,
) -> @posoco.Message {
  self.activation_message_with_disclosed(id, Set([]))
}

///|
/// Incremental disclosure when profiles overlap: preserve a header for each
/// activated profile, but include an extension's manual only once per session.
fn Profiles::activation_message_with_disclosed(
  self : Profiles,
  id : String,
  disclosed : Set[String],
) -> @posoco.Message {
  let members = match self.find_entry(id) {
    Some(entry) => entry.members
    None => []
  }
  let manuals : Array[String] = []
  let resident : Array[String] = []
  for ext_id in members {
    if self.defer_set.contains(ext_id) && !disclosed.contains(ext_id) {
      match self.captured_prompts.get(ext_id) {
        Some(text) => manuals.push(text)
        None => ()
      }
    } else {
      resident.push(ext_id)
    }
  }
  let mut body = manuals.join("\n\n")
  if !resident.is_empty() {
    let line = "already resident (no re-injection): \{resident.join(", ")}"
    body = if body.is_empty() { line } else { "\{body}\n\n\{line}" }
  }
  let text = if body.is_empty() {
    activation_header(id)
  } else {
    "\{activation_header(id)}\n\n\{body}"
  }
  @posoco.Message::UserMessage(content=[@posoco.Content::Text(text)])
}

///|
/// Fire-and-forget product notification: `@kit_events.ProfilesActivated`,
/// payload `{id, members}`. Publishing with no capability or no subscribers
/// is a no-op by the event contract, and a closed system is not an error
/// path (`publish` returns `Err(Closed)` at shutdown and the notice is
/// dropped).
fn Profiles::publish_activated(self : Profiles, id : String) -> Unit {
  match self.events {
    Some(events) => {
      let members = match self.find_entry(id) {
        Some(entry) => entry.members
        None => []
      }
      let payload : @kit_events.ProfilesActivatedPayload = { id, members, }
      ignore(events.publish(@kit_events.ProfilesActivated(payload)))
    }
    None => ()
  }
}
