///|
/// Typed runtime settings, parsed from a host-supplied JSON object.
/// Recognized keys: `base_url` (string), `gateway_key` (string — the
/// optional remote credential; hosts sourcing it from a credential store
/// pass the value here and nothing is persisted by this extension),
/// `enabled` (bool), `model` (string, selection seed), `effort` (string).
/// Unknown keys are ignored; wrong-typed known keys raise
/// `MagpieGatewayError::InvalidConfig` — activation recovers by falling
/// back to defaults and recording the reason.
pub(all) struct MagpieRuntimeSettings {
  base_url : String?
  gateway_key : String?
  enabled : Bool?
  model : String?
  effort : String?
} derive(Eq, Debug)

///|
pub extend MagpieRuntimeSettings with Eq::{not_equal, equal}

///|
pub extend MagpieRuntimeSettings with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Parses settings from JSON. `None` yields the documented defaults.
pub fn MagpieRuntimeSettings::from_settings(
  settings : Json?,
) -> MagpieRuntimeSettings raise MagpieGatewayError {
  let fields = match settings {
    None =>
      return {
        base_url: None,
        gateway_key: None,
        enabled: None,
        model: None,
        effort: None,
      }
    Some(Json::Object(fields)) => fields
    Some(_) =>
      raise MagpieGatewayError::InvalidConfig("settings must be a JSON object")
  }
  {
    base_url: match fields.get("base_url") {
      None => None
      Some(Json::String(value)) => Some(value)
      Some(_) =>
        raise MagpieGatewayError::InvalidConfig(
          "settings.base_url must be a string",
        )
    },
    gateway_key: match fields.get("gateway_key") {
      None => None
      Some(Json::String(value)) => Some(value)
      Some(_) =>
        raise MagpieGatewayError::InvalidConfig(
          "settings.gateway_key must be a string",
        )
    },
    enabled: match fields.get("enabled") {
      None => None
      Some(Json::True) => Some(true)
      Some(Json::False) => Some(false)
      Some(_) =>
        raise MagpieGatewayError::InvalidConfig(
          "settings.enabled must be a boolean",
        )
    },
    model: match fields.get("model") {
      None => None
      Some(Json::String(value)) => Some(value)
      Some(_) =>
        raise MagpieGatewayError::InvalidConfig(
          "settings.model must be a string",
        )
    },
    effort: match fields.get("effort") {
      None => None
      Some(Json::String(value)) => Some(value)
      Some(_) =>
        raise MagpieGatewayError::InvalidConfig(
          "settings.effort must be a string",
        )
    },
  }
}

///|
/// The activated runtime: manager, model port, and intelligence sharing one
/// configuration and transport, plus the bounded recent-execution log the
/// usage command reads from.
pub struct MagpieRuntime {
  priv manager : MagpieManager
  priv port : MagpieModelPort
  priv intelligence : MagpieGatewayIntelligence
  priv reports : Ref[Array[MagpieExecutionReport]]
  priv unconfigured_reason : String?
  priv mut active : Bool
}

///|
/// The most recent executions a usage command can show.
const RUNTIME_REPORT_LOG_LIMIT : Int32 = 20

///|
/// Activates the runtime. Never performs I/O: an offline gateway is
/// discovered by `on_start`'s refresh, not here. Invalid settings or an
/// invalid derived configuration recover to the documented defaults with a
/// recorded reason, so startup cannot crash on configuration.
pub fn MagpieRuntime::activate(
  settings~ : Json? = None,
  transport~ : &MagpieTransport = HttpMagpieTransport::HttpMagpieTransport(),
) -> MagpieRuntime {
  let reason : Ref[String?] = Ref(None)
  // Invalid settings must never silently activate the default gateway.
  let fallback : MagpieRuntimeSettings = {
    base_url: None,
    gateway_key: None,
    enabled: Some(false),
    model: None,
    effort: None,
  }
  let parsed = MagpieRuntimeSettings::from_settings(settings) catch {
    error => {
      reason.val = Some(error.to_string())
      fallback
    }
  }
  let config = MagpieConfig::MagpieConfig(
    base_url=parsed.base_url.unwrap_or(DEFAULT_GATEWAY_URL),
    credential=parsed.gateway_key,
    enabled=parsed.enabled.unwrap_or(true),
    selected_model=parsed.model,
    selected_effort=parsed.effort,
  ) catch {
    error => {
      reason.val = Some(error.to_string())
      MagpieConfig::{
        base_url: DEFAULT_GATEWAY_URL,
        credential: None,
        connect_timeout_ms: DEFAULT_CONNECT_TIMEOUT_MS,
        enabled: false,
        selected_model: None,
        selected_effort: None,
      }
    }
  }
  let reports : Ref[Array[MagpieExecutionReport]] = Ref([])
  let manager = MagpieManager::MagpieManager(config~, transport~)
  let port = MagpieModelPort::MagpieModelPort(manager~, transport~, report_sink=fn(
    report,
  ) {
    reports.val.push(report)
    if reports.val.length() > RUNTIME_REPORT_LOG_LIMIT {
      let keep : Array[MagpieExecutionReport] = []
      for
        index in (reports.val.length() - RUNTIME_REPORT_LOG_LIMIT)..<reports.val.length() {
        keep.push(reports.val[index])
      }
      reports.val = keep
    }
  })
  let intelligence = MagpieGatewayIntelligence::MagpieGatewayIntelligence(
    config~,
    transport~,
  )
  {
    manager,
    port,
    intelligence,
    reports,
    unconfigured_reason: reason.val,
    active: true,
  }
}

///|
/// The manager behind this runtime (selection surface).
pub fn MagpieRuntime::manager(self : MagpieRuntime) -> MagpieManager {
  self.manager
}

///|
/// The model port behind this runtime.
pub fn MagpieRuntime::model_port(self : MagpieRuntime) -> MagpieModelPort {
  self.port
}

///|
/// The intelligence client behind this runtime.
pub fn MagpieRuntime::intelligence(
  self : MagpieRuntime,
) -> MagpieGatewayIntelligence {
  self.intelligence
}

///|
/// Why the runtime fell back to default settings, when it did.
pub fn MagpieRuntime::unconfigured_reason(self : MagpieRuntime) -> String? {
  self.unconfigured_reason
}

///|
fn MagpieRuntime::require_active(
  self : MagpieRuntime,
) -> Unit raise @posoco.CommandError {
  if !self.active {
    raise @posoco.CommandError::ExecutionFailed("magpie runtime is deactivated")
  }
}

///|
/// The recent execution log, oldest first.
pub fn MagpieRuntime::recent_reports(
  self : MagpieRuntime,
) -> Array[MagpieExecutionReport] {
  self.reports.val.copy()
}

///|
fn runtime_arg_str(args : Json, key : String) -> String? {
  guard args is Json::Object(fields) else { return None }
  match fields.get(key) {
    Some(Json::String(value)) => Some(value)
    _ => None
  }
}

///|
fn runtime_arg_bool(args : Json, key : String) -> Bool? {
  guard args is Json::Object(fields) else { return None }
  match fields.get(key) {
    Some(Json::True) => Some(true)
    Some(Json::False) => Some(false)
    _ => None
  }
}

///|
fn runtime_arg_int(args : Json, key : String) -> Int32? {
  guard args is Json::Object(fields) else { return None }
  match fields.get(key) {
    Some(Json::Number(value, ..)) => Some(value.to_int())
    _ => None
  }
}

///|
/// The model catalog as one structured listing: ids verbatim, selection and
/// pending state included.
fn MagpieRuntime::model_catalog_json(self : MagpieRuntime) -> Json {
  let control = self.manager as &@modelmgmt.ModelManagerControl
  let selection = control.active_selection()
  let entries : Array[Json] = []
  for model in control.list_models() {
    entries.push(
      Json::object({
        "id": Json::string(model.model_id),
        "label": Json::string(model.label),
        "provider": Json::string(model.provider_id),
        "efforts": Json::array(
          model.efforts.map(fn(effort) { Json::string(effort) }),
        ),
        "selected": Json::boolean(model.model_id == selection.model_id),
        "pending": Json::boolean(selection.pending),
      }),
    )
  }
  Json::object({
    "selected": Json::string(selection.model_id),
    "effort": match selection.effort {
      Some(effort) => Json::string(effort)
      None => Json::null()
    },
    "pending": Json::boolean(selection.pending),
    "models": Json::array(entries),
  })
}

///|
/// Compact human status: connection, selection, catalog, services.
fn MagpieRuntime::status_feedback(self : MagpieRuntime) -> String {
  let status = self.manager.connection_status()
  let selection = self.manager.active_selection()
  let effort = match selection.effort {
    Some(effort) => " at effort \{effort}"
    None => ""
  }
  let catalog = "\{self.manager.list_models().length()} models"
  let services = [Route, Quotas, Limit, Usage, UsageRequests, Concurrency]
    .map(fn(service) {
      "\{service}=\{self.intelligence.service_availability(service~)}"
    })
    .join(" ")
  "\{status.describe()}; selected \{selection.model_id}\{effort} (pending=\{selection.pending}); \{catalog}; services: \{services}"
}

///|
/// The full runtime status as structured JSON.
fn MagpieRuntime::status_json(self : MagpieRuntime) -> Json {
  let status = self.manager.connection_status()
  let selection = self.manager.active_selection()
  let services : Array[Json] = [
    Route,
    Quotas,
    Limit,
    Usage,
    UsageRequests,
    Concurrency,
  ].map(fn(service) {
    Json::object({
      "service": Json::string(service.to_string()),
      "availability": Json::string(
        self.intelligence.service_availability(service~).to_string(),
      ),
    })
  })
  Json::object({
    "gateway": Json::string(status.describe()),
    "connected": Json::boolean(status.connected()),
    "selected": Json::string(selection.model_id),
    "effort": match selection.effort {
      Some(effort) => Json::string(effort)
      None => Json::null()
    },
    "pending": Json::boolean(selection.pending),
    "catalog_size": Json::number(
      self.manager.list_models().length().to_double(),
    ),
    "services": Json::array(services),
    "unconfigured_reason": match self.unconfigured_reason {
      Some(reason) => Json::string(reason)
      None => Json::null()
    },
    "active": Json::boolean(self.active),
  })
}

///|
fn magpie_command(
  id~ : String,
  label~ : String,
  description~ : String,
  params~ : Array[@posoco.CommandParam] = [],
) -> @posoco.CommandDef {
  @posoco.CommandDef::{
    id,
    label,
    description,
    category: "magpie",
    ctype: Action,
    params,
    aliases: [],
    shortcut: None,
    icon: None,
    visible: true,
    metadata: None,
  }
}

///|
fn text_param(
  name~ : String,
  label~ : String,
  description~ : String,
  required~ : Bool,
) -> @posoco.CommandParam {
  @posoco.CommandParam::{
    name,
    label,
    description,
    ptype: Str,
    required,
    default: None,
    choices: None,
    positional: true,
  }
}

///|
pub impl @posoco.CommandPort for MagpieRuntime with fn commands(
  self : MagpieRuntime,
) -> Array[@posoco.CommandDef] {
  let _ = self
  [
    magpie_command(
      id="magpie_model",
      label="Switch Magpie Model",
      description="List Magpie models, select one, or apply a reasoning effort",
      params=[
        text_param(
          name="model",
          label="Model",
          description="Opaque model or routing-group id; omit to list the catalog",
          required=false,
        ),
        text_param(
          name="effort",
          label="Effort",
          description="Advertised reasoning effort to apply to the selection",
          required=false,
        ),
      ],
    ),
    magpie_command(
      id="magpie_status",
      label="Magpie Status",
      description="Gateway connection, selection, and service availability",
    ),
    magpie_command(
      id="magpie_refresh",
      label="Refresh Magpie Catalog",
      description="Re-read /v1/models from the gateway",
    ),
    magpie_command(
      id="magpie_route",
      label="Magpie Route",
      description="The routing decision for a session",
      params=[
        text_param(
          name="session",
          label="Session",
          description="Session id to query",
          required=true,
        ),
      ],
    ),
    magpie_command(
      id="magpie_quotas",
      label="Magpie Quotas",
      description="Subscription and plan quota cards",
      params=[
        @posoco.CommandParam::{
          name: "kept",
          label: "Kept",
          description: "Answer from the gateway's last reading without asking vendors",
          ptype: Bool,
          required: false,
          default: None,
          choices: None,
          positional: false,
        },
      ],
    ),
    magpie_command(
      id="magpie_limit",
      label="Magpie Key Limit",
      description="The calling gateway key's own limit status",
    ),
    magpie_command(
      id="magpie_usage",
      label="Magpie Usage",
      description="Gateway usage summary",
      params=[
        text_param(
          name="period",
          label="Period",
          description="today, week, month, or all",
          required=false,
        ),
      ],
    ),
    magpie_command(
      id="magpie_requests",
      label="Magpie Request History",
      description="Request history, one page at a time",
      params=[
        text_param(
          name="period",
          label="Period",
          description="today, week, month, or all",
          required=false,
        ),
        @posoco.CommandParam::{
          name: "offset",
          label: "Offset",
          description: "Rows to skip",
          ptype: Int,
          required: false,
          default: None,
          choices: None,
          positional: false,
        },
        @posoco.CommandParam::{
          name: "limit",
          label: "Limit",
          description: "Rows per page (gateway ceiling 500)",
          ptype: Int,
          required: false,
          default: None,
          choices: None,
          positional: false,
        },
      ],
    ),
    magpie_command(
      id="magpie_concurrency",
      label="Magpie Concurrency",
      description="What the gateway has in flight right now",
    ),
    magpie_command(
      id="magpie_usage_recent",
      label="Magpie Recent Executions",
      description="This runtime's recent execution reports",
    ),
  ]
}

///|
pub impl @posoco.CommandPort for MagpieRuntime with fn invoke(
  self : MagpieRuntime,
  id : String,
  args : Json,
) -> @posoco.CommandOutcome raise @posoco.CommandError {
  self.require_active()
  match id {
    "magpie_model" => {
      let control = self.manager as &@modelmgmt.ModelManagerControl
      let model = runtime_arg_str(args, "model")
      let effort = runtime_arg_str(args, "effort")
      if model is None && effort is None {
        return @posoco.CommandOutcome::Success(
          feedback="Magpie models",
          structured=Some(self.model_catalog_json()),
          ui_hint=Some(@posoco.UiHint::RefreshModelList),
        )
      }
      match model {
        Some(model_id) =>
          control.select_model(model_id) catch {
            @modelmgmt.ModelManagerError::UnknownModel(detail) =>
              raise @posoco.CommandError::InvalidArgs(reason=detail)
            other =>
              raise @posoco.CommandError::InvalidArgs(reason=other.to_string())
          }
        None => ()
      }
      match effort {
        Some(effort) =>
          control.select_effort(effort) catch {
            @modelmgmt.ModelManagerError::UnsupportedEffort(detail) =>
              raise @posoco.CommandError::InvalidArgs(reason=detail)
            @modelmgmt.ModelManagerError::UnknownModel(detail) =>
              raise @posoco.CommandError::InvalidArgs(reason=detail)
            @modelmgmt.ModelManagerError::EffortNotApplicable(detail) =>
              raise @posoco.CommandError::InvalidArgs(reason=detail)
          }
        None => ()
      }
      let selection = control.active_selection()
      let effort_text = match selection.effort {
        Some(effort) => " at effort \{effort}"
        None => ""
      }
      @posoco.CommandOutcome::Success(
        feedback="selected \{selection.model_id}\{effort_text} (pending=\{selection.pending})",
        structured=Some(self.model_catalog_json()),
        ui_hint=Some(@posoco.UiHint::RefreshModelList),
      )
    }
    "magpie_status" =>
      @posoco.CommandOutcome::Success(
        feedback=self.status_feedback(),
        structured=Some(self.status_json()),
        ui_hint=None,
      )
    "magpie_refresh" => {
      try {
        let _ = self.manager.refresh()
      } catch {
        error =>
          return @posoco.CommandOutcome::Failure(
            reason="magpie refresh failed: \{error.to_string()}",
          )
      }
      @posoco.CommandOutcome::Success(
        feedback="catalog refreshed: \{self.manager.list_models().length()} models",
        structured=Some(self.model_catalog_json()),
        ui_hint=Some(@posoco.UiHint::RefreshModelList),
      )
    }
    "magpie_route" => {
      let session = match runtime_arg_str(args, "session") {
        Some(session) => session
        None =>
          raise @posoco.CommandError::InvalidArgs(
            reason="magpie_route needs a session id",
          )
      }
      let snapshot = self.intelligence.route_snapshot(query={
        session,
        after: None,
        wait: None,
      }) catch {
        error =>
          return @posoco.CommandOutcome::Failure(reason=error.to_string())
      }
      let text = match snapshot.route {
        Some(route) =>
          match route.served {
            Some(served) => "served \{served}"
            None =>
              match route.model {
                Some(model) => "trying \{model}"
                None => "routing decided, no member yet"
              }
          }
        None => "no route yet for this session"
      }
      @posoco.CommandOutcome::Success(
        feedback=text,
        structured=Some(
          Json::object({ "route": Json::string(@debug.to_string(snapshot)) }),
        ),
        ui_hint=None,
      )
    }
    "magpie_quotas" => {
      let kept = runtime_arg_bool(args, "kept").unwrap_or(false)
      let snapshot = self.intelligence.quota_snapshot(kept~) catch {
        error =>
          return @posoco.CommandOutcome::Failure(reason=error.to_string())
      }
      let lines = snapshot.cards.map(fn(card) {
        match card.error {
          Some(error) => "\{card.provider}: error (\{error})"
          None => {
            let window_text = match card.windows {
              Some(windows) =>
                windows
                .map(fn(window) {
                  "\{window.name} \{window.used.unwrap_or(0)}%"
                })
                .join(", ")
              None => "no windows"
            }
            "\{card.provider} \{card.plan.unwrap_or("")}: \{window_text}"
          }
        }
      })
      @posoco.CommandOutcome::Success(
        feedback=lines.join("\n"),
        structured=Some(
          Json::object({
            "kept": Json::boolean(snapshot.kept),
            "cards": Json::array(
              snapshot.cards.map(fn(card) { Json::string(card.provider) }),
            ),
          }),
        ),
        ui_hint=None,
      )
    }
    "magpie_limit" => {
      let limit = self.intelligence.key_limit() catch {
        error =>
          return @posoco.CommandOutcome::Failure(reason=error.to_string())
      }
      @posoco.CommandOutcome::Success(
        feedback="gateway key limited=\{limit.limited}",
        structured=Some(
          Json::object({ "limited": Json::boolean(limit.limited) }),
        ),
        ui_hint=None,
      )
    }
    "magpie_usage" => {
      let period = match runtime_arg_str(args, "period") {
        Some("week") => Week
        Some("month") => Month
        Some("all") => All
        _ => Today
      }
      let summary = self.intelligence.usage_summary(period~) catch {
        error =>
          return @posoco.CommandOutcome::Failure(reason=error.to_string())
      }
      let cost = match summary.cost {
        Some(value) => "$\{value}"
        None => "unpriced calls: \{summary.unpriced.unwrap_or(0)}"
      }
      @posoco.CommandOutcome::Success(
        feedback="calls \{summary.calls.unwrap_or(0)}, in \{summary.input_tokens.unwrap_or(0)}, out \{summary.output_tokens.unwrap_or(0)}, cache r/w \{summary.cache_read_tokens.unwrap_or(0)}/\{summary.cache_write_tokens.unwrap_or(0)}, cost \{cost}",
        structured=Some(
          Json::object({
            "period": match summary.period {
              Some(period) => Json::string(period)
              None => Json::null()
            },
            "calls": Json::number(summary.calls.unwrap_or(0).to_double()),
            "cost": match summary.cost {
              Some(value) => Json::number(value)
              None => Json::null()
            },
          }),
        ),
        ui_hint=None,
      )
    }
    "magpie_requests" => {
      let offset = runtime_arg_int(args, "offset").unwrap_or(0)
      let limit = runtime_arg_int(args, "limit").unwrap_or(20)
      let period = match runtime_arg_str(args, "period") {
        Some("week") => Some(Week)
        Some("month") => Some(Month)
        Some("all") => Some(All)
        Some("today") => Some(Today)
        _ => None
      }
      let page = self.intelligence.usage_requests(offset~, limit~, period~) catch {
        error =>
          return @posoco.CommandOutcome::Failure(reason=error.to_string())
      }
      let lines = page.rows.map(fn(row) {
        let cost = match row.cost {
          Some(value) => "$\{value}"
          None => "-"
        }
        "\{row.t.unwrap_or("?")} \{row.agent.unwrap_or("?")} \{row.model.unwrap_or("?")} \{row.input_tokens.unwrap_or(0)}->\{row.output_tokens.unwrap_or(0)} \{cost}"
      })
      @posoco.CommandOutcome::Success(
        feedback="requests \{page.offset.unwrap_or(0)}..\{page.total.unwrap_or(0)}\n\{lines.join("\n")}",
        structured=Some(
          Json::object({
            "offset": Json::number(page.offset.unwrap_or(0).to_double()),
            "total": Json::number(page.total.unwrap_or(0).to_double()),
            "rows": Json::number(page.rows.length().to_double()),
          }),
        ),
        ui_hint=None,
      )
    }
    "magpie_concurrency" => {
      let snapshot = self.intelligence.concurrency_snapshot() catch {
        error =>
          return @posoco.CommandOutcome::Failure(reason=error.to_string())
      }
      @posoco.CommandOutcome::Success(
        feedback="in-flight \{snapshot.requests.length()}, waiting \{snapshot.waiting.unwrap_or(0)}, tools \{snapshot.tools.unwrap_or(0)}",
        structured=Some(
          Json::object({
            "in_flight": Json::number(snapshot.requests.length().to_double()),
            "waiting": Json::number(snapshot.waiting.unwrap_or(0).to_double()),
            "tools": Json::number(snapshot.tools.unwrap_or(0).to_double()),
          }),
        ),
        ui_hint=None,
      )
    }
    "magpie_usage_recent" => {
      let reports = self.recent_reports()
      if reports is [] {
        return @posoco.CommandOutcome::Success(
          feedback="no executions yet",
          structured=Some(Json::object({ "reports": Json::array([]) })),
          ui_hint=None,
        )
      }
      let lines = reports.map(fn(report) {
        let served = match report.served_model {
          Some(model) => model
          None => "?"
        }
        let input = match report.usage {
          Some(usage) => usage.input_tokens.unwrap_or(0)
          None => 0
        }
        "\{report.requested_model} → \{served} via \{report.protocol} (\{report.kind}) in=\{input}"
      })
      @posoco.CommandOutcome::Success(
        feedback=lines.join("\n"),
        structured=Some(
          Json::object({ "reports": Json::number(reports.length().to_double()) }),
        ),
        ui_hint=None,
      )
    }
    _ => raise @posoco.CommandError::NotFound(id)
  }
}

///|
/// Lifecycle: `on_start` refreshes the catalog; an offline gateway leaves
/// the explicit offline state instead of failing startup. `on_shutdown`
/// deactivates the runtime and drops owned observation state.
pub impl @posoco.Lifecycle for MagpieRuntime with fn on_start(
  self : MagpieRuntime,
) -> Unit {
  try {
    let _ = self.manager.refresh()
  } catch {
    _ => ()
  }
}

///|
pub impl @posoco.Lifecycle for MagpieRuntime with fn on_shutdown(
  self : MagpieRuntime,
) -> Unit {
  self.active = false
  self.reports.val = []
}

///|
pub impl @posoco.Extension for MagpieRuntime with fn extension_id(
  _self : MagpieRuntime,
) -> String {
  "posoco_ext_magpie"
}

///|
pub impl @posoco.Extension for MagpieRuntime with fn manifest(
  self : MagpieRuntime,
) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(
    id="posoco_ext_magpie",
    models=[self.port],
    commands=[self],
    lifecycle=[self],
  )
}

///|
pub extend MagpieRuntime with @posoco.Extension::{extension_id, manifest}

///|
pub extend MagpieRuntime with @posoco.Lifecycle::{
  on_compose,
  on_start,
  on_shutdown,
}

///|
pub extend MagpieRuntime with @posoco.CommandPort::{commands, invoke}
