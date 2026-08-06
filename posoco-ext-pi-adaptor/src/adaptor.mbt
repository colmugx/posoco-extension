///|
pub(all) struct PiAdaptor {
  host : JsPiHost
}

///|
pub fn PiAdaptor::PiAdaptor() -> PiAdaptor {
  { host: js_host_new() }
}

///|
pub fn pi_adaptor_new() -> PiAdaptor {
  PiAdaptor::PiAdaptor()
}

///|
/// Load and register an unmodified Pi extension module. Node/Bun callers await
/// the returned JavaScript Promise before inspecting the catalog. Lifecycle
/// events are emitted separately so packages with multiple extension entries
/// receive session_start exactly once.
pub fn pi_adaptor_load(adaptor : PiAdaptor, specifier : String) -> JsPromise {
  js_host_load(adaptor.host, specifier)
}

///|
/// Set the working directory exposed as ExtensionContext.cwd.
pub fn pi_adaptor_set_cwd(adaptor : PiAdaptor, cwd : String) -> Unit {
  js_host_set_cwd(adaptor.host, cwd)
}

///|
/// Control the value exposed by ExtensionContext.isProjectTrusted(). The safe
/// default is false; hosts must opt in after applying their own trust policy.
pub fn pi_adaptor_set_project_trusted(
  adaptor : PiAdaptor,
  trusted : Bool,
) -> Unit {
  js_host_set_project_trusted(adaptor.host, trusted)
}

///|
pub fn pi_adaptor_tool_count(adaptor : PiAdaptor) -> Int {
  js_tool_count(adaptor.host)
}

///|
pub fn pi_adaptor_tool_name(adaptor : PiAdaptor, index : Int) -> String {
  js_tool_name(adaptor.host, index)
}

///|
pub fn pi_adaptor_tool_description(adaptor : PiAdaptor, index : Int) -> String {
  js_tool_description(adaptor.host, index)
}

///|
pub fn pi_adaptor_tool_schema_json(adaptor : PiAdaptor, index : Int) -> String {
  js_tool_schema_json(adaptor.host, index)
}

///|
pub fn pi_adaptor_catalog_json(adaptor : PiAdaptor) -> String {
  js_catalog_json(adaptor.host)
}

///|
/// Versioned catalog snapshot for Posoco Runtime/CatalogSource composition.
pub fn pi_adaptor_catalog_snapshot_json(adaptor : PiAdaptor) -> String {
  js_catalog_snapshot_json(adaptor.host)
}

///|
pub fn pi_adaptor_execute_json_async(
  adaptor : PiAdaptor,
  name : String,
  call_id : String,
  arguments_json : String,
) -> JsPromise {
  js_execute_async(adaptor.host, name, call_id, arguments_json)
}

///|
/// Execute a Pi tool correlated to a canonical Posoco EffectId.
pub fn pi_adaptor_execute_effect_json_async(
  adaptor : PiAdaptor,
  effect_id : Int,
  name : String,
  call_id : String,
  arguments_json : String,
) -> JsPromise {
  js_execute_effect_async(
    adaptor.host,
    effect_id,
    name,
    call_id,
    arguments_json,
  )
}

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
/// forwards these through the public RuntimeControl handle.
pub fn pi_adaptor_take_followups_json(adaptor : PiAdaptor) -> String {
  js_take_followups_json(adaptor.host)
}

///|
/// Best-effort cancellation for an in-flight Pi tool call.
pub fn pi_adaptor_cancel_call(adaptor : PiAdaptor, call_id : String) -> Bool {
  js_cancel_call(adaptor.host, call_id)
}

///|
/// Cancel runtime effects and return one canonical disposition per EffectId.
pub fn pi_adaptor_cancel_effects_json(
  adaptor : PiAdaptor,
  effect_ids_json : String,
  reason_json : String,
) -> String {
  js_cancel_effects_json(adaptor.host, effect_ids_json, reason_json)
}

///|
pub fn pi_adaptor_inflight_count(adaptor : PiAdaptor) -> Int {
  js_inflight_count(adaptor.host)
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
pub fn pi_adaptor_entries_json(adaptor : PiAdaptor) -> String {
  js_entries_json(adaptor.host)
}

///|
pub fn pi_adaptor_messages_json(adaptor : PiAdaptor) -> String {
  js_messages_json(adaptor.host)
}

///|
fn parse_json_or_null(text : String) -> Json {
  @json.parse(text) catch {
    _ => Json::null()
  }
}

///|
fn parse_optional_json(text : String) -> Json? {
  if text == "null" {
    None
  } else {
    Some(parse_json_or_null(text))
  }
}

///|
pub impl @posoco.ToolProvider for PiAdaptor with fn list_tools(
  adaptor : PiAdaptor,
) -> Array[@posoco.ToolDef] {
  let tools : Array[@posoco.ToolDef] = []
  for index in 0..<js_tool_count(adaptor.host) {
    let name = js_tool_name(adaptor.host, index)
    tools.push({
      name: @posoco.ToolName::unchecked(name),
      description: js_tool_description(adaptor.host, index),
      input_schema: parse_json_or_null(js_tool_schema_json(adaptor.host, index)),
      owner: @posoco.OwnerId::unchecked("posoco_ext_pi_adaptor"),
      policy: @posoco.ExecutionPolicy::Parallel,
      provenance: Some("pi"),
    })
  }
  tools
}

///|
/// The default ToolProvider path supports Pi tools that return AgentToolResult
/// synchronously. Promise-returning tools require PiRuntime through
/// Agent::with_runtime so execution can suspend without blocking JavaScript.
pub impl @posoco.ToolProvider for PiAdaptor with fn execute(
  adaptor : PiAdaptor,
  name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let result = js_execute_sync(
    adaptor.host,
    name,
    call.call_id.to_string(),
    call.arguments.stringify(),
  )
  let structured = parse_optional_json(result.details_json())
  if result.is_error() {
    @posoco.ToolOutcome::ToolReportedError(
      content=result.content(),
      structured~,
    )
  } else {
    @posoco.ToolOutcome::Success(content=result.content(), structured~)
  }
}

///|
pub impl @posoco.Extension for PiAdaptor with fn extension_id(
  _adaptor : PiAdaptor,
) -> String {
  "posoco_ext_pi_adaptor"
}

///|
pub impl @posoco.Extension for PiAdaptor with fn manifest(adaptor : PiAdaptor) -> @posoco.ExtensionManifest {
  {
    id: "posoco_ext_pi_adaptor",
    models: [],
    tools: [adaptor],
    sessions: [],
    observers: [],
    hooks: [],
    memory: [],
    lifecycle: [],
    commands: [],
    ui: [],
    prompt_contributors: [],
  }
}

///|
pub extend PiAdaptor with @posoco.Extension::{extension_id, manifest}

///|
pub extend PiAdaptor with @posoco.ToolProvider::{list_tools, execute}

///|
pub fn pi_extension() -> PiAdaptor {
  PiAdaptor::PiAdaptor()
}
