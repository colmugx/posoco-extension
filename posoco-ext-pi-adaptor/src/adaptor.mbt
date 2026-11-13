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
  /// Static tools are already owned by the composed catalog. A dynamic
  /// contribution may only contain tools registered after composition.
  mut static_tools : Map[String, Bool]
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
    static_tools: Map::from_array([]),
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
pub impl @posoco.Extension for PiAdaptor with fn extension_id(
  _adaptor : PiAdaptor,
) -> String {
  "posoco_ext_pi_adaptor"
}

///|
pub impl @posoco.Extension for PiAdaptor with fn manifest(adaptor : PiAdaptor) -> @posoco.ExtensionManifest {
  // The manifest's ToolProvider is captured as static tools. Never publish
  // these same names through ToolContributions: the directory rejects a
  // duplicate even when both providers claim the same owner.
  let initial = @posoco.ToolProvider::list_tools(adaptor)
  for tool in initial {
    adaptor.static_tools[tool.name.to_string()] = true
  }
  @posoco.ExtensionManifest(
    id="posoco_ext_pi_adaptor",
    tools=[adaptor],
    observers=[adaptor.events as &@posoco.Observer],
    hooks=[adaptor.hook as &@posoco.PipelineHook],
    commands=[adaptor.commands as &@posoco.CommandPort],
    lifecycle=[adaptor as &@posoco.Lifecycle],
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
