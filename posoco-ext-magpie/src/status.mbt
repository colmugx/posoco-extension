///|
/// status.mbt — connection status vocabulary of the Magpie control plane.
///
/// The status is the manager's own honest report about its gateway. It is
/// deliberately separate from the catalog: after a failed refresh the manager
/// keeps serving its last-known-good catalog while the status says the data
/// is not verified current. Stale catalog data is never presented as
/// real-time availability.

///|
/// Connection status of a `MagpieManager`, distinguishing exactly the states
/// a host needs to phrase feedback: unconfigured, disabled, unreachable,
/// rejected credential, not actually Magpie, connected with an empty catalog,
/// and connected successfully.
pub(all) enum MagpieConnectionStatus {
  /// Fresh manager that has neither connected nor failed yet.
  NotConfigured
  /// The manager is configured with `enabled = false`.
  Disabled
  /// The gateway is unreachable; the payload quotes the transport reason.
  Offline(String)
  /// The gateway rejected the presented credential (HTTP 401/403).
  AuthFailed(String)
  /// The endpoint answered but is not a usable Magpie gateway (identity
  /// miss, non-2xx status, or an unparsable/malformed payload).
  InvalidGateway(String)
  /// Connected successfully; `/v1/models` exposed no models.
  EmptyCatalog
  /// Connected successfully with a non-empty catalog. Carries the gateway's
  /// self-reported version from `/api/hello` when it named one.
  Connected(String?)
} derive(Eq, Debug)

///|
pub extend MagpieConnectionStatus with Eq::{not_equal, equal}

///|
pub extend MagpieConnectionStatus with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub impl Show for MagpieConnectionStatus with fn to_string(
  self : MagpieConnectionStatus,
) -> String {
  match self {
    NotConfigured => "NotConfigured"
    Disabled => "Disabled"
    Offline(_) => "Offline(..)"
    AuthFailed(_) => "AuthFailed(..)"
    InvalidGateway(_) => "InvalidGateway(..)"
    EmptyCatalog => "EmptyCatalog"
    Connected(Some(v)) => "Connected(\{v})"
    Connected(None) => "Connected(..)"
  }
}

///|
pub extend MagpieConnectionStatus with Show::{to_string, output}

///|
/// `true` only for `Connected` and `EmptyCatalog` — the states where the
/// catalog was verified against a live Magpie gateway.
pub fn MagpieConnectionStatus::connected(self : MagpieConnectionStatus) -> Bool {
  match self {
    Connected(_) | EmptyCatalog => true
    _ => false
  }
}

///|
/// Human-facing one-line description. Never contains credentials.
pub fn MagpieConnectionStatus::describe(
  self : MagpieConnectionStatus,
) -> String {
  match self {
    NotConfigured => "not connected: no refresh has run yet"
    Disabled => "disabled: the manager is configured with enabled = false"
    Offline(reason) => "gateway offline: \{reason}"
    AuthFailed(reason) => "authentication failed: \{reason}"
    InvalidGateway(reason) => "invalid gateway response: \{reason}"
    EmptyCatalog => "connected: the gateway exposes no models"
    Connected(version) =>
      match version {
        Some(v) => "connected to magpie \{v}"
        None => "connected to magpie"
      }
  }
}
