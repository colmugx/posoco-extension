///|
/// errors.mbt — typed failures of the Magpie control plane.

///|
/// Typed failures of talking to a Magpie gateway. Every constructor names a
/// distinct situation so hosts can phrase recovery precisely. Error text is
/// structural only: it never carries response bodies, authorization headers,
/// or credentials.
pub(all) suberror MagpieGatewayError {
  /// The module's own configuration is unusable (bad base URL, an effort
  /// seeded without a model). Raised at construction, never by the gateway.
  InvalidConfig(String)
  /// The manager is configured with `enabled = false`.
  Disabled
  /// The gateway cannot be reached with what is configured — today only a
  /// non-loopback endpoint without an explicitly configured credential.
  NotConfigured(String)
  /// The gateway is unreachable (connection refused, DNS, timeout).
  Offline(String)
  /// The gateway rejected the presented credential (HTTP 401/403).
  AuthenticationFailed(String)
  /// The endpoint answered but is not Magpie (`/api/hello` identity miss).
  WrongIdentity(String)
  /// The gateway answered but its payload is not a valid Magpie response
  /// (non-2xx status, unparsable JSON, malformed required fields).
  InvalidResponse(String)
} derive(Debug)

///|
pub extend MagpieGatewayError with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend MagpieGatewayError with Show::{to_string, output}

///|
pub impl Show for MagpieGatewayError with fn to_string(self) -> String {
  match self {
    InvalidConfig(detail) => "MagpieGatewayError::InvalidConfig(\{detail})"
    Disabled => "MagpieGatewayError::Disabled"
    NotConfigured(detail) => "MagpieGatewayError::NotConfigured(\{detail})"
    Offline(detail) => "MagpieGatewayError::Offline(\{detail})"
    AuthenticationFailed(detail) =>
      "MagpieGatewayError::AuthenticationFailed(\{detail})"
    WrongIdentity(detail) => "MagpieGatewayError::WrongIdentity(\{detail})"
    InvalidResponse(detail) => "MagpieGatewayError::InvalidResponse(\{detail})"
  }
}
