///|
/// config.mbt — typed Magpie gateway configuration.
///
/// The configuration is the whole setup surface of this control plane: where
/// the gateway is, which credential authenticates it, whether the manager is
/// enabled, and the persisted selection seed a host restored from its own
/// storage. The credential is never exposed through `Debug`, `Show`, or any
/// error text.

///|
/// Gateway base URL used when configuration does not name one: Magpie's
/// documented local gateway address.
pub const DEFAULT_GATEWAY_URL : String = "http://127.0.0.1:3425"

///|
/// Local application identity token, following Magpie's documented
/// `magpie-<app-id>` convention: the gateway attributes every call sent with
/// this token to the app id `posoco`. It is only ever sent to loopback
/// endpoints; remote endpoints require an explicitly configured credential.
pub const LOCAL_APP_TOKEN : String = "magpie-posoco"

///|
/// Default per-request connect timeout in milliseconds.
pub const DEFAULT_CONNECT_TIMEOUT_MS : Int32 = 5000

///|
/// Stable manager identity reported by `ModelManagerControl::manager_id`.
pub const MANAGER_ID : String = "magpie"

///|
/// Typed Magpie gateway configuration.
///
/// The persisted selection seed (`selected_model`/`selected_effort`) is what
/// a host restored from its own storage before handing the config over. A
/// seeded model missing from the current catalog stays `pending` — it is
/// never rewritten and never replaced by a default. Seeding an effort
/// without a model is a configuration error.
pub struct MagpieConfig {
  /// Gateway base URL, normalized (no trailing slash); http/https only.
  base_url : String
  /// Explicitly configured gateway credential, sent as
  /// `Authorization: Bearer <credential>` to every endpoint. Required for
  /// remote (non-loopback) gateways; on loopback the local application token
  /// `magpie-posoco` is used when this is `None`.
  credential : String?
  /// Per-request connect timeout in milliseconds.
  connect_timeout_ms : Int32
  /// Explicit enable/disable. A disabled manager refuses refresh and reports
  /// `Disabled`; it never touches the network.
  enabled : Bool
  /// Persisted model selection seed; `None` = nothing persisted yet.
  selected_model : String?
  /// Persisted explicit reasoning-effort seed. Only meaningful together
  /// with `selected_model`.
  selected_effort : String?
} derive(Eq)

///|
/// Creates a normalized, validated configuration. Raises
/// `MagpieGatewayError::InvalidConfig` for an unusable base URL, a
/// non-positive timeout, or an effort seeded without a model.
pub fn MagpieConfig::MagpieConfig(
  base_url~ : String = DEFAULT_GATEWAY_URL,
  credential~ : String? = None,
  connect_timeout_ms~ : Int32 = DEFAULT_CONNECT_TIMEOUT_MS,
  enabled~ : Bool = true,
  selected_model~ : String? = None,
  selected_effort~ : String? = None,
) -> MagpieConfig raise MagpieGatewayError {
  let normalized = normalize_base_url(base_url)
  if connect_timeout_ms <= 0 {
    raise MagpieGatewayError::InvalidConfig(
      "connect_timeout_ms must be positive, got \{connect_timeout_ms}",
    )
  }
  if selected_model is None && selected_effort is Some(_) {
    raise MagpieGatewayError::InvalidConfig(
      "selected_effort is set without selected_model",
    )
  }
  {
    base_url: normalized,
    credential,
    connect_timeout_ms,
    enabled,
    selected_model,
    selected_effort,
  }
}

///|
/// Strips at most one trailing slash and validates the scheme. Only
/// `http://` and `https://` absolute URLs are accepted.
fn normalize_base_url(url : String) -> String raise MagpieGatewayError {
  let trimmed : String = url.trim().to_owned()
  let has_http = trimmed.has_prefix("http://")
  let has_https = trimmed.has_prefix("https://")
  if !has_http && !has_https {
    raise MagpieGatewayError::InvalidConfig(
      "base_url must be an absolute http(s) URL",
    )
  }
  if trimmed is "http://" || trimmed is "https://" {
    raise MagpieGatewayError::InvalidConfig("base_url names no host")
  }
  // Gateway base URL is an origin, never a path, query, fragment or URL
  // containing credentials. Otherwise Authorization could be sent to an
  // unintended destination or secrets could leak through diagnostics.
  let origin = if trimmed.has_suffix("/") {
    trimmed[:trimmed.length() - 1].to_owned()
  } else {
    trimmed
  }
  let authority = if has_https {
    origin[8:]
  } else {
    origin[7:]
  }
  if authority == "" || authority.contains("/") || authority.contains("?") ||
    authority.contains("#") || authority.contains("@") || authority.contains("\\") ||
    authority.contains(" ") {
    raise MagpieGatewayError::InvalidConfig(
      "base_url must be a gateway origin without path, query or userinfo",
    )
  }
  if trimmed.has_suffix("/") {
    trimmed[:trimmed.length() - 1].to_owned()
  } else {
    trimmed
  }
}

///|
/// Redacted rendering of the configuration: the credential, if any, appears
/// only as `<redacted>`, in both the `Debug` and `Show` renderings. Never
/// derive `Debug`/`Show` over the raw struct.
pub impl Debug for MagpieConfig with fn to_repr(self) -> @debug.Repr {
  @debug.Repr::Repr(self.to_string())
}

///|
pub extend MagpieConfig with Eq::{not_equal, equal}

///|
pub extend MagpieConfig with Show::{to_string, output}

///|
pub impl Show for MagpieConfig with fn to_string(self : MagpieConfig) -> String {
  let credential = match self.credential {
    Some(_) => "Some(<redacted>)"
    None => "None"
  }
  let selected_model = match self.selected_model {
    Some(id) => "Some(\{id})"
    None => "None"
  }
  let selected_effort = match self.selected_effort {
    Some(effort) => "Some(\{effort})"
    None => "None"
  }
  "MagpieConfig(base_url=\{self.base_url}, credential=\{credential}, connect_timeout_ms=\{self.connect_timeout_ms}, enabled=\{self.enabled}, selected_model=\{selected_model}, selected_effort=\{selected_effort})"
}
