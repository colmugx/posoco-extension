///|
/// manager.mbt — the Magpie Model Manager.
///
/// `MagpieManager` is a peer-level `ModelManagerControl` implementation: it
/// owns Magpie gateway configuration, catalog discovery, and selection
/// state, with no dependency on `posoco-ext-llm`, any provider extension,
/// or a concrete transport. Execution (`ModelPort`, `/v1/messages`) is a
/// later layer and is deliberately absent here.

///|
/// Report of one successful refresh: catalog size, how the swap changed it,
/// and the duplicate ids the gateway sent.
pub(all) struct MagpieRefreshOutcome {
  /// Number of models in the new catalog.
  total : Int32
  /// Models present now that were absent before the swap.
  added : Int32
  /// Models absent now that were present before the swap.
  removed : Int32
  /// Duplicate ids the gateway sent; the first occurrence won.
  duplicates : Array[String]
} derive(Eq, Debug)

///|
pub extend MagpieRefreshOutcome with Eq::{not_equal, equal}

///|
pub extend MagpieRefreshOutcome with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Independent Model Manager for a Magpie gateway.
///
/// State model:
/// - The catalog exists only after a successful refresh; an empty catalog is
///   itself a successful, reportable state (`EmptyCatalog`).
/// - A failed refresh raises, updates only the connection status, and leaves
///   catalog and selection untouched: the last-known-good catalog keeps
///   serving while the status says it is not verified current.
/// - Refresh never rewrites the selection. A selected model the gateway no
///   longer exposes reports `pending = true` until it reappears.
///
/// Concurrency: `refresh` is async and serializes overlapping refreshes
/// through an internal mutex, so each refresh — fetch, decode, and atomic
/// catalog swap — completes as a unit. The synchronous trait methods
/// (`list_models`, `select_model`, …) contain no yield points and are atomic
/// under the cooperative async runtime.
pub struct MagpieManager {
  priv config : MagpieConfig
  priv transport : &MagpieTransport
  priv gate : @async.Mutex
  priv mut catalog : Array[MagpieCatalogEntry]
  priv mut status : MagpieConnectionStatus
  /// Active model id; `""` = nothing selected or persisted yet.
  priv mut selected_model : String
  /// Explicit effort applied on top of the model's own default.
  priv mut selected_effort : String?
  priv mut last_report : MagpieRefreshOutcome?
}

///|
/// Creates a manager. `transport` defaults to real gateway HTTP; tests
/// inject a scripted one. Raises `MagpieGatewayError::InvalidConfig` when
/// the configuration itself is unusable.
pub fn MagpieManager::MagpieManager(
  config~ : MagpieConfig,
  transport~ : &MagpieTransport = HttpMagpieTransport::HttpMagpieTransport(),
) -> MagpieManager {
  let (selected_model, selected_effort) = match config.selected_model {
    Some(model_id) => (model_id, config.selected_effort)
    None => ("", None)
  }
  {
    config,
    transport,
    gate: @async.Mutex::Mutex(),
    catalog: [],
    status: NotConfigured,
    selected_model,
    selected_effort,
    last_report: None,
  }
}

///|
/// Current connection status, as of the last refresh attempt.
pub fn MagpieManager::connection_status(
  self : MagpieManager,
) -> MagpieConnectionStatus {
  self.status
}

///|
/// Report of the last successful refresh, if any has succeeded.
pub fn MagpieManager::last_refresh_report(
  self : MagpieManager,
) -> MagpieRefreshOutcome? {
  self.last_report
}

///|
/// One refresh cycle: validate identity (`/api/hello`), decode the catalog
/// (`/v1/models`), then swap atomically. Raises `MagpieGatewayError` on any
/// failure; the connection status always reflects the outcome.
#warnings("-fragile_catch_all")
pub async fn MagpieManager::refresh(
  self : MagpieManager,
) -> MagpieRefreshOutcome raise MagpieGatewayError {
  // The arm only maps the typed error to its status and re-raises it; the
  // lint's errdefer simplification does not apply to error-mapping wrappers.
  self.refresh_cycle() catch {
    error => {
      self.status = status_for(error)
      raise error
    }
  }
}

///|
async fn MagpieManager::refresh_cycle(
  self : MagpieManager,
) -> MagpieRefreshOutcome raise MagpieGatewayError {
  if !self.config.enabled {
    raise MagpieGatewayError::Disabled
  }
  // `effective_token` returns `None` only for a remote endpoint without an
  // explicitly configured credential; the local application token never
  // leaves loopback.
  guard effective_token(self.config) is Some(token) else {
    raise MagpieGatewayError::NotConfigured(
      "remote gateway requires an explicitly configured credential",
    )
  }
  // Serialize overlapping refreshes: fetch, decode, and swap complete as
  // one unit per caller. The lock is released on every exit path, failed
  // cycles included, so one gateway failure can never wedge the manager.
  self.gate.acquire()
  defer self.gate.release()
  let hello_body = self.fetch_validated("/api/hello", token)
  let identity = parse_hello(hello_body)
  let models_body = self.fetch_validated("/v1/models", token)
  let report = decode_catalog(models_body)
  let previous : Map[String, Bool] = Map::from_array([])
  for entry in self.catalog {
    previous[entry.info.model_id] = true
  }
  let next : Map[String, Bool] = Map::from_array([])
  for entry in report.entries {
    next[entry.info.model_id] = true
  }
  let mut added = 0
  for entry in report.entries {
    if !previous.contains(entry.info.model_id) {
      added += 1
    }
  }
  let mut removed = 0
  for id, _ in previous {
    if !next.contains(id) {
      removed += 1
    }
  }
  let outcome : MagpieRefreshOutcome = {
    total: report.entries.length(),
    added,
    removed,
    duplicates: report.duplicates,
  }
  self.catalog = report.entries
  self.status = if report.entries is [] {
    EmptyCatalog
  } else {
    Connected(identity.version)
  }
  self.last_report = Some(outcome)
  outcome
}

///|
/// One transport GET with status classification. Network failures pass
/// through as `Offline`; non-2xx becomes `AuthenticationFailed` or
/// `InvalidResponse` without ever quoting the body.
async fn MagpieManager::fetch_validated(
  self : MagpieManager,
  path : String,
  token : String,
) -> String raise MagpieGatewayError {
  let (code, body) = self.transport.get(
    gateway_url(self.config, path),
    gateway_headers(token),
  )
  if code == 401 || code == 403 {
    raise MagpieGatewayError::AuthenticationFailed(
      "\{path} answered HTTP \{code}",
    )
  }
  if code < 200 || code >= 300 {
    raise MagpieGatewayError::InvalidResponse("\{path} answered HTTP \{code}")
  }
  body
}

///|
/// The status a refresh failure leaves behind. Catalog and selection are
/// untouched by this mapping — it only names what went wrong.
fn status_for(error : MagpieGatewayError) -> MagpieConnectionStatus {
  match error {
    Disabled => Disabled
    NotConfigured(_) => NotConfigured
    Offline(detail) => Offline(detail)
    AuthenticationFailed(detail) => AuthFailed(detail)
    WrongIdentity(detail) => InvalidGateway(detail)
    InvalidResponse(detail) => InvalidGateway(detail)
    // Refresh revalidates nothing the constructor has not already accepted;
    // this arm exists for exhaustiveness only.
    InvalidConfig(_) => NotConfigured
  }
}

///|
pub extend MagpieManager with @modelmgmt.ModelManagerControl::{
  manager_id,
  list_models,
  active_selection,
  select_model,
  select_effort,
}

///|
/// Control-plane contract of the Magpie manager: identity, catalog
/// snapshots, selection reporting, and validated selection switching.
pub impl @modelmgmt.ModelManagerControl for MagpieManager with fn manager_id(
  _self : MagpieManager,
) -> String {
  MANAGER_ID
}

///|
/// Fresh copies of the neutral projections, in server order. Mutating a
/// returned snapshot never affects the manager or earlier snapshots.
pub impl @modelmgmt.ModelManagerControl for MagpieManager with fn list_models(
  self : MagpieManager,
) -> Array[@modelmgmt.ManagerModelInfo] {
  self.catalog.map(fn(entry) {
    let info = entry.info
    {
      model_id: info.model_id,
      label: info.label,
      provider_id: info.provider_id,
      context_window: info.context_window,
      capabilities: info.capabilities.copy(),
      efforts: info.efforts.copy(),
      default_effort: info.default_effort,
      display_group: info.display_group,
    }
  })
}

///|
/// The logical selection. `pending` marks a selected id the current catalog
/// does not carry — including the never-selected `""` of a fresh manager.
pub impl @modelmgmt.ModelManagerControl for MagpieManager with fn active_selection(
  self : MagpieManager,
) -> @modelmgmt.ManagerSelection {
  {
    model_id: self.selected_model,
    effort: self.selected_effort,
    pending: !self.catalog
    .iter()
    .any(fn(entry) { entry.info.model_id == self.selected_model }),
  }
}

///|
/// Switches the active model. Unknown ids raise `UnknownModel` without
/// mutating anything; a successful switch resets any explicit effort.
pub impl @modelmgmt.ModelManagerControl for MagpieManager with fn select_model(
  self : MagpieManager,
  model_id : String,
) -> Unit raise @modelmgmt.ModelManagerError {
  guard self.catalog.iter().any(fn(entry) { entry.info.model_id == model_id }) else {
    raise @modelmgmt.ModelManagerError::UnknownModel(
      "unknown magpie model: \{model_id}",
    )
  }
  self.selected_model = model_id
  self.selected_effort = None
}

///|
/// Applies an explicit reasoning effort to the active model. A missing or
/// pending selection raises `UnknownModel`; an effort the model does not
/// advertise raises `UnsupportedEffort`. `EffortNotApplicable` is not
/// reachable in this control plane: recording an effort cannot fail once
/// the model is known — execution-layer application belongs to the next
/// PR, which owns that failure mode.
pub impl @modelmgmt.ModelManagerControl for MagpieManager with fn select_effort(
  self : MagpieManager,
  effort : String,
) -> Unit raise @modelmgmt.ModelManagerError {
  guard self.selected_model != "" else {
    raise @modelmgmt.ModelManagerError::UnknownModel("no magpie model selected")
  }
  let mut entry : MagpieCatalogEntry? = None
  for candidate in self.catalog {
    if candidate.info.model_id == self.selected_model {
      entry = Some(candidate)
    }
  }
  guard entry is Some(entry) else {
    raise @modelmgmt.ModelManagerError::UnknownModel(
      "active magpie model is not in the catalog: \{self.selected_model}",
    )
  }
  guard entry.info.efforts.contains(effort) else {
    raise @modelmgmt.ModelManagerError::UnsupportedEffort(
      "magpie model \{self.selected_model} does not advertise effort \"\{effort}\"",
    )
  }
  self.selected_effort = Some(effort)
}
