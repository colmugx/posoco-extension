///|
/// intelligence.mbt — the typed gateway intelligence client.
///
/// A read-only client over Magpie's documented control and observability
/// endpoints. It never touches model execution: availability is recorded
/// per service and kept independent from the inference connection, so one
/// forbidden or missing monitoring endpoint never marks the manager
/// offline. Response shapes follow the gateway's documented behavior and
/// observed responses; fields are never invented, and diagnostics quote
/// statuses and documented codes — never bodies, credentials, or session
/// identifiers.

///|
/// Query parameters for one route poll.
pub(all) struct MagpieRouteQuery {
  session : String
  /// Hold the answer until the route changes past this sequence number.
  after : Int32?
  /// Long-poll wait in seconds; the gateway allows up to 60.
  wait : Int32?
} derive(Eq, Debug)

///|
pub extend MagpieRouteQuery with Eq::{not_equal, equal}

///|
pub extend MagpieRouteQuery with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Read-only, typed access to Magpie's gateway intelligence. Share the
/// manager's configuration and transport; keep no global state.
pub struct MagpieGatewayIntelligence {
  priv config : MagpieConfig
  priv transport : &MagpieTransport
  priv availability : Map[String, MagpieServiceAvailability]
}

///|
pub fn MagpieGatewayIntelligence::MagpieGatewayIntelligence(
  config~ : MagpieConfig,
  transport~ : &MagpieTransport = HttpMagpieTransport::HttpMagpieTransport(),
) -> MagpieGatewayIntelligence {
  { config, transport, availability: Map::from_array([]), }
}

///|
/// Builds an intelligence client over a manager's configuration.
pub fn MagpieGatewayIntelligence::for_manager(
  manager : MagpieManager,
) -> MagpieGatewayIntelligence {
  {
    config: manager.config,
    transport: manager.transport,
    availability: Map::from_array([]),
  }
}

///|
/// The last recorded availability of a service; `Unknown` before the first
/// probe.
pub fn MagpieGatewayIntelligence::service_availability(
  self : MagpieGatewayIntelligence,
  service~ : MagpieService,
) -> MagpieServiceAvailability {
  match self.availability.get(service.to_string()) {
    Some(state) => state
    None => Unknown
  }
}

///|
fn MagpieGatewayIntelligence::record(
  self : MagpieGatewayIntelligence,
  service~ : MagpieService,
  state~ : MagpieServiceAvailability,
) -> Unit {
  self.availability[service.to_string()] = state
}

///|
fn hex_digit(d : Int32) -> String {
  if d < 10 {
    "\{d}"
  } else {
    ["A", "B", "C", "D", "E", "F"][d - 10]
  }
}

///|
/// Percent-encodes one query value: UTF-8 bytes, uppercase hex. Unreserved
/// characters pass through; everything else is escaped, so session ids and
/// filter values stay inert.
fn query_encode(value : String) -> String {
  let keep = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
  let out = StringBuilder()
  fn write_byte(byte : Int32) -> Unit {
    out.write_string("%\{hex_digit((byte >> 4) & 0xF)}\{hex_digit(byte & 0xF)}")
  }

  fn write_utf8(cp : Int32) -> Unit {
    if cp < 0x80 {
      write_byte(cp)
    } else if cp < 0x800 {
      write_byte(0xC0 | (cp >> 6))
      write_byte(0x80 | (cp & 0x3F))
    } else if cp < 0x10000 {
      write_byte(0xE0 | (cp >> 12))
      write_byte(0x80 | ((cp >> 6) & 0x3F))
      write_byte(0x80 | (cp & 0x3F))
    } else {
      write_byte(0xF0 | (cp >> 18))
      write_byte(0x80 | ((cp >> 12) & 0x3F))
      write_byte(0x80 | ((cp >> 6) & 0x3F))
      write_byte(0x80 | (cp & 0x3F))
    }
  }

  for ch in value {
    let text = ch.to_string()
    if keep.contains(text) {
      out.write_string(text)
    } else {
      write_utf8(ch.to_int())
    }
  }
  out.to_string()
}

///|
/// Assembles `path?query` from ordered pairs, skipping empty values.
fn build_query(path : String, pairs : Array[(String, String)]) -> String {
  let parts : Array[String] = []
  for pair in pairs {
    let (key, value) = pair
    if value != "" {
      parts.push("\{key}=\{query_encode(value)}")
    }
  }
  if parts.is_empty() {
    path
  } else {
    path + "?" + parts.join("&")
  }
}

///|
/// One intelligence GET: sends the configured credential, classifies the
/// status into the service-availability model, records it, and raises the
/// matching Posoco error on anything but success. 200 returns the body.
async fn MagpieGatewayIntelligence::fetch(
  self : MagpieGatewayIntelligence,
  service~ : MagpieService,
  path~ : String,
) -> String raise @posoco.ModelError {
  let token = match effective_token(self.config) {
    Some(token) => token
    None => {
      self.record(service~, state=Forbidden)
      raise @posoco.ModelError::RequestBuild(
        "magpie intelligence request build failure (stage=\{service}): remote gateway requires an explicitly configured credential",
      )
    }
  }
  let headers = gateway_headers(token)
  let (code, body) = self.transport.get(gateway_url(self.config, path), headers) catch {
    error => {
      self.record(service~, state=TemporarilyUnavailable)
      raise @posoco.ModelError::Transport(
        "magpie intelligence transport failure (stage=\{service}): \{error.to_string()}",
      )
    }
  }
  if is_http_success(code) {
    self.record(service~, state=Accessible)
    return body
  }
  // The documented denial shape is {"code":"gateway_key_held"}; the code is
  // quoted, the body never is.
  let held = body.contains("gateway_key_held")
  let state = if code == 401 || code == 403 {
    Forbidden
  } else if code == 404 {
    NotSupported
  } else {
    TemporarilyUnavailable
  }
  self.record(service~, state~)
  let reason = if code == 401 {
    "unauthenticated"
  } else if code == 403 {
    if held {
      "forbidden (gateway_key_held)"
    } else {
      "forbidden"
    }
  } else if code == 404 {
    "not supported by this gateway version"
  } else if code == 429 {
    "rate limited"
  } else {
    "gateway error"
  }
  raise @posoco.ModelError::Transport(
    "magpie intelligence failure (stage=\{service}, status=\{code}, \{reason})",
  )
}

///|
/// Strict field decoders. Known fields with wrong shapes are malformed;
/// unknown fields are ignored, and optional fields stay optional.
fn intel_error(stage : String, category : String) -> @posoco.ModelError {
  @posoco.ModelError::ResponseParse(
    "magpie intelligence parse failure (stage=\{stage}, category=\{category})",
  )
}

///|
fn intel_object(
  body : String,
  stage : String,
) -> Map[String, Json] raise @posoco.ModelError {
  let value = @json.parse(body) catch {
    _ => raise intel_error(stage, "invalid_json")
  }
  guard value is Json::Object(fields) else {
    raise intel_error(stage, "not_object")
  }
  fields
}

///|
fn intel_str(
  fields : Map[String, Json],
  key : String,
  stage : String,
) -> String? raise @posoco.ModelError {
  match fields.get(key) {
    None => None
    Some(Json::Null) => None
    Some(Json::String(text)) => Some(text)
    Some(_) => raise intel_error("\{stage}.\{key}", "wrong_type")
  }
}

///|
fn intel_int(
  fields : Map[String, Json],
  key : String,
  stage : String,
) -> Int32? raise @posoco.ModelError {
  match fields.get(key) {
    None => None
    Some(Json::Null) => None
    Some(Json::Number(value, ..)) if value >= 0.0 && value <= 2147483647.0 && value == value.floor() => Some(value.to_int())
    Some(Json::Number(_, ..)) => raise intel_error("\{stage}.\{key}", "out_of_range_or_fractional")
    Some(_) => raise intel_error("\{stage}.\{key}", "wrong_type")
  }
}

///|
fn intel_double(
  fields : Map[String, Json],
  key : String,
  stage : String,
) -> Double? raise @posoco.ModelError {
  match fields.get(key) {
    None => None
    Some(Json::Null) => None
    Some(Json::Number(value, ..)) => Some(value)
    Some(_) => raise intel_error("\{stage}.\{key}", "wrong_type")
  }
}

///|
fn intel_bool(
  fields : Map[String, Json],
  key : String,
  stage : String,
) -> Bool? raise @posoco.ModelError {
  match fields.get(key) {
    None => None
    Some(Json::Null) => None
    Some(Json::True) => Some(true)
    Some(Json::False) => Some(false)
    Some(_) => raise intel_error("\{stage}.\{key}", "wrong_type")
  }
}

///|
/// The session's latest routing state.
pub async fn MagpieGatewayIntelligence::route_snapshot(
  self : MagpieGatewayIntelligence,
  query~ : MagpieRouteQuery,
) -> MagpieRouteSnapshot raise @posoco.ModelError {
  if query.session == "" || (query.after is Some(n) && n < 0) ||
    (query.wait is Some(seconds) && (seconds < 0 || seconds > 60)) {
    raise @posoco.ModelError::RequestBuild(
      "magpie intelligence request build failure (stage=route): wait is limited to 60 seconds",
    )
  }
  let pairs : Array[(String, String)] = [("session", query.session)]
  match query.after {
    Some(after) => pairs.push(("after", after.to_string()))
    None => ()
  }
  match query.wait {
    Some(seconds) => pairs.push(("wait", seconds.to_string()))
    None => ()
  }
  let body = self.fetch(
    service=Route,
    path=build_query("/v1/magpie/route", pairs),
  )
  let fields = intel_object(body, "route")
  let route = match fields.get("route") {
    Some(Json::Null) | None => None
    Some(Json::Object(route_fields)) => {
      let tries : Array[MagpieRouteTry]? = match route_fields.get("tries") {
        None => None
        Some(Json::Array(rows)) => {
          let typed : Array[MagpieRouteTry] = []
          for row in rows {
            guard row is Json::Object(row_fields) else {
              raise intel_error("route.tries", "wrong_type")
            }
            typed.push({
              model: intel_str(row_fields, "model", "route.tries") catch {
                _ => raise intel_error("route.tries.model", "wrong_type")
              },
              effort: intel_str(row_fields, "effort", "route.tries") catch {
                _ => raise intel_error("route.tries.effort", "wrong_type")
              },
              fail: intel_str(row_fields, "fail", "route.tries") catch {
                _ => raise intel_error("route.tries.fail", "wrong_type")
              },
            })
          }
          Some(typed)
        }
        Some(_) => raise intel_error("route.tries", "wrong_type")
      }
      let rule_pick = match route_fields.get("rule") {
        Some(Json::Object(rule_fields)) =>
          match rule_fields.get("pick") {
            Some(Json::String(pick)) => Some(pick)
            _ => None
          }
        _ => None
      }
      Some({
        asked: intel_str(route_fields, "asked", "route") catch {
          _ => raise intel_error("route.asked", "wrong_type")
        },
        group: intel_str(route_fields, "group", "route") catch {
          _ => raise intel_error("route.group", "wrong_type")
        },
        rule: route_fields.get("rule"),
        rule_pick,
        model: intel_str(route_fields, "model", "route") catch {
          _ => raise intel_error("route.model", "wrong_type")
        },
        effort: intel_str(route_fields, "effort", "route") catch {
          _ => raise intel_error("route.effort", "wrong_type")
        },
        served: intel_str(route_fields, "served", "route") catch {
          _ => raise intel_error("route.served", "wrong_type")
        },
        done: intel_bool(route_fields, "done", "route") catch {
          _ => raise intel_error("route.done", "wrong_type")
        },
        status: route_fields.get("status"),
        tries,
      })
    }
    Some(_) => raise intel_error("route", "wrong_type")
  }
  {
    session: match fields.get("session") {
      Some(Json::String(session)) => session
      _ => query.session
    },
    seq: intel_int(fields, "seq", "route") catch {
      _ => raise intel_error("route.seq", "wrong_type")
    },
    route,
  }
}

///|
/// Decodes one quota card.
fn intel_quota_card(item : Json) -> MagpieQuotaCard raise @posoco.ModelError {
  guard item is Json::Object(fields) else {
    raise intel_error("quotas.card", "not_object")
  }
  let provider = match fields.get("provider") {
    Some(Json::String(provider)) => provider
    _ => raise intel_error("quotas.card.provider", "missing_or_wrong_type")
  }
  let windows : Array[MagpieQuotaWindow]? = match fields.get("windows") {
    None => None
    Some(Json::Array(rows)) => {
      let typed : Array[MagpieQuotaWindow] = []
      for row in rows {
        guard row is Json::Object(window) else {
          raise intel_error("quotas.window", "not_object")
        }
        let name = match window.get("name") {
          Some(Json::String(name)) => name
          _ => raise intel_error("quotas.window.name", "missing_or_wrong_type")
        }
        typed.push({
          name,
          used: intel_double(window, "used", "quotas.window") catch {
            _ => raise intel_error("quotas.window.used", "wrong_type")
          },
          remaining: intel_double(window, "remaining", "quotas.window") catch {
            _ => raise intel_error("quotas.window.remaining", "wrong_type")
          },
          resets_at: intel_str(window, "resetsAt", "quotas.window") catch {
            _ => raise intel_error("quotas.window.resetsAt", "wrong_type")
          },
          reset_secs: intel_int(window, "resetSecs", "quotas.window") catch {
            _ => raise intel_error("quotas.window.resetSecs", "wrong_type")
          },
          display: intel_str(window, "display", "quotas.window") catch {
            _ => raise intel_error("quotas.window.display", "wrong_type")
          },
          amount: intel_double(window, "amount", "quotas.window") catch {
            _ => raise intel_error("quotas.window.amount", "wrong_type")
          },
          limit: intel_double(window, "limit", "quotas.window") catch {
            _ => raise intel_error("quotas.window.limit", "wrong_type")
          },
        })
      }
      Some(typed)
    }
    Some(_) => raise intel_error("quotas.windows", "wrong_type")
  }
  let resets_each : Array[String]? = match fields.get("resets") {
    Some(Json::Object(resets)) =>
      match resets.get("each") {
        Some(Json::Array(each)) => {
          let untils : Array[String] = []
          for entry in each {
            guard entry is Json::Object(entry_fields) else {
              raise intel_error("quotas.resets.each", "not_object")
            }
            match entry_fields.get("until") {
              Some(Json::String(until)) => untils.push(until)
              _ => ()
            }
          }
          Some(untils)
        }
        _ => None
      }
    _ => None
  }
  {
    provider,
    name: intel_str(fields, "name", "quotas.card") catch {
      _ => raise intel_error("quotas.card.name", "wrong_type")
    },
    kind: intel_str(fields, "kind", "quotas.card") catch {
      _ => raise intel_error("quotas.card.kind", "wrong_type")
    },
    plan: intel_str(fields, "plan", "quotas.card") catch {
      _ => raise intel_error("quotas.card.plan", "wrong_type")
    },
    user: intel_str(fields, "user", "quotas.card") catch {
      _ => raise intel_error("quotas.card.user", "wrong_type")
    },
    windows,
    read_at: intel_str(fields, "readAt", "quotas.card") catch {
      _ => raise intel_error("quotas.card.readAt", "wrong_type")
    },
    error: intel_str(fields, "error", "quotas.card") catch {
      _ => raise intel_error("quotas.card.error", "wrong_type")
    },
    until: intel_str(fields, "until", "quotas.card") catch {
      _ => raise intel_error("quotas.card.until", "wrong_type")
    },
    renew: intel_str(fields, "renew", "quotas.card") catch {
      _ => raise intel_error("quotas.card.renew", "wrong_type")
    },
    resets_count: match fields.get("resets") {
      Some(Json::Object(resets)) =>
        intel_int(resets, "count", "quotas.resets") catch {
          _ => raise intel_error("quotas.resets.count", "wrong_type")
        }
      _ => None
    },
    resets_until: match fields.get("resets") {
      Some(Json::Object(resets)) =>
        intel_str(resets, "until", "quotas.resets") catch {
          _ => raise intel_error("quotas.resets.until", "wrong_type")
        }
      _ => None
    },
    resets_each_until: resets_each,
  }
}

///|
fn intel_quota_list(
  body : String,
  stage : String,
) -> Array[MagpieQuotaCard] raise @posoco.ModelError {
  let fields = intel_object(body, stage)
  guard fields.get("data") is Some(Json::Array(items)) else {
    raise intel_error("\{stage}.data", "missing_or_wrong_type")
  }
  let cards : Array[MagpieQuotaCard] = []
  for item in items {
    cards.push(intel_quota_card(item))
  }
  cards
}

///|
/// The quota card list. `kept=1` answers from what the gateway last read,
/// asking no vendor; the snapshot marks it.
pub async fn MagpieGatewayIntelligence::quota_snapshot(
  self : MagpieGatewayIntelligence,
  kept~ : Bool = false,
) -> MagpieQuotaSnapshot raise @posoco.ModelError {
  let path = if kept { "/v1/magpie/quotas?kept=1" } else { "/v1/magpie/quotas" }
  let body = self.fetch(service=Quotas, path~)
  { cards: intel_quota_list(body, "quotas"), kept, }
}

///|
/// Asks the gateway to re-read one vendor's quota card and answers with the
/// refreshed list. Officially rate-limited by the gateway itself (at most
/// once per 30 seconds per card).
pub async fn MagpieGatewayIntelligence::refresh_quota_cards(
  self : MagpieGatewayIntelligence,
) -> MagpieQuotaSnapshot raise @posoco.ModelError {
  let token = match effective_token(self.config) {
    Some(token) => token
    None =>
      raise @posoco.ModelError::RequestBuild(
        "magpie intelligence request build failure (stage=quotas.refresh): remote gateway requires an explicitly configured credential",
      )
  }
  let headers = gateway_headers(token)
  headers["Content-Type"] = "application/json"
  let (code, body) = self.transport.post(
    gateway_url(self.config, "/v1/magpie/quotas/refresh"),
    headers~,
    body="{}",
  ) catch {
    error =>
      raise @posoco.ModelError::Transport(
        "magpie intelligence transport failure (stage=quotas.refresh): \{error.to_string()}",
      )
  }
  if !is_http_success(code) {
    self.record(service=Quotas, state=TemporarilyUnavailable)
    raise @posoco.ModelError::Transport(
      "magpie intelligence failure (stage=quotas.refresh, status=\{code})",
    )
  }
  self.record(service=Quotas, state=Accessible)
  { cards: intel_quota_list(body, "quotas.refresh"), kept: false, }
}

///|
/// The calling gateway key's own limit status.
pub async fn MagpieGatewayIntelligence::key_limit(
  self : MagpieGatewayIntelligence,
) -> MagpieKeyLimit raise @posoco.ModelError {
  let body = self.fetch(service=Limit, path="/v1/magpie/limit")
  let fields = intel_object(body, "limit")
  let limited = intel_bool(fields, "limited", "limit") catch {
    _ => raise intel_error("limit.limited", "wrong_type")
  }
  if limited is None {
    raise intel_error("limit.limited", "missing")
  }
  {
    key: intel_str(fields, "key", "limit") catch {
      _ => raise intel_error("limit.key", "wrong_type")
    },
    limited: limited.unwrap_or(false),
  }
}

///|
/// Decodes the usage summary's numeric core and session rows.
fn intel_usage_summary(
  body : String,
) -> MagpieUsageSummary raise @posoco.ModelError {
  let fields = intel_object(body, "usage")
  let sessions : Array[Json] = match fields.get("sessions") {
    Some(Json::Array(rows)) => rows
    None => []
    Some(_) => raise intel_error("usage.sessions", "wrong_type")
  }
  {
    period: intel_str(fields, "period", "usage") catch {
      _ => raise intel_error("usage.period", "wrong_type")
    },
    since: intel_str(fields, "since", "usage") catch {
      _ => raise intel_error("usage.since", "wrong_type")
    },
    calls: intel_int(fields, "calls", "usage") catch {
      _ => raise intel_error("usage.calls", "wrong_type")
    },
    errors: intel_int(fields, "errors", "usage") catch {
      _ => raise intel_error("usage.errors", "wrong_type")
    },
    input_tokens: intel_int(fields, "input", "usage") catch {
      _ => raise intel_error("usage.input", "wrong_type")
    },
    output_tokens: intel_int(fields, "output", "usage") catch {
      _ => raise intel_error("usage.output", "wrong_type")
    },
    cache_read_tokens: intel_int(fields, "cache_read", "usage") catch {
      _ => raise intel_error("usage.cache_read", "wrong_type")
    },
    cache_write_tokens: intel_int(fields, "cache_write", "usage") catch {
      _ => raise intel_error("usage.cache_write", "wrong_type")
    },
    cache_write_1h_tokens: intel_int(fields, "cache_write_1h", "usage") catch {
      _ => raise intel_error("usage.cache_write_1h", "wrong_type")
    },
    reasoning_tokens: intel_int(fields, "reasoning", "usage") catch {
      _ => raise intel_error("usage.reasoning", "wrong_type")
    },
    cost: intel_double(fields, "cost", "usage") catch {
      _ => raise intel_error("usage.cost", "wrong_type")
    },
    unpriced: intel_int(fields, "unpriced", "usage") catch {
      _ => raise intel_error("usage.unpriced", "wrong_type")
    },
    session_count: intel_int(fields, "sessionCount", "usage") catch {
      _ => raise intel_error("usage.sessionCount", "wrong_type")
    },
    sessions,
  }
}

///|
/// The usage summary for a period.
pub async fn MagpieGatewayIntelligence::usage_summary(
  self : MagpieGatewayIntelligence,
  period~ : MagpieUsagePeriod = Today,
) -> MagpieUsageSummary raise @posoco.ModelError {
  let body = self.fetch(
    service=Usage,
    path=build_query("/v1/magpie/usage", [("period", period.to_string())]),
  )
  intel_usage_summary(body)
}

///|
/// Decodes one request-history row.
fn intel_usage_row(
  item : Json,
) -> MagpieUsageRequestRow raise @posoco.ModelError {
  guard item is Json::Object(fields) else {
    raise intel_error("usage.requests.row", "not_object")
  }
  {
    t: intel_str(fields, "t", "usage.requests") catch {
      _ => raise intel_error("usage.requests.t", "wrong_type")
    },
    agent: intel_str(fields, "agent", "usage.requests") catch {
      _ => raise intel_error("usage.requests.agent", "wrong_type")
    },
    provider: intel_str(fields, "provider", "usage.requests") catch {
      _ => raise intel_error("usage.requests.provider", "wrong_type")
    },
    model: intel_str(fields, "model", "usage.requests") catch {
      _ => raise intel_error("usage.requests.model", "wrong_type")
    },
    served: intel_str(fields, "served", "usage.requests") catch {
      _ => raise intel_error("usage.requests.served", "wrong_type")
    },
    session: intel_str(fields, "session", "usage.requests") catch {
      _ => raise intel_error("usage.requests.session", "wrong_type")
    },
    input_tokens: intel_int(fields, "in", "usage.requests") catch {
      _ => raise intel_error("usage.requests.in", "wrong_type")
    },
    output_tokens: intel_int(fields, "out", "usage.requests") catch {
      _ => raise intel_error("usage.requests.out", "wrong_type")
    },
    cache_read_tokens: intel_int(fields, "cache_read", "usage.requests") catch {
      _ => raise intel_error("usage.requests.cache_read", "wrong_type")
    },
    cache_write_tokens: intel_int(fields, "cache_write", "usage.requests") catch {
      _ => raise intel_error("usage.requests.cache_write", "wrong_type")
    },
    cache_write_1h_tokens: intel_int(fields, "cache_write_1h", "usage.requests") catch {
      _ => raise intel_error("usage.requests.cache_write_1h", "wrong_type")
    },
    reasoning_tokens: intel_int(fields, "reasoning", "usage.requests") catch {
      _ => raise intel_error("usage.requests.reasoning", "wrong_type")
    },
    cost: intel_double(fields, "cost", "usage.requests") catch {
      _ => raise intel_error("usage.requests.cost", "wrong_type")
    },
    priced: intel_bool(fields, "priced", "usage.requests") catch {
      _ => raise intel_error("usage.requests.priced", "wrong_type")
    },
    status: intel_int(fields, "status", "usage.requests") catch {
      _ => raise intel_error("usage.requests.status", "wrong_type")
    },
    duration_ms: intel_int(fields, "ms", "usage.requests") catch {
      _ => raise intel_error("usage.requests.ms", "wrong_type")
    },
  }
}

///|
/// One page of request history. `limit` follows the gateway's own ceiling
/// (500); `offset` pages forward from 0.
pub async fn MagpieGatewayIntelligence::usage_requests(
  self : MagpieGatewayIntelligence,
  offset~ : Int32 = 0,
  limit~ : Int32 = 100,
  period~ : MagpieUsagePeriod? = Some(Today),
) -> MagpieUsageRequestsPage raise @posoco.ModelError {
  if limit < 1 || limit > 500 || offset < 0 {
    raise @posoco.ModelError::RequestBuild(
      "magpie intelligence request build failure (stage=usage.requests): limit is limited to 500",
    )
  }
  let pairs : Array[(String, String)] = [
    ("offset", offset.to_string()),
    ("limit", limit.to_string()),
  ]
  match period {
    Some(period) => pairs.push(("period", period.to_string()))
    None => ()
  }
  let body = self.fetch(
    service=UsageRequests,
    path=build_query("/v1/magpie/usage/requests", pairs),
  )
  let fields = intel_object(body, "usage.requests")
  let rows : Array[MagpieUsageRequestRow] = match fields.get("rows") {
    Some(Json::Array(items)) => {
      let typed : Array[MagpieUsageRequestRow] = []
      for item in items {
        typed.push(intel_usage_row(item))
      }
      typed
    }
    None => []
    Some(_) => raise intel_error("usage.requests.rows", "wrong_type")
  }
  {
    rows,
    offset: intel_int(fields, "offset", "usage.requests") catch {
      _ => raise intel_error("usage.requests.offset", "wrong_type")
    },
    total: intel_int(fields, "total", "usage.requests") catch {
      _ => raise intel_error("usage.requests.total", "wrong_type")
    },
  }
}

///|
/// What is in flight right now.
pub async fn MagpieGatewayIntelligence::concurrency_snapshot(
  self : MagpieGatewayIntelligence,
) -> MagpieConcurrencySnapshot raise @posoco.ModelError {
  let body = self.fetch(service=Concurrency, path="/v1/magpie/concurrency")
  let fields = intel_object(body, "concurrency")
  let requests : Array[Json] = match fields.get("requests") {
    Some(Json::Array(rows)) => rows
    None => []
    Some(_) => raise intel_error("concurrency.requests", "wrong_type")
  }
  let data : Array[(String, Int32)] = match fields.get("data") {
    Some(Json::Object(map)) => {
      let pairs : Array[(String, Int32)] = []
      for key, value in map {
        match value {
          Json::Number(count, ..) => pairs.push((key, count.to_int()))
          _ => ()
        }
      }
      pairs.sort_by(fn(a, b) { a.0.compare(b.0) })
      pairs
    }
    None => []
    Some(_) => raise intel_error("concurrency.data", "wrong_type")
  }
  {
    requests,
    waiting: intel_int(fields, "waiting", "concurrency") catch {
      _ => raise intel_error("concurrency.waiting", "wrong_type")
    },
    tools: intel_int(fields, "tools", "concurrency") catch {
      _ => raise intel_error("concurrency.tools", "wrong_type")
    },
    data,
  }
}

///|
/// Protocol-local cache economics through the messages kit: the caller
/// supplies the rate card, the row supplies the native numbers, and the
/// kit computes the economics. `None` when the row reports no cache
/// activity at all.
pub fn MagpieUsageRequestRow::cache_economics(
  self : MagpieUsageRequestRow,
  rates~ : @messages.MessagesCacheRates,
) -> @messages.MessagesCacheEconomics? raise @posoco.ModelError {
  guard self.cache_read_tokens is Some(_) || self.cache_write_tokens is Some(_) else {
    return None
  }
  // Magpie's cache_write is the total number of created cache tokens.
  // cache_write_1h is the 1h subset, not additional tokens. Without a
  // 1h breakdown, the TTL distribution is unknown and no exact write
  // pricing may be inferred from the aggregate.
  let creation : @messages.MessagesCacheCreation = match (
    self.cache_write_tokens,
    self.cache_write_1h_tokens,
  ) {
    (Some(total), Some(hour)) if hour >= 0 && total >= hour =>
      {
        ephemeral_5m_input_tokens: Some(total - hour),
        ephemeral_1h_input_tokens: Some(hour),
      }
    (Some(_), Some(_)) =>
      raise @posoco.ModelError::ResponseParse(
        "magpie cache accounting invalid (stage=economics, category=one_hour_exceeds_total)",
      )
    _ => {
      ephemeral_5m_input_tokens: None,
      ephemeral_1h_input_tokens: None,
    }
  }
  let usage = @messages.MessagesUsage::{
    input_tokens: self.input_tokens.unwrap_or(0),
    output_tokens: self.output_tokens.unwrap_or(0),
    cache_read_input_tokens: self.cache_read_tokens,
    cache_creation_input_tokens: self.cache_write_tokens,
  }
  Some(@messages.analyze_messages_cache_economics(usage, creation, rates))
}
