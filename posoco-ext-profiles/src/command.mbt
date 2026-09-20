///|
/// Slash surface. `/profiles` is the manual activation fallback (Q17): it
/// mirrors the meta tool through the SAME activation-message constructor,
/// appending via the SessionStore port. `/profile save` (§5, skill-creator
/// shape) persists the session's observed tool usage as a new profile. The
/// composed UiPort is wired once at `on_compose` (Q17).

///|
/// Capture the composed UiPort. Sync on purpose — wiring, not acting (the
/// port's request stays async and is only called later from invoke).
pub impl @posoco.Lifecycle for Profiles with fn on_compose(
  self : Profiles,
  ctx : @posoco.CompositionView,
) -> Unit raise @posoco.CompositionError {
  self.ui = ctx.ui()
}

///|
pub impl @posoco.Lifecycle for Profiles with fn on_shutdown(_self : Profiles) -> Unit {
  ()
}

///|
pub impl @posoco.CommandPort for Profiles with fn commands(_self : Profiles) -> Array[
  @posoco.CommandDef,
] {
  [
    {
      id: "profiles",
      label: "Profiles",
      description: "Activate a profile in the current session",
      category: "profiles",
      ctype: @posoco.CommandType::Select,
      params: [],
      aliases: [],
      shortcut: None,
      icon: None,
      visible: true,
      metadata: None,
    },
    {
      id: "profile",
      label: "Profile",
      description: "Save this session's tool usage as a reusable profile",
      category: "profiles",
      ctype: @posoco.CommandType::MultiStep,
      params: [
        {
          name: "action",
          label: "Action",
          description: "What to do; only \"save\" is supported",
          ptype: @posoco.ParamType::Str,
          required: true,
          default: None,
          choices: Some(["save"]),
          positional: true,
        },
        {
          name: "name",
          label: "Profile name",
          description: "Optional display name; derived from usage when omitted",
          ptype: @posoco.ParamType::Str,
          required: false,
          default: None,
          choices: None,
          positional: false,
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
pub impl @posoco.CommandPort for Profiles with fn invoke(
  self : Profiles,
  id : String,
  args : Json,
) -> @posoco.CommandOutcome raise @posoco.CommandError {
  match id {
    "profiles" => {
      // The selector awaits the UiPort; async calls carry the general
      // Error type, so the boundary folds any raise into a Failure.
      let attempted : Result[@posoco.CommandOutcome, Error] = Ok(
        self.invoke_select_profiles(args),
      ) catch {
        error => Err(error)
      }
      match attempted {
        Ok(outcome) => outcome
        Err(error) =>
          @posoco.CommandOutcome::Failure(
            reason="profiles failed: \{error.to_string()}",
          )
      }
    }
    "profile" => self.invoke_profile_action(args)
    _ => raise @posoco.CommandError::NotFound(id)
  }
}

///|
/// `/profiles` — show the selector, then activate the choice through the
/// manual injection path.
async fn Profiles::invoke_select_profiles(
  self : Profiles,
  args : Json,
) -> @posoco.CommandOutcome {
  let ui = match self.ui {
    Some(ui) => ui
    None =>
      return @posoco.CommandOutcome::Failure(
        reason="profiles needs a composed UI: declare Capability::Ui and wire a host UI at composition",
      )
  }
  let options = self.menu_rows()
  if options.is_empty() {
    return @posoco.CommandOutcome::Failure(
      reason="no profiles are loaded; nothing to select",
    )
  }
  let response = ui.request(
    @posoco.UiRequest::Select(
      prompt="Select profile",
      options~,
      default=Some(0),
    ),
  ) catch {
    error =>
      return @posoco.CommandOutcome::Failure(
        reason="profiles: ui request failed: \{error.to_string()}",
      )
  }
  match response {
    @posoco.UiResponse::Selected(index) =>
      match self.menu_entries().get(index) {
        Some(entry) => self.manual_activate(entry.id, args)
        None =>
          @posoco.CommandOutcome::Failure(
            reason="profiles: selection \{index} is out of range",
          )
      }
    @posoco.UiResponse::Cancelled =>
      @posoco.CommandOutcome::Failure(reason="cancelled")
    _ =>
      @posoco.CommandOutcome::Failure(reason="profiles: unexpected ui response")
  }
}

///|
/// Manual activation — the same injection template as the meta-tool path
/// (Q17/Q18: one template, one invariant). Appends directly through the
/// SessionStore port at the current transcript tail, then fires the same
/// bus event the hook path fires.
async fn Profiles::manual_activate(
  self : Profiles,
  id : String,
  args : Json,
) -> @posoco.CommandOutcome {
  let wiring_failure = "manual activation requires host wiring: pass {\"session_id\": ...} in args and inject a session store at composition"
  let store = match self.session_store {
    Some(store) => store
    None => return @posoco.CommandOutcome::Failure(reason=wiring_failure)
  }
  let session_id = match json_string_field(args, "session_id") {
    Some(session_id) => session_id
    None => return @posoco.CommandOutcome::Failure(reason=wiring_failure)
  }
  let message = self.activation_message(id)
  let loaded : Result[@posoco.Session, @posoco.SessionError] = Ok(
    store.load(session_id),
  ) catch {
    error => Err(error)
  }
  let from_index = match loaded {
    Ok(session) => session.messages.length()
    Err(error) =>
      return @posoco.CommandOutcome::Failure(
        reason="manual activation failed to load session '\{session_id}': \{error.to_string()}",
      )
  }
  let appended : Result[Unit, @posoco.SessionError] = Ok(
    store.append_messages(session_id, from_index, [message][:]),
  ) catch {
    error => Err(error)
  }
  match appended {
    Ok(_) => ()
    Err(error) =>
      return @posoco.CommandOutcome::Failure(
        reason="manual activation failed to append to session '\{session_id}': \{error.to_string()}",
      )
  }
  self.publish_activated(id)
  @posoco.CommandOutcome::Success(
    feedback="activated profile: \{id}",
    structured=None,
    ui_hint=None,
  )
}

///|
fn Profiles::invoke_profile_action(
  self : Profiles,
  args : Json,
) -> @posoco.CommandOutcome {
  match json_string_field(args, "action") {
    Some("save") => self.invoke_save_profile(args)
    Some(other) =>
      @posoco.CommandOutcome::Failure(
        reason="profile: unsupported action '\{other}'; only \"save\" is implemented",
      )
    None =>
      @posoco.CommandOutcome::Failure(
        reason="profile requires an \"action\" argument (\"save\")",
      )
  }
}

///|
/// `/profile save` (§5): fully manual. Name/description come from the
/// host's summarizer when wired, else a deterministic derivation; an
/// explicit `name` argument overrides both names. The id is minted legal
/// and unique; the manifest persists through the ProfileStore seam when
/// wired, and — regardless — enters the in-memory catalog immediately (Q19:
/// activate_profile accepts it this session; the menu catches up next
/// composition).
fn Profiles::invoke_save_profile(
  self : Profiles,
  args : Json,
) -> @posoco.CommandOutcome {
  let session_id = match json_string_field(args, "session_id") {
    Some(session_id) => session_id
    None =>
      return @posoco.CommandOutcome::Failure(
        reason="profile save requires a \"session_id\" argument",
      )
  }
  let usage = self.session_usage(session_id)
  if usage.is_empty() {
    return @posoco.CommandOutcome::Failure(
      reason="no tool usage recorded for this session",
    )
  }
  let derived = match self.summarizer {
    Some(summarize) => summarize(usage)
    None => {
      let leader = usage[0].0
      let detail : Array[String] = []
      for pair in usage {
        let (ext_id, count) = pair
        detail.push("\{ext_id}:\{count}")
        if detail.length() >= 5 {
          break
        }
      }
      (
        "session-\{leader}",
        "auto-saved from session usage: \{detail.join(", ")}",
      )
    }
  }
  let name = match json_string_field(args, "name") {
    Some(given) => given
    None => derived.0
  }
  let id = derive_profile_id(name, self.catalog)
  let manifest : ProfileManifest = {
    id,
    name,
    description: derived.1,
    exts: usage.map(fn(pair) { pair.0 }),
  }
  match self.store {
    Some(store) => {
      let level = match json_string_field(args, "level") {
        Some(level) => level
        None => "user"
      }
      match store.write(level, manifest) {
        Ok(_) => ()
        Err(msg) =>
          return @posoco.CommandOutcome::Failure(
            reason="profile save failed: \{msg}",
          )
      }
    }
    None => ()
  }
  self.catalog.push({
    id: manifest.id,
    description: manifest.description,
    members: manifest.exts.copy(),
    dangling: dangling_ext_ids(manifest.exts, self.defer_set, self.attribution),
  })
  @posoco.CommandOutcome::Success(
    feedback="saved profile: \{id}",
    structured=None,
    ui_hint=None,
  )
}

///|
/// Select options: one label per catalog manifest, identical to the
/// system-prompt menu rows minus the list marker. The builtin `all` is
/// covered by the prompt's fallback sentence.
fn Profiles::menu_rows(self : Profiles) -> Array[String] {
  self.catalog.map(fn(entry) { menu_row(entry) })
}

///|
/// Entries behind the select options, same order as `menu_rows`.
fn Profiles::menu_entries(self : Profiles) -> Array[ProfileEntry] {
  self.catalog.copy()
}

///|
fn json_string_field(args : Json, key : String) -> String? {
  match args {
    Json::Object(fields) =>
      match fields.get(key) {
        Some(Json::String(value)) => Some(value)
        _ => None
      }
    _ => None
  }
}

///|
/// Mint a legal, unused profile id from a display name (Q16): lowercase,
/// non-alphanumeric runs collapse to `-`, edges trimmed; the reserved `all`
/// and catalog collisions get a `-N` suffix. Falls back when nothing
/// survives the sanitization.
fn derive_profile_id(name : String, catalog : Array[ProfileEntry]) -> String {
  let chars : Array[Char] = []
  for ch in name.to_lower() {
    if ch.is_ascii_lowercase() || ch.is_ascii_digit() {
      chars.push(ch)
    } else if chars.length() > 0 && chars[chars.length() - 1] != '-' {
      chars.push('-')
    }
  }
  while chars.length() > 0 && chars[chars.length() - 1] == '-' {
    let _ = chars.remove(chars.length() - 1)
  }
  let mut base = String::from_array(chars)
  if base == reserved_profile_id {
    base = "\{reserved_profile_id}-2"
  }
  if base.is_empty() {
    base = "session-profile"
  }
  let taken : Map[String, Unit] = Map::from_array([])
  for entry in catalog {
    taken[entry.id] = ()
  }
  let mut id = base
  let mut suffix = 2
  while taken.contains(id) {
    id = "\{base}-\{suffix}"
    suffix = suffix + 1
  }
  id
}
