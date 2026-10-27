///|
pub(all) struct PiAdaptor {
  host : JsPiHost
  /// Event bridge over the same JsPiHost, contributed via the manifest.
  events : PiEventObserver
  /// Command bridge over the same JsPiHost (`pi:` namespace), contributed via
  /// the manifest.
  commands : PiCommandPort
  /// Prompt-snippet hook over the same JsPiHost, contributed via the
  /// manifest.
  hook : PiHook
  /// Tool names the host declared as already owned; matching pi tools are
  /// hidden from every Posoco-facing catalog view (base wins).
  mut hidden_tools : Map[String, Bool]
  /// ToolContribution handle claimed at on_compose; the live pi tool set
  /// publishes through it as the adaptor's own dynamic group.
  mut contributions : @posoco.ToolContributions?
  /// Set by the JS host whenever its tool registration changes. The next
  /// model call (PiRuntime::call_model) observes it and re-publishes; the
  /// kernel adopts the new group at the next operation boundary.
  mut catalog_dirty : Bool
  /// Name snapshot of the last accepted publication; suppresses identical
  /// re-publications.
  mut published_names : Array[String]
}

///|
pub fn PiAdaptor::PiAdaptor() -> PiAdaptor {
  let host = js_host_new()
  let adaptor = {
    host,
    events: PiEventObserver::PiEventObserver(host~),
    commands: PiCommandPort::PiCommandPort(host~),
    hook: PiHook::PiHook(host~),
    hidden_tools: Map::from_array([]),
    contributions: None,
    catalog_dirty: true,
    published_names: [],
  }
  js_host_set_on_catalog_change(host, fn() { adaptor.catalog_dirty = true })
  adaptor
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
/// Install the host UI callbacks backing ExtensionContext.ui. `on_request`
/// receives a UiPort `ui_request` JSON string and resolves to the correlated
/// `ui_response` JSON string; `on_render` receives a `ui_render` JSON string.
/// Both wire shapes mirror cetas-js JsUiPort so hosts reuse their existing TS
/// callback pair. Absent callbacks keep the headless no-op ui (hasUI=false);
/// once installed, mode stays "json" while hasUI reports true.
pub fn pi_adaptor_set_ui_callbacks(
  adaptor : PiAdaptor,
  on_request : JsUiRequestFn,
  on_render : JsUiRenderFn,
) -> Unit {
  js_host_set_ui_callbacks(adaptor.host, on_request, on_render)
}

///|
/// Declare the tool names the host already owns (base tools). Matching pi
/// tools are hidden from list_tools and the catalog JSON views so the core's
/// manifest-aggregate collision check and the model catalog keep the host's
/// tool (base wins), and from the `<pi-tools>` prompt block so the model
/// never sees a snippet for a tool it cannot call. Hiding is visibility-only:
/// the pi-side registry keeps the tool and PiRuntime can still execute it.
pub fn pi_adaptor_set_hidden_tools_json(
  adaptor : PiAdaptor,
  names_json : String,
) -> Unit {
  let hidden : Map[String, Bool] = Map::from_array([])
  let parsed = @json.parse(names_json) catch { _ => Json::null() }
  if parsed is Json::Array(items) {
    for item in items {
      if item is Json::String(value) {
        hidden[value] = true
      }
    }
  }
  adaptor.hidden_tools = hidden
  js_host_set_hidden_tools(adaptor.host, names_json)
}

///|
fn pi_tool_hidden(adaptor : PiAdaptor, name : String) -> Bool {
  adaptor.hidden_tools.contains(name)
}

///|
/// Drop hidden tools from a parsed pi catalog JSON payload. Handles both the
/// plain tool array (`js_catalog_json`) and the snapshot object
/// (`js_catalog_snapshot_json`, `{version, tools}`).
fn filter_hidden_tools(adaptor : PiAdaptor, json : Json) -> Json {
  match json {
    Json::Array(items) => Json::array(filter_hidden_tool_items(adaptor, items))
    Json::Object(fields) =>
      match fields.get("tools") {
        Some(Json::Array(items)) => {
          let kept : Array[(String, Json)] = []
          for field in fields {
            let (key, value) = field
            if key == "tools" {
              kept.push(
                ("tools", Json::array(filter_hidden_tool_items(adaptor, items))),
              )
            } else {
              kept.push((key, value))
            }
          }
          Json::object(Map::from_array(kept))
        }
        _ => json
      }
    _ => json
  }
}

///|
fn filter_hidden_tool_items(
  adaptor : PiAdaptor,
  items : Array[Json],
) -> Array[Json] {
  let kept : Array[Json] = []
  for item in items {
    let name = match item {
      Json::Object(fields) =>
        match fields.get("name") {
          Some(Json::String(value)) => value
          _ => ""
        }
      _ => ""
    }
    if !pi_tool_hidden(adaptor, name) {
      kept.push(item)
    }
  }
  kept
}

///|
pub fn pi_adaptor_tool_count(adaptor : PiAdaptor) -> Int32 {
  js_tool_count(adaptor.host)
}

///|
pub fn pi_adaptor_tool_name(adaptor : PiAdaptor, index : Int32) -> String {
  js_tool_name(adaptor.host, index)
}

///|
pub fn pi_adaptor_tool_description(
  adaptor : PiAdaptor,
  index : Int32,
) -> String {
  js_tool_description(adaptor.host, index)
}

///|
pub fn pi_adaptor_tool_schema_json(
  adaptor : PiAdaptor,
  index : Int32,
) -> String {
  js_tool_schema_json(adaptor.host, index)
}

///|
pub fn pi_adaptor_catalog_json(adaptor : PiAdaptor) -> String {
  project_catalog_json(
    filter_hidden_tools(
      adaptor,
      parse_json_or_null(js_catalog_json(adaptor.host)),
    ),
  ).stringify()
}

///|
/// Versioned catalog snapshot for Posoco Runtime/CatalogSource composition.
pub fn pi_adaptor_catalog_snapshot_json(adaptor : PiAdaptor) -> String {
  project_catalog_json(
    filter_hidden_tools(
      adaptor,
      parse_json_or_null(js_catalog_snapshot_json(adaptor.host)),
    ),
  ).stringify()
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
  effect_id : Int32,
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
pub fn pi_adaptor_inflight_count(adaptor : PiAdaptor) -> Int32 {
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
    if pi_tool_hidden(adaptor, name) {
      continue
    }
    tools.push(
      @posoco.ToolDef(
        name=@posoco.ToolName::unchecked(name),
        description=js_tool_description(adaptor.host, index),
        input_schema=project_tool_schema(
          parse_json_or_null(js_tool_schema_json(adaptor.host, index)),
        ),
        owner=@posoco.OwnerId::unchecked("posoco_ext_pi_adaptor"),
        policy=@posoco.ExecutionPolicy::Parallel,
        provenance=Some("pi"),
      ),
    )
  }
  tools
}

///|
/// The default ToolProvider path supports Pi tools that return AgentToolResult
/// synchronously. Promise-returning tools require PiRuntime through
/// Agent::with_runtime so execution can suspend without blocking JavaScript.
pub impl @posoco.ToolProvider for PiAdaptor with fn execute(
  adaptor : PiAdaptor,
  ctx : @posoco.ToolCallContext,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let name = ctx.name.to_string()
  let result = js_execute_sync(
    adaptor.host,
    name,
    ctx.call_id.to_string(),
    ctx.arguments.stringify(),
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
  @posoco.ExtensionManifest(
    id="posoco_ext_pi_adaptor",
    tools=[adaptor],
    observers=[adaptor.events as &@posoco.Observer],
    hooks=[adaptor.hook as &@posoco.PipelineHook],
    commands=[adaptor.commands as &@posoco.CommandPort],
    requires=[@posoco.Capability::ToolContribution],
  )
}

///|
pub impl @posoco.Lifecycle for PiAdaptor with fn on_compose(
  adaptor : PiAdaptor,
  view : @posoco.CompositionView,
) -> Unit raise @posoco.CompositionError {
  adaptor.contributions = view.tool_contributions()
}

///|
/// One fixed snapshot of the live pi tools (already hidden-filtered by
/// `list_tools`). Publishing pins the group; the JS host bumps the dirty
/// flag on the next registration change and `PiRuntime::call_model`
/// re-publishes there.
priv struct PiLiveTools {
  defs : Array[@posoco.ToolDef]
  adaptor : PiAdaptor
}

///|
impl @posoco.ToolProvider for PiLiveTools with fn list_tools(self : PiLiveTools) -> Array[
  @posoco.ToolDef,
] {
  self.defs.copy()
}

///|
impl @posoco.ToolProvider for PiLiveTools with fn execute(
  self : PiLiveTools,
  ctx : @posoco.ToolCallContext,
) -> @kernel.ToolOutcome raise @posoco.RuntimeError {
  @posoco.ToolProvider::execute(self.adaptor, ctx)
}

///|
/// Publish the current live pi tool set as the adaptor's contribution
/// group (owner posoco_ext_pi_adaptor). Call from an async context — the
/// model-call seam in PiRuntime. A rejected group keeps the previous
/// snapshot; the failure is recorded in the dirty state so a later
/// registration change retries.
pub async fn pi_adaptor_publish(adaptor : PiAdaptor) -> Unit {
  adaptor.catalog_dirty = false
  let handle = match adaptor.contributions {
    Some(handle) => handle
    None => return
  }
  let defs = @posoco.ToolProvider::list_tools(adaptor)
  let names = defs.map(fn(def) { def.name.to_string() })
  if names == adaptor.published_names {
    return
  }
  let provider = PiLiveTools::{ defs, adaptor, } as &@posoco.ToolProvider
  let ack = handle.replace(provider~)
  match ack {
    Ok(_) => adaptor.published_names = names
    Err(_) => adaptor.catalog_dirty = true
  }
}

///|
pub extend PiAdaptor with @posoco.Extension::{extension_id, manifest}

///|
#deprecated
pub extend PiAdaptor with @posoco.Lifecycle::{on_compose, on_start, on_shutdown}

///|
pub extend PiAdaptor with @posoco.ToolProvider::{list_tools, execute}

///|
pub fn pi_extension() -> PiAdaptor {
  PiAdaptor::PiAdaptor()
}
