///|
/// The tools companion: announces the plan's official MCP servers as this
/// extension's own dynamic tool group while one of its models is active.
///
/// Policy (this extension's own decision, not Posoco's):
/// - Activate when the router publishes a `model_selection` naming a slot this
///   provider serves; withdraw (soft) when the selection leaves.
/// - A switch is a *declaration*, not an instant face change: the new group is
///   adopted at the next operation boundary, and the segment reports the truth
///   in between (`0/3` while connecting).
/// - Connections belong to the published version: each activation opens a fresh
///   connection set, and `retire` closes exactly that set once core releases
///   its last reference. Nothing closes an old version by hand.

///|
/// One published version: the connection set and the provider core captured.
/// Both are kept here so the provider's borrow stays valid for the version's
/// lifetime.
pub(all) struct ZaiLivePlane {
  connection : &ZaiMcpConnection
  provider : ZaiMcpToolProvider
}

///|
/// Slot id → provider id part (`provider/model`). A slot without a separator is
/// its own provider; the router never emits an empty id.
fn zai_slot_provider(slot_id : String) -> String {
  match slot_id.find("/") {
    Some(index) => slot_id.exact_view(end=index).to_owned()
    None => slot_id
  }
}

///|
/// Slot id → model id part.
fn zai_slot_model(slot_id : String) -> String {
  match slot_id.find("/") {
    Some(index) => slot_id.exact_view(start=index + 1).to_owned()
    None => slot_id
  }
}

///|
/// Extract the selected slot from a bus event, ignoring every other topic.
fn zai_selection_slot(event : @devkit.BusEvent) -> String? {
  if event.topic != "model_selection" || event.source != "posoco_ext_llm" {
    return None
  }
  match event.data {
    Json::Object(fields) =>
      match fields.get("slot_id") {
        Some(Json::String(slot_id)) if slot_id != "" => Some(slot_id)
        _ => None
      }
    _ => None
  }
}

///|
pub(all) struct ZaiCodingPlanTools {
  /// Resolved provider config for this session (key, host, profile).
  config : @zai.ZaiConfig
  bus : @devkit.EventBus
  /// Host task group for background activation work; the extension never
  /// blocks a selection event handler.
  group : @async.TaskGroup[Unit]
  /// Persisted selection at session start, so the first operation already sees
  /// the group when the session resumes on this provider.
  initial_slot_id : String
  /// Plane opener. Injected so tests stay offline; production uses
  /// `zai_mcp_open`.
  open_plane : async (String, Array[ZaiToolGroup]) -> Result[
    &ZaiMcpConnection,
    String,
  ] noraise
  mut contributions : @posoco.ToolContributions?
  /// Optional structured log sink: a 0/3 must be diagnosable, not just red.
  mut log : &@posoco.LogPort?
  /// Optional UI: a connect failure surfaces as a notice, so the human sees
  /// the reason instead of only a red count.
  mut ui : &@posoco.UiPort?
  mut state : ZaiToolsState
  mut live : ZaiLivePlane?
  /// Bumped per activation attempt so a late connect cannot overwrite a newer
  /// decision.
  mut generation : Int32
  /// Model this version was declared for; `""` when nothing is announced.
  mut active_model : String
}

///|
pub fn ZaiCodingPlanTools::ZaiCodingPlanTools(
  config~ : @zai.ZaiConfig,
  bus~ : @devkit.EventBus,
  group~ : @async.TaskGroup[Unit],
  initial_slot_id~ : String = "",
  open_plane? : async (String, Array[ZaiToolGroup]) -> Result[
    &ZaiMcpConnection,
    String,
  ] noraise,
) -> ZaiCodingPlanTools {
  {
    config,
    bus,
    group,
    initial_slot_id,
    open_plane: match open_plane {
      Some(opener) => opener
      None => zai_mcp_open_default
    },
    contributions: None,
    log: None,
    ui: None,
    state: ZaiToolsState::Inactive,
    live: None,
    generation: 0,
    active_model: "",
  }
}

///|
/// Whether one slot id is served by this provider. Static so callers (and
/// tests) can ask the question without a constructed extension.
pub fn zai_coding_plan_owns_slot(slot_id : String) -> Bool {
  slot_id != "" && zai_slot_provider(slot_id) == zai_coding_plan_provider_id()
}

///|
/// Whether one slot id is served by this provider.
pub fn ZaiCodingPlanTools::owns_slot(
  self : ZaiCodingPlanTools,
  slot_id : String,
) -> Bool {
  let _ = self
  zai_coding_plan_owns_slot(slot_id)
}

///|
/// Publish the current state on the status bar. A hidden state unregisters the
/// segment; the owner string always matches the manifest id, so a rebuilt
/// extension keeps ownership of its own segment.
fn ZaiCodingPlanTools::publish_status(self : ZaiCodingPlanTools) -> Unit {
  let owner = zai_coding_plan_tools_owner()
  match self.state.segment_value() {
    Some(value) =>
      match self.state.segment_color() {
        Some(color) =>
          @devkit.publish_status_register(
            self.bus,
            source=owner,
            segment="mcp",
            label="Official MCP",
            priority=21,
            value=zai_mcp_segment_text(value),
            color~,
          )
        None =>
          @devkit.publish_status_register(
            self.bus,
            source=owner,
            segment="mcp",
            label="Official MCP",
            priority=21,
            value=zai_mcp_segment_text(value),
          )
      }
    None =>
      @devkit.publish_status_unregister(self.bus, source=owner, segment="mcp")
  }
}

///|
/// Record one failed activation on the structured log sink, when the host
/// composed one. A missing sink is a rendering gap, never an error.
async fn ZaiCodingPlanTools::report_failure(
  self : ZaiCodingPlanTools,
  reason~ : String,
  groups~ : Array[ZaiToolGroup],
) -> Unit noraise {
  match self.ui {
    None => ()
    Some(ui) =>
      ui.render(@posoco.UiRender::{
        slot: @posoco.UiSlot::Notice,
        key: "zai-coding-plan-mcp",
        title: Some("Official MCP"),
        body: @posoco.UiBody::Text(reason),
        ttl_ms: Some(8000),
      })
  }
  match self.log {
    None => ()
    Some(sink) => {
      let endpoints : Array[Json] = groups.map(fn(group) {
        Json::string(group.endpoint)
      })
      let record : @posoco.LogRecord = {
        level: @posoco.LogLevel::Warn,
        source: zai_coding_plan_tools_owner(),
        channel: "mcp",
        event: "mcp.activate.failed",
        message: Some(reason),
        scope: None,
        data: Json::object({
          "declared": Json::number(groups.length().to_double()),
          "endpoints": Json::array(endpoints),
        }),
      }
      let _ = sink.write(record, @posoco.LogDurability::Buffered) catch {
        _ => ()
      }
    }
  }
}

///|
/// Open the declared groups and publish them as this owner's dynamic group.
async fn ZaiCodingPlanTools::activate(
  self : ZaiCodingPlanTools,
  model : String,
) -> Unit noraise {
  self.generation += 1
  let generation = self.generation
  let groups = zai_coding_plan_declared_groups(
    model~,
    host=self.config.base_url,
  )
  if groups.is_empty() {
    return
  }
  let total = groups.length()
  self.active_model = model
  self.state = ZaiToolsState::Connecting(connected=0, total~)
  self.publish_status()
  let opened = (self.open_plane)(self.config.api_key, groups)
  // A newer switch already decided: discard this attempt without touching the
  // published state.
  if generation != self.generation {
    match opened {
      Ok(connection) => connection.close()
      Err(_) => ()
    }
    return
  }
  match opened {
    Err(reason) => {
      // The bar only carries counts; the reason belongs in the log so a
      // 0/3 is diagnosable instead of merely red.
      self.report_failure(reason~, groups~)
      self.state = ZaiToolsState::Degraded(connected=0, total~)
      self.publish_status()
    }
    Ok(connection) => {
      let connected = connection.connected_groups()
      self.state = ZaiToolsState::settled(connected~, total~)
      self.publish_status()
      let provider = ZaiMcpToolProvider(connection~)
      let retire : @posoco.ToolRetire = async fn() {
        connection.close()
        Ok(())
      }
      match self.contributions {
        None => connection.close()
        Some(handle) =>
          match handle.replace(provider~, retire~) {
            Ok(_) => self.live = Some({ connection, provider, })
            Err(_) => {
              connection.close()
              self.state = ZaiToolsState::Degraded(connected=0, total~)
              self.publish_status()
            }
          }
      }
    }
  }
}

///|
/// Stop announcing the group. Soft withdrawal keeps admitted operations
/// working; the connections close through `retire` once core releases them.
async fn ZaiCodingPlanTools::deactivate(
  self : ZaiCodingPlanTools,
) -> Unit noraise {
  self.generation += 1
  let total = self.state.total()
  if self.active_model == "" && self.state is Inactive {
    return
  }
  self.state = if total > 0 {
    ZaiToolsState::Withdrawing(total~)
  } else {
    ZaiToolsState::Inactive
  }
  self.publish_status()
  match self.contributions {
    Some(handle) => {
      let _ = handle.withdraw(mode=@posoco.ToolWithdrawMode::Soft)
    }
    None => ()
  }
  self.active_model = ""
  self.state = ZaiToolsState::Inactive
  // The segment was already hidden by the withdrawing state; reporting the
  // terminal state is registry bookkeeping, not another bar update.
  // Do not close here: core retires the published version after its last
  // operation reference is released.
  self.live = None
}

///|
pub impl @posoco.Lifecycle for ZaiCodingPlanTools with fn on_compose(
  self : ZaiCodingPlanTools,
  view : @posoco.CompositionView,
) -> Unit raise @posoco.CompositionError {
  self.contributions = view.tool_contributions()
  self.log = view.log()
  self.ui = view.ui()
}

///|
/// Boot: subscribe to the session's selection feed, then honour the persisted
/// selection synchronously — `on_start` runs before the first operation's tool
/// capture, so a session that resumes on this provider starts with its tools.
pub impl @posoco.Lifecycle for ZaiCodingPlanTools with fn on_start(
  self : ZaiCodingPlanTools,
) -> Unit {
  self.bus.subscribe(self as &@devkit.BusSubscriber)
  if self.owns_slot(self.initial_slot_id) {
    self.activate(zai_slot_model(self.initial_slot_id))
  }
}

///|
pub impl @posoco.Lifecycle for ZaiCodingPlanTools with fn on_shutdown(
  self : ZaiCodingPlanTools,
) -> Unit {
  self.deactivate()
  // Retire is core-owned, but shutdown must not leave sockets if retire is
  // never reached (for example when composition failed after publishing).
  match self.live {
    Some(live) => live.connection.close()
    None => ()
  }
  self.live = None
}

///|
/// Selection feed: a switch is handled in the background so the command that
/// caused it never waits on a network handshake.
pub impl @devkit.BusSubscriber for ZaiCodingPlanTools with fn on_bus_event(
  self : ZaiCodingPlanTools,
  event : @devkit.BusEvent,
) -> Unit {
  let slot_id = match zai_selection_slot(event) {
    Some(slot_id) => slot_id
    None => return
  }
  if self.owns_slot(slot_id) {
    let model = zai_slot_model(slot_id)
    // Re-declaring the same model is a no-op: a duplicate event must not
    // reconnect a healthy group.
    if model == self.active_model && self.state is Ready(_) {
      return
    }
    self.group.spawn_bg(() => self.activate(model))
  } else {
    self.group.spawn_bg(() => self.deactivate())
  }
}

///|
pub impl @posoco.Extension for ZaiCodingPlanTools with fn extension_id(
  _self : ZaiCodingPlanTools,
) -> String {
  zai_coding_plan_tools_owner()
}

///|
/// Manifest: no static tools — every tool is a dynamic contribution, so the
/// base catalog never carries a stale copy of the MCP set.
pub impl @posoco.Extension for ZaiCodingPlanTools with fn manifest(
  self : ZaiCodingPlanTools,
) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(
    id=zai_coding_plan_tools_owner(),
    lifecycle=[self],
    requires=[
      @posoco.Capability::ToolContribution,
      @posoco.Capability::Log,
      @posoco.Capability::Ui,
    ],
  )
}

///|
pub extend ZaiCodingPlanTools with @posoco.Extension::{extension_id, manifest}

///|
pub extend ZaiCodingPlanTools with @posoco.Lifecycle::{
  on_compose,
  on_shutdown,
  on_start,
}

///|
pub extend ZaiCodingPlanTools with @devkit.BusSubscriber::{on_bus_event}
