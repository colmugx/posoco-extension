///|
/// `/decision` command for the provider-catalog router.
///
/// With no argument the command lists every `kind = Decision` slot with its
/// provider/model facts and the active marker, plus an explicit hint when the
/// decision capability is off (nothing selected, a pending persisted id, or a
/// provider that does not serve decisions). With a slot id it switches the
/// active decision model. The conversation selection (`/model`) is untouched:
/// the two selections never cross kinds.

///|
/// Machine-readable decision-slot catalog: every `kind = Decision` slot in
/// composition order with the active marker. Entries mirror the `/model`
/// catalog's identity fields so hosts can render both lists with one shape.
fn RouterModelPort::decision_slot_catalog_json(self : RouterModelPort) -> Json {
  let entries : Array[Json] = []
  for slot in self.list_decision_slots() {
    entries.push(
      Json::object(
        Map::from_array([
          ("id", Json::string(slot.id)),
          ("label", Json::string(slot.label)),
          ("provider", Json::string(slot.provider_id)),
          ("model", Json::string(slot.model_id)),
          ("active", Json::boolean(slot.id == self.active_decision_id)),
        ]),
      ),
    )
  }
  Json::array(entries)
}

///|
/// Human-readable listing header: the selection state and, when the decision
/// capability is off, the reason why — the unconfigured-selection hint is part
/// of the listing, never a silent empty list.
fn RouterModelPort::decision_listing_feedback(self : RouterModelPort) -> String {
  let slots = self.list_decision_slots()
  match self.decision_off_reason() {
    None =>
      if slots.is_empty() {
        "Decision models (active: none)"
      } else {
        "Available decision model slots (active: " +
        self.active_decision_id +
        ")"
      }
    Some(reason) =>
      if slots.is_empty() {
        "No decision model slots are configured; decision is off (" +
        reason +
        ")"
      } else {
        "Available decision model slots; decision is off (" + reason + ")"
      }
  }
}

///|
/// Parse `/decision` arguments: no arguments (list) or one slot id — a bare
/// string, a `{slot}` object, or the `_positional` field a host slash parser
/// produces.
fn decision_command_selection(
  args : Json,
) -> String? raise @posoco.CommandError {
  match args {
    Json::Null => None
    Json::String(slot_id) =>
      if slot_id.length() == 0 {
        None
      } else {
        Some(slot_id)
      }
    Json::Object(fields) =>
      match parse_optional_string("/decision", fields, "slot") {
        Some(slot_id) => Some(slot_id)
        None => parse_optional_string("/decision", fields, "_positional")
      }
    _ =>
      raise @posoco.CommandError::InvalidArgs(
        reason="/decision expects no arguments or a decision slot id",
      )
  }
}
