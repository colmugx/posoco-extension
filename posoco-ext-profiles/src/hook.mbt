///|
/// before_model injection (Q18): the activation point. Every pending
/// activation — an `activate_profile` success whose header line is not yet
/// in the transcript — gets exactly one UserMessage appended here. The bus
/// event fires at this injection point too (F4): the activation knowledge
/// lives in the hook, not in the tool's execute.

///|
/// Append one activation message per pending id. Idempotence is entirely
/// `find_pending_activations`' subtraction against the transcript scan; this
/// function keeps no memory and is safe to re-run before every model
/// request within a run.
pub impl @posoco.PipelineHook for Profiles with fn before_model(
  self : Profiles,
  messages : Array[@posoco.Message],
) -> Array[@posoco.Message] {
  for id in find_pending_activations(messages) {
    match self.find_entry(id) {
      Some(_) => {
        messages.push(self.activation_message(id))
        self.publish_activated(id)
      }
      // Unreachable for results this package produced (the catalog never
      // shrinks), but an unknown id is never injected.
      None => ()
    }
  }
  messages
}

///|
/// The one activation message both the meta-tool path and the manual
/// `/profiles` path converge on (Q18: one template, one invariant —
/// "activated" means this message exists in the transcript). First line is
/// the frozen header, then a blank line, then the manual.
///
/// Coverage = defer_set ∩ members (Q19's construction-time guard against
/// re-injecting resident prompt sections): deferred members get their
/// captured manual text in fixed member order (catalog-independent);
/// members outside the deferral are already resident and only listed, never
/// re-injected.
fn Profiles::activation_message(
  self : Profiles,
  id : String,
) -> @posoco.Message {
  let members = match self.find_entry(id) {
    Some(entry) => entry.members
    None => []
  }
  let manuals : Array[String] = []
  let resident : Array[String] = []
  for ext_id in members {
    if self.defer_set.contains(ext_id) {
      match self.captured_prompts.get(ext_id) {
        Some(text) => manuals.push(text)
        // Deep-deferred but contributing no prompt section: nothing to
        // inject for this member.
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
/// Fire-and-forget product notification (F4): topic `profiles.activated`,
/// payload `{id, members}`. Publishing with no bus or no subscribers is a
/// no-op by the bus contract.
fn Profiles::publish_activated(self : Profiles, id : String) -> Unit {
  match self.bus {
    Some(bus) => {
      let members = match self.find_entry(id) {
        Some(entry) => entry.members
        None => []
      }
      bus.publish({
        source: "posoco_ext_profiles",
        topic: "profiles.activated",
        data: Json::object(
          Map::from_array([
            ("id", Json::string(id)),
            ("members", Json::array(members.map(fn(m) { Json::string(m) }))),
          ]),
        ),
      })
    }
    None => ()
  }
}
