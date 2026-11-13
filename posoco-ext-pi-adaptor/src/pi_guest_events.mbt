///|
// Pi events, commands, UI callbacks and follow-up ingress (JS target).
// Keep foreign-runtime implementation here; the public Pi/Posoco mapping lives
// in adaptor, event_observer, hook_adaptor, and runtime_adaptor.

///|
extern "js" fn js_emit_event(
  host : JsPiHost,
  event : String,
  payload_json : String,
) -> JsPromise =
  #| async (host, event, payloadJson) => {
  #|   const handlers = host.state.handlers.get(event) ?? [];
  #|   const payload = JSON.parse(payloadJson);
  #|   const context = host.makeContext();
  #|   for (const handler of handlers) await handler(payload, context);
  #|   return handlers.length;
  #| }

///|
extern "js" fn js_seed_entry(
  host : JsPiHost,
  custom_type : String,
  data_json : String,
) -> Unit =
  #| (host, customType, dataJson) => {
  #|   host.state.entries.push({
  #|     type: "custom",
  #|     customType,
  #|     data: JSON.parse(dataJson),
  #|   });
  #| }

///|
extern "js" fn js_event_names_json(host : JsPiHost) -> String =
  #| (host) => JSON.stringify([...host.state.handlers.keys()])

///|
extern "js" fn js_shortcuts_json(host : JsPiHost) -> String =
  #| (host) => JSON.stringify(host.state.shortcuts)

///|
/// Registered Pi command descriptors (name + description, handlers withheld).
extern "js" fn js_commands_json(host : JsPiHost) -> String =
  #| (host) => JSON.stringify(host.state.commands.map(({ name, description }) => ({ name, description })))

///|
/// Run one registered Pi command or shortcut handler. `name` is the bare
/// command name, or "#<key>" for shortcuts. The positional args string is
/// extracted from the host's JSON args (terminal-shell sends
/// {"_positional": ...}); the handler gets the shared makeContext(). Resolves
/// to {thrown, feedback, message} JSON: handlers never reject across the FFI.
extern "js" fn js_invoke_command_async(
  host : JsPiHost,
  name : String,
  args_json : String,
) -> JsPromise =
  #| async (host, name, argsJson) => {
  #|   const shortcut = name.startsWith("#");
  #|   const entry = shortcut
  #|     ? host.state.shortcuts.find((item) => item.key === name.slice(1))
  #|     : host.state.commands.find((item) => item.name === name);
  #|   if (!entry || typeof entry.handler !== "function") {
  #|     return JSON.stringify({ thrown: true, message: `Unknown Pi command: ${name}` });
  #|   }
  #|   let args = "";
  #|   if (!shortcut) {
  #|     try {
  #|       const parsed = JSON.parse(argsJson);
  #|       if (typeof parsed === "string") args = parsed;
  #|       else if (parsed && typeof parsed._positional === "string") args = parsed._positional;
  #|     } catch {}
  #|   }
  #|   try {
  #|     const returned = shortcut
  #|       ? await entry.handler(host.makeContext())
  #|       : await entry.handler(args, host.makeContext());
  #|     return JSON.stringify({ thrown: false, feedback: typeof returned === "string" ? returned : "" });
  #|   } catch (error) {
  #|     return JSON.stringify({
  #|       thrown: true,
  #|       message: error instanceof Error ? error.message : String(error),
  #|     });
  #|   }
  #| }

///|
/// Execute host.api.exec (child_process argv spawn) and resolve to its
/// ExecResult JSON string.
extern "js" fn js_exec_async(
  host : JsPiHost,
  command : String,
  args_json : String,
  options_json : String,
) -> JsPromise =
  #| async (host, command, argsJson, optionsJson) => {
  #|   let args = [];
  #|   let options = {};
  #|   try { args = JSON.parse(argsJson) ?? []; } catch {}
  #|   try { options = JSON.parse(optionsJson) ?? {}; } catch {}
  #|   return JSON.stringify(await host.api.exec(command, args, options));
  #| }

///|
extern "js" fn js_entries_json(host : JsPiHost) -> String =
  #| (host) => JSON.stringify(host.state.entries)

///|
extern "js" fn js_messages_json(host : JsPiHost) -> String =
  #| (host) => JSON.stringify(host.state.messages)

///|
extern "js" fn js_updates_json(host : JsPiHost) -> String =
  #| (host) => JSON.stringify(host.state.updates)

///|
extern "js" fn js_take_updates_json(host : JsPiHost) -> String =
  #| (host) => {
  #|   const updates = host.state.updates.splice(0, host.state.updates.length);
  #|   return JSON.stringify(updates);
  #| }

///|
extern "js" fn js_take_followups_json(host : JsPiHost) -> String =
  #| (host) => {
  #|   const followUps = host.state.followUps.splice(0, host.state.followUps.length);
  #|   return JSON.stringify(followUps);
  #| }

///|
/// Install a callback used to forward triggerTurn messages to AgentControl.
/// The callback returns "Accepted" when consumed, "Parked" when the envelope
/// may be retried, or "Failed:<reason>" for a terminal error.
extern "js" fn js_host_set_followup_callback(
  host : JsPiHost,
  callback : (String) -> String,
) -> Unit =
  #| (host, callback) => { host.state.followUpCallback = callback }

///|
/// Install the host UI callbacks consulted by makeContext.ui. Before this is
/// called (e.g. package loads, pre-composition events) the callbacks stay
/// absent and ctx.ui keeps no-op defaults with hasUI=false.
extern "js" fn js_host_set_ui_callbacks(
  host : JsPiHost,
  on_request : JsUiRequestFn,
  on_render : JsUiRenderFn,
) -> Unit =
  #| (host, onRequest, onRender) => {
  #|   host.state.uiOnRequest = onRequest;
  #|   host.state.uiOnRender = onRender;
  #| }

///|
/// Install the callback fired on every api.appendEntry: (customType,
/// dataJson). Hosts project these as observer Custom events at emission time.
extern "js" fn js_host_set_custom_entry_callback(
  host : JsPiHost,
  callback : (String, String) -> Unit,
) -> Unit =
  #| (host, callback) => { host.state.customEmit = callback }

///|
/// Drain custom entries appended since the last drain. Only api.appendEntry
/// feeds this queue — js_seed_entry restore never re-drains.
extern "js" fn js_take_custom_entries_json(host : JsPiHost) -> String =
  #| (host) => {
  #|   const entries = host.state.customEntries.splice(0, host.state.customEntries.length);
  #|   return JSON.stringify(entries);
  #| }
