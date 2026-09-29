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
pub(open) trait BoardWebServer {
  fn attach_event_hub(Self, hub : BoardEventHub) -> Unit
  async fn bind(Self) -> Result[BoardEndpoint, String]
  async fn run(Self) -> Result[Unit, String]
  fn browser_url(Self) -> String?
  fn close(Self) -> Unit
  fn is_alive(Self) -> Bool
  fn last_error(Self) -> String?
}

///|
/// Target seam for focusing/opening the Board page.
pub(open) trait BrowserOpener {
  async fn open(Self, url : String) -> Result[Unit, String]
}
