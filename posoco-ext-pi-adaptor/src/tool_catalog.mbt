///|
// Tool catalog and dynamic contribution projection; Posoco owns schema validation and operation snapshots.

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
  filter_hidden_tools(
    adaptor,
    parse_json_or_null(js_catalog_json(adaptor.host)),
  ).stringify()
}

///|
/// Versioned snapshot of the Pi guest catalog (not a Posoco CatalogSource).
pub fn pi_adaptor_catalog_snapshot_json(adaptor : PiAdaptor) -> String {
  filter_hidden_tools(
    adaptor,
    parse_json_or_null(js_catalog_snapshot_json(adaptor.host)),
  ).stringify()
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
        input_schema=parse_json_or_null(
          js_tool_schema_json(adaptor.host, index),
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
/// Only tools registered *after* the static manifest snapshot may be
/// contributed dynamically. Posoco checks collisions against the static
/// directory; duplicating names under the same owner is still invalid.
fn pi_dynamic_tools(adaptor : PiAdaptor) -> Array[@posoco.ToolDef] {
  let defs : Array[@posoco.ToolDef] = []
  for def in @posoco.ToolProvider::list_tools(adaptor) {
    if !adaptor.static_tools.contains(def.name.to_string()) {
      defs.push(def)
    }
  }
  defs
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
  let defs = pi_dynamic_tools(adaptor)
  let names = defs.map(fn(def) { def.name.to_string() })
  if names == adaptor.published_names {
    return
  }
  // Only late-registered tools belong to the dynamic group. When the group
  // becomes empty, withdraw it instead of exposing an empty stale version.
  if defs.is_empty() {
    let ack = handle.withdraw()
    match ack {
      Ok(_) => adaptor.published_names = []
      Err(_) => adaptor.catalog_dirty = true
    }
    return
  }
  let provider = PiLiveTools::{ defs, adaptor, } as &@posoco.ToolProvider
  let ack = handle.replace(provider~)
  match ack {
    Ok(_) => adaptor.published_names = names
    Err(_) => adaptor.catalog_dirty = true
  }
}
