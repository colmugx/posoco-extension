///|
/// intel_types.mbt — typed snapshots of Magpie's control and observability
/// endpoints.
///
/// Field sets follow the documented gateway behavior and the observed
/// responses; optional fields distinguish unknown from explicitly declared
/// values. Nothing here is inferred from model identifiers, and nothing
/// carries credentials. Account attribution (user emails on quota cards)
/// appears only because the gateway reports it to an authorized caller.

///|
/// The observability services this client can query.
pub(all) enum MagpieService {
  Route
  Quotas
  Limit
  Usage
  UsageRequests
  Concurrency
} derive(Eq, Debug)

///|
pub extend MagpieService with Eq::{not_equal, equal}

///|
pub extend MagpieService with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub impl Show for MagpieService with fn to_string(self : MagpieService) -> String {
  match self {
    Route => "route"
    Quotas => "quotas"
    Limit => "limit"
    Usage => "usage"
    UsageRequests => "usage/requests"
    Concurrency => "concurrency"
  }
}

///|
pub extend MagpieService with Show::{to_string, output}

///|
/// Gateway service availability, independent from the inference connection:
/// one unavailable monitoring endpoint never invalidates working model
/// execution.
pub(all) enum MagpieServiceAvailability {
  /// Supported and accessible.
  Accessible
  /// Supported but forbidden for this credential (401/403, e.g. a held
  /// gateway key).
  Forbidden
  /// Temporarily unavailable (429, 5xx, unreachable gateway).
  TemporarilyUnavailable
  /// Not supported by this gateway version (404).
  NotSupported
  /// Never probed.
  Unknown
} derive(Eq, Debug)

///|
pub extend MagpieServiceAvailability with Eq::{not_equal, equal}

///|
pub extend MagpieServiceAvailability with @moonbitlang/core/debug.Debug::{
  to_repr,
}

///|
pub impl Show for MagpieServiceAvailability with fn to_string(
  self : MagpieServiceAvailability,
) -> String {
  match self {
    Accessible => "Accessible"
    Forbidden => "Forbidden"
    TemporarilyUnavailable => "TemporarilyUnavailable"
    NotSupported => "NotSupported"
    Unknown => "Unknown"
  }
}

///|
pub extend MagpieServiceAvailability with Show::{to_string, output}

///|
/// The session's latest routing state (`GET /v1/magpie/route`). `route` is
/// `None` before the session has one; the gateway's own fields are carried
/// verbatim — asked, group, rule, the member being tried, the tries with
/// their fallback reasons, and the post-reply done/status/served facts.
pub(all) struct MagpieRouteSnapshot {
  session : String
  seq : Int32?
  route : MagpieRouteDecision?
} derive(Eq, Debug)

///|
pub extend MagpieRouteSnapshot with Eq::{not_equal, equal}

///|
pub extend MagpieRouteSnapshot with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub(all) struct MagpieRouteDecision {
  /// The model the agent named, verbatim.
  asked : String?
  /// The routing group that matched, when one did.
  group : String?
  /// The group rule that matched; its shape is the gateway's.
  rule : Json?
  /// The effort the rule's decision model picked.
  rule_pick : String?
  /// The upstream member being tried, as `provider/model`.
  model : String?
  /// The reasoning effort the member was sent at.
  effort : String?
  /// The upstream that actually served the reply, once done.
  served : String?
  done : Bool?
  status : Json?
  /// One entry per member tried; a failed try carries its fallback reason.
  tries : Array[MagpieRouteTry]?
} derive(Eq, Debug)

///|
pub extend MagpieRouteDecision with Eq::{not_equal, equal}

///|
pub extend MagpieRouteDecision with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub(all) struct MagpieRouteTry {
  model : String?
  effort : String?
  /// Why this member was fallen back from, when it failed.
  fail : String?
} derive(Eq, Debug)

///|
pub extend MagpieRouteTry with Eq::{not_equal, equal}

///|
pub extend MagpieRouteTry with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// One subscription/plan/key quota card.
pub(all) struct MagpieQuotaCard {
  provider : String
  name : String?
  kind : String?
  plan : String?
  /// Account attribution, as reported to the authorized caller.
  user : String?
  /// User-defined alias; unlike an email it is safe to use as a compact label.
  account_alias : String?
  /// Gateway-wide last service, NOT attribution to the current session.
  last_served_at : String?
  last : Bool?
  /// Cached observations and deferrals must not be treated as live guarantees.
  read_deferred : Bool?
  from : String?
  balance : String?
  windows : Array[MagpieQuotaWindow]?
  read_at : String?
  /// The card's own read error, when the vendor refused.
  error : String?
  until : String?
  renew : String?
  resets_count : Int32?
  resets_until : String?
  resets_each_until : Array[String]?
} derive(Eq, Debug)

///|
pub extend MagpieQuotaCard with Eq::{not_equal, equal}

///|
pub extend MagpieQuotaCard with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// One usage window: percentage-shaped (`used`/`remaining`) or
/// amount-shaped (`amount`/`limit`), with the gateway's own display string
/// when it has one.
pub(all) struct MagpieQuotaWindow {
  name : String
  used : Double?
  remaining : Double?
  resets_at : String?
  reset_secs : Int32?
  /// A vendor's pool may be shared across models or accounts.
  pool : String?
  unlimited : Bool?
  display : String?
  amount : Double?
  limit : Double?
} derive(Eq, Debug)

///|
pub extend MagpieQuotaWindow with Eq::{not_equal, equal}

///|
pub extend MagpieQuotaWindow with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The quota card list (`GET /v1/magpie/quotas`, `?kept=1` answers from what
/// the gateway last read without asking any vendor).
pub(all) struct MagpieQuotaSnapshot {
  cards : Array[MagpieQuotaCard]
  /// True when the answer came from the gateway's kept cache (`kept=1`).
  kept : Bool
} derive(Eq, Debug)

///|
pub extend MagpieQuotaSnapshot with Eq::{not_equal, equal}

///|
pub extend MagpieQuotaSnapshot with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The calling gateway key's own limit status
/// (`GET /v1/magpie/limit`); a key is told its own and no other's.
pub(all) struct MagpieKeyLimit {
  key : String?
  limited : Bool
} derive(Eq, Debug)

///|
pub extend MagpieKeyLimit with Eq::{not_equal, equal}

///|
pub extend MagpieKeyLimit with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Usage period selector (`GET /v1/magpie/usage?period=…`).
pub(all) enum MagpieUsagePeriod {
  Today
  Week
  Month
  All
} derive(Eq, Debug)

///|
pub extend MagpieUsagePeriod with Eq::{not_equal, equal}

///|
pub extend MagpieUsagePeriod with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub impl Show for MagpieUsagePeriod with fn to_string(self : MagpieUsagePeriod) -> String {
  match self {
    Today => "today"
    Week => "week"
    Month => "month"
    All => "all"
  }
}

///|
pub extend MagpieUsagePeriod with Show::{to_string, output}

///|
/// The usage summary: window totals, the gateway's own series, and the
/// per-session rows it reports. Dimensions the gateway does not return stay
/// `None`/empty — never fabricated.
pub(all) struct MagpieUsageSummary {
  period : String?
  since : String?
  calls : Int32?
  errors : Int32?
  input_tokens : Int32?
  output_tokens : Int32?
  cache_read_tokens : Int32?
  cache_write_tokens : Int32?
  /// The portion of cache writes retained for one hour, when reported.
  cache_write_1h_tokens : Int32?
  reasoning_tokens : Int32?
  /// The gateway's actual reported cost (USD). Authoritative when present.
  cost : Double?
  /// Calls the gateway could not price.
  unpriced : Int32?
  session_count : Int32?
  /// Per-session rows exactly as the gateway reports them.
  sessions : Array[Json]
} derive(Eq, Debug)

///|
pub extend MagpieUsageSummary with Eq::{not_equal, equal}

///|
pub extend MagpieUsageSummary with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// One request-history row: the usage facts the gateway logged for a single
/// call. Presentation-only fields are not carried.
pub(all) struct MagpieUsageRequestRow {
  t : String?
  agent : String?
  provider : String?
  model : String?
  /// The upstream that actually served, when the gateway names it.
  served : String?
  session : String?
  input_tokens : Int32?
  output_tokens : Int32?
  cache_read_tokens : Int32?
  cache_write_tokens : Int32?
  /// The 1h portion of writes; total writes minus this value are 5m writes.
  cache_write_1h_tokens : Int32?
  reasoning_tokens : Int32?
  /// The gateway's actual billed cost (USD), authoritative when present.
  cost : Double?
  priced : Bool?
  status : Int32?
  duration_ms : Int32?
} derive(Eq, Debug)

///|
pub extend MagpieUsageRequestRow with Eq::{not_equal, equal}

///|
pub extend MagpieUsageRequestRow with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// One page of request history (`GET /v1/magpie/usage/requests`).
pub(all) struct MagpieUsageRequestsPage {
  rows : Array[MagpieUsageRequestRow]
  offset : Int32?
  total : Int32?
} derive(Eq, Debug)

///|
pub extend MagpieUsageRequestsPage with Eq::{not_equal, equal}

///|
pub extend MagpieUsageRequestsPage with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// What is in flight right now (`GET /v1/magpie/concurrency`). The in-flight
/// request rows are the gateway's own records, retained verbatim — their
/// shape is not documented, so nothing is projected away and nothing is
/// invented.
pub(all) struct MagpieConcurrencySnapshot {
  requests : Array[Json]
  waiting : Int32?
  /// Claude-Code-style turns waiting on their caller's tool results.
  tools : Int32?
  /// Per limited key/account in-flight counts.
  data : Array[(String, Int32)]
} derive(Eq, Debug)

///|
pub extend MagpieConcurrencySnapshot with Eq::{not_equal, equal}

///|
pub extend MagpieConcurrencySnapshot with @moonbitlang/core/debug.Debug::{
  to_repr,
}
