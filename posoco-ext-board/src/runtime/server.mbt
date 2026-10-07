///|
/// Public endpoint metadata is intentionally token-free. The instance secret
/// never crosses this value boundary.
pub(all) struct BoardEndpoint {
  host : String
  port : Int
} derive(Eq, Debug)

///|
pub extend BoardEndpoint with Eq::{equal, not_equal}

///|
pub extend BoardEndpoint with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn BoardEndpoint::base_url(self : BoardEndpoint) -> String {
  "http://\{self.host}:\{self.port}"
}

///|
pub fn BoardEndpoint::ws_url(self : BoardEndpoint) -> String {
  "ws://\{self.host}:\{self.port}/ws"
}

///|
pub(all) enum BoardServerStatus {
  Stopped
  Starting
  Running(BoardEndpoint)
  Stopping
  Failed(String)
} derive(Eq, Debug)

///|
pub extend BoardServerStatus with Eq::{equal, not_equal}

///|
pub extend BoardServerStatus with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn BoardServerStatus::to_json(self : BoardServerStatus) -> Json {
  match self {
    Stopped => Json::object({ "state": Json::string("stopped") })
    Starting => Json::object({ "state": Json::string("starting") })
    Stopping => Json::object({ "state": Json::string("stopping") })
    Failed(error) =>
      Json::object({
        "state": Json::string("failed"),
        "error": Json::string(error),
      })
    Running(endpoint) =>
      Json::object({
        "state": Json::string("running"),
        "host": Json::string(endpoint.host),
        "port": Json::number(endpoint.port.to_double()),
        "url": Json::string(endpoint.base_url()),
      })
  }
}

///|
/// Target seam for the local Board control plane. Implementations own the
/// instance token and must never expose it through endpoint/status values.
/// The snapshot provider awaits the durable coordinator and returns the
/// composite wire snapshot, or a resync reason when no trustworthy snapshot
/// can be produced; the runtime installs exactly one per server while
/// starting the control plane.
pub(open) trait BoardWebServer {
  async fn bind(Self) -> Result[BoardEndpoint, String]
  async fn run(Self) -> Result[Unit, String]
  fn browser_url(Self) -> String?
  fn close(Self) -> Unit
  fn is_alive(Self) -> Bool
  fn last_error(Self) -> String?
  /// Install the authoritative snapshot provider. Default: none — a server
  /// without a provider answers snapshot-required subscriptions with an
  /// explicit resync frame and closes, instead of fabricating a snapshot.
  async fn set_snapshot_provider(
    Self,
    provider : async () -> Result[@protocol.BoardSnapshot, String],
  ) -> Unit = _
  /// Install the authoritative command handler. Default: none — a server
  /// without a handler answers every `Command` with `accepted=false`
  /// (`"unsupported_in_current_stage"`) and mutates nothing. Symmetric to
  /// `set_snapshot_provider`: the runtime installs exactly one per server
  /// while starting the control plane, and the returned result is answered
  /// only on the issuing connection.
  async fn set_command_handler(
    Self,
    handler : async (@protocol.BoardClientCommand) -> @protocol.BoardCommandResult,
  ) -> Unit = _
}

///|
impl BoardWebServer with fn set_snapshot_provider(
  _self,
  _provider : async () -> Result[@protocol.BoardSnapshot, String],
) -> Unit {
  ()
}

///|
impl BoardWebServer with fn set_command_handler(
  _self,
  _handler : async (@protocol.BoardClientCommand) -> @protocol.BoardCommandResult,
) -> Unit {
  ()
}

///|
/// Target seam for focusing/opening the Board page.
pub(open) trait BrowserOpener {
  async fn open(Self, url : String) -> Result[Unit, String]
}
