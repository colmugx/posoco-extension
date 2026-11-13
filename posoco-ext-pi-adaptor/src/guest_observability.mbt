///|
// Host-facing events, UI, commands, session entries and follow-up export functions.

///|
pub fn pi_adaptor_updates_json(adaptor : PiAdaptor) -> String {
  js_updates_json(adaptor.host)
}

///|
/// Drain partial Pi tool updates for projection as TurnEvent::Custom/UI renders.
pub fn pi_adaptor_take_updates_json(adaptor : PiAdaptor) -> String {
  js_take_updates_json(adaptor.host)
}

///|
/// Drain Pi sendMessage(..., { triggerTurn: true }) envelopes. PiRuntime
/// forwards these through the public AgentControl handle.
pub fn pi_adaptor_take_followups_json(adaptor : PiAdaptor) -> String {
  js_take_followups_json(adaptor.host)
}

///|
/// Install the callback fired on every pi appendEntry: (customType, dataJson).
/// Hosts project these as observer Custom events at emission time.
pub fn pi_adaptor_set_custom_entry_callback(
  adaptor : PiAdaptor,
  callback : (String, String) -> Unit,
) -> Unit {
  js_host_set_custom_entry_callback(adaptor.host, callback)
}

///|
/// Drain custom session entries appended since the last drain (fresh
/// appendEntry calls only; seeded restore entries never re-drain). JSON array
/// of pi entry objects: {type:"custom", customType, data}.
pub fn pi_adaptor_take_custom_entries_json(adaptor : PiAdaptor) -> String {
  js_take_custom_entries_json(adaptor.host)
}

///|
/// Emit a Pi lifecycle/session event into the extension's registered handlers.
pub fn pi_adaptor_emit_event(
  adaptor : PiAdaptor,
  event : String,
  payload_json : String,
) -> JsPromise {
  js_emit_event(adaptor.host, event, payload_json)
}

///|
/// Seed a Pi custom session entry before session_start restoration.
pub fn pi_adaptor_seed_entry(
  adaptor : PiAdaptor,
  custom_type : String,
  data_json : String,
) -> Unit {
  js_seed_entry(adaptor.host, custom_type, data_json)
}

///|
pub fn pi_adaptor_event_names_json(adaptor : PiAdaptor) -> String {
  js_event_names_json(adaptor.host)
}

///|
pub fn pi_adaptor_shortcuts_json(adaptor : PiAdaptor) -> String {
  js_shortcuts_json(adaptor.host)
}

///|
/// Registered Pi command descriptors as a JSON array of {name, description}.
pub fn pi_adaptor_commands_json(adaptor : PiAdaptor) -> String {
  js_commands_json(adaptor.host)
}

///|
/// The <pi-tools> prompt block the PiHook currently injects (empty string
/// when no registered tool self-describes). Diagnostic surface for hosts and
/// probes; the hook itself reads the same live state per model call.
pub fn pi_adaptor_prompt_block_json(adaptor : PiAdaptor) -> String {
  pi_prompt_block(adaptor.hook.entries())
}

///|
/// Invoke through the CommandPort bridge and resolve to the projected
/// CommandOutcome JSON. Ids are the port-declared forms: `pi:<name>` and
/// `pi:#<key>`.
pub fn pi_adaptor_invoke_command_json_async(
  adaptor : PiAdaptor,
  id : String,
  args_json : String,
) -> @js_async.Promise[String] {
  @js_async.Promise::from_async() <| () => {
    let port : &@posoco.CommandPort = adaptor.commands as &@posoco.CommandPort
    let outcome = port.invoke(id, parse_json_or_null(args_json)) catch {
      err => @posoco.CommandOutcome::Failure(reason=err.to_string())
    }
    command_outcome_json(outcome).stringify()
  }
}

///|
/// Run host.api.exec (argv spawn, pi ExecResult semantics) and resolve to its
/// JSON: {stdout, stderr, code, killed}.
pub fn pi_adaptor_exec_json_async(
  adaptor : PiAdaptor,
  command : String,
  args_json : String,
  options_json : String,
) -> JsPromise {
  js_exec_async(adaptor.host, command, args_json, options_json)
}

///|
pub fn pi_adaptor_entries_json(adaptor : PiAdaptor) -> String {
  js_entries_json(adaptor.host)
}

///|
pub fn pi_adaptor_messages_json(adaptor : PiAdaptor) -> String {
  js_messages_json(adaptor.host)
}

