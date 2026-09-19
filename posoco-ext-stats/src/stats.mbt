///|
/// Speed and prompt-cache metrics derived purely from core turn events:
/// `ttft` (round start → first streamed token), `tps` (output tokens over the
/// span of the round that just committed), `avg` (the running per-round mean
/// of `tps`), and `cache` (the process aggregate of per-session prompt-cache
/// accounting). Everything publishes through the devkit status protocol
/// (segments `ttft`/`tps`/`avg`/`cache`, priorities 50/60/70/80, source
/// `posoco_ext_stats`); with `bus = None` the observer still maintains its
/// state and publishes nowhere.
///
/// A "round" is one model response: `ModelResponseReceived` closes the round
/// (computing metrics, then re-anchoring at the current time) so a tool loop
/// measures one round per response without a fresh `TurnStarted`. Each round
/// with usage also accumulates into a per-session bucket (keyed by the
/// dispatched `EventScope` session id, falling back to a `"(no scope)"`
/// process bucket). Cache reporting is tracked separately from generic usage:
/// `cached_input_tokens=None` means unknown, while `Some(0)` is an explicit
/// zero-hit report. The clock is injectable for deterministic tests.
pub struct Stats {
  bus : @devkit.EventBus?
  clock : () -> Int64
  mut round_started_ms : Int64?
  mut first_token_ms : Int64?
  mut sum_tps : Double
  mut tps_rounds : Int
  cache_buckets : Map[String, CacheBucket]
}

///|
/// One session's prompt-cache accounting. `requests` counts usage-bearing
/// model responses. `cache_reported_requests` is the subset whose provider
/// explicitly supplied `cached_input_tokens`; this separation prevents
/// unknown cache telemetry from being treated as zero hits.
pub struct CacheBucket {
  /// Rounds whose `ModelResponseReceived` carried a `Usage`.
  mut requests : Int
  /// Rounds whose usage explicitly reported `cached_input_tokens` (including 0).
  mut cache_reported_requests : Int
  /// Rounds whose usage reported `cached_input_tokens > 0`.
  mut hit_requests : Int
  /// Sum of all reported `input_tokens` (usage accounting).
  mut sum_input : Int
  /// Sum of reported input tokens only on cache-reporting rounds.
  mut sum_cache_input : Int
  /// Sum of reported `output_tokens`.
  mut sum_output : Int
  /// Sum of reported `cached_input_tokens`.
  mut sum_cached : Int
}

///|
pub fn Stats::Stats(
  bus? : @devkit.EventBus? = None,
  clock? : () -> Int64 = fn() { @async.now() },
) -> Stats {
  {
    bus,
    clock,
    round_started_ms: None,
    first_token_ms: None,
    sum_tps: 0.0,
    tps_rounds: 0,
    cache_buckets: Map::from_array([]),
  }
}

///|
pub impl @posoco.Observer for Stats with fn on_event_at(
  self : Stats,
  scope : @posoco.EventScope?,
  event : @posoco.TurnEvent,
) -> Unit {
  match event {
    TurnStarted => {
      self.round_started_ms = Some((self.clock)())
      self.first_token_ms = None
    }
    StreamChunkReceived(chunk~) =>
      match chunk {
        TextDelta(_) | ReasoningDelta(_) => self.note_first_token()
        _ => ()
      }
    ModelResponseReceived(usage~, ..) => {
      match usage {
        Some(u) => self.note_cache_usage(scope_key(scope), u)
        None => ()
      }
      self.close_round(usage)
    }
    _ => ()
  }
}

///|
pub impl @posoco.Observer for Stats with fn on_event(
  self : Stats,
  event : @posoco.TurnEvent,
) -> Unit {
  self.on_event_at(None, event)
}

///|
fn scope_key(scope : @posoco.EventScope?) -> String {
  match scope {
    Some(s) => s.session_id.to_string()
    None => "(no scope)"
  }
}

///|
fn Stats::note_cache_usage(
  self : Stats,
  key : String,
  usage : @posoco.Usage,
) -> Unit {
  let bucket = self.cache_bucket(key)
  bucket.requests += 1
  match usage.cached_input_tokens {
    Some(n) => {
      bucket.cache_reported_requests += 1
      if n > 0 {
        bucket.hit_requests += 1
      }
      bucket.sum_cached += n
      match usage.input_tokens {
        Some(input) => bucket.sum_cache_input += input
        None => ()
      }
    }
    None => ()
  }
  match usage.input_tokens {
    Some(n) => bucket.sum_input += n
    None => ()
  }
  match usage.output_tokens {
    Some(n) => bucket.sum_output += n
    None => ()
  }
}

///|
fn Stats::cache_bucket(self : Stats, key : String) -> CacheBucket {
  match self.cache_buckets.get(key) {
    Some(bucket) => bucket
    None => {
      let bucket : CacheBucket = {
        requests: 0,
        cache_reported_requests: 0,
        hit_requests: 0,
        sum_input: 0,
        sum_cache_input: 0,
        sum_output: 0,
        sum_cached: 0,
      }
      self.cache_buckets[key] = bucket
      bucket
    }
  }
}

///|
priv struct CacheTotals {
  requests : Int
  cache_reported_requests : Int
  hit_requests : Int
  sum_input : Int
  sum_cache_input : Int
  sum_output : Int
  sum_cached : Int
}

///|
fn Stats::cache_totals(self : Stats) -> CacheTotals {
  let mut requests = 0
  let mut cache_reported_requests = 0
  let mut hit_requests = 0
  let mut sum_input = 0
  let mut sum_cache_input = 0
  let mut sum_output = 0
  let mut sum_cached = 0
  for _key, bucket in self.cache_buckets {
    requests += bucket.requests
    cache_reported_requests += bucket.cache_reported_requests
    hit_requests += bucket.hit_requests
    sum_input += bucket.sum_input
    sum_cache_input += bucket.sum_cache_input
    sum_output += bucket.sum_output
    sum_cached += bucket.sum_cached
  }
  {
    requests,
    cache_reported_requests,
    hit_requests,
    sum_input,
    sum_cache_input,
    sum_output,
    sum_cached,
  }
}

///|
/// Callers must ensure the denominator is > 0.
fn hit_rate_percent(sum_cached : Int, sum_input : Int) -> Double {
  sum_cached.to_double() * 100.0 / sum_input.to_double()
}

///|
fn Stats::note_first_token(self : Stats) -> Unit {
  if self.round_started_ms is Some(_) && self.first_token_ms is None {
    self.first_token_ms = Some((self.clock)())
  }
}

///|
fn cache_status_value(totals : CacheTotals) -> String {
  if totals.cache_reported_requests == 0 {
    return "n/a"
  }
  if totals.sum_cache_input > 0 {
    return "\{totals.hit_requests}/\{totals.cache_reported_requests}·\{fmt_one_decimal(hit_rate_percent(totals.sum_cached, totals.sum_cache_input))}%"
  }
  "\{totals.hit_requests}/\{totals.cache_reported_requests}·n/a"
}

///|
fn Stats::close_round(self : Stats, usage : @posoco.Usage?) -> Unit {
  let now = (self.clock)()
  let ttft_ms : Int64? = match (self.round_started_ms, self.first_token_ms) {
    (Some(started), Some(first)) => Some(first - started)
    _ => None
  }
  let span_ms : Int64? = match self.round_started_ms {
    Some(started) => {
      let span = now - started
      if span >= 0 && span <= 2147483647 {
        Some(span)
      } else {
        None
      }
    }
    None => None
  }
  let tps : Double? = match (usage, span_ms) {
    (Some(usage), Some(span)) if span > 0 =>
      match usage.output_tokens {
        Some(out) => Some(out.to_double() * 1000.0 / span.to_double())
        None => None
      }
    _ => None
  }
  match tps {
    Some(rate) => {
      self.sum_tps += rate
      self.tps_rounds += 1
    }
    None => ()
  }
  self.round_started_ms = Some(now)
  self.first_token_ms = None
  match self.bus {
    Some(bus) => {
      match ttft_ms {
        Some(ms) =>
          @devkit.publish_status_register(
            bus,
            source="posoco_ext_stats",
            segment="ttft",
            priority=50,
            value="\{ms}ms",
          )
        None => ()
      }
      match tps {
        Some(rate) =>
          @devkit.publish_status_register(
            bus,
            source="posoco_ext_stats",
            segment="tps",
            priority=60,
            value="\{fmt_one_decimal(rate)}/s",
          )
        None => ()
      }
      if self.tps_rounds > 0 {
        @devkit.publish_status_register(
          bus,
          source="posoco_ext_stats",
          segment="avg",
          priority=70,
          value="\{fmt_one_decimal(self.sum_tps / self.tps_rounds.to_double())}/s",
        )
      }
      // Update the cache segment only when this response carried usage. The
      // compact value uses cache-reporting rounds exclusively; a provider
      // that omits `cached_input_tokens` is displayed as n/a, not as a miss.
      match usage {
        Some(_) => {
          let totals = self.cache_totals()
          @devkit.publish_status_register(
            bus,
            source="posoco_ext_stats",
            segment="cache",
            priority=80,
            value=cache_status_value(totals),
          )
        }
        None => ()
      }
    }
    None => ()
  }
}

///|
fn fmt_one_decimal(value : Double) -> String {
  let scaled = (value * 10.0 + 0.5).to_int()
  "\{scaled / 10}.\{scaled % 10}"
}

///|
/// Compact honest token count: raw below 1K, one-decimal K/M above.
fn fmt_tokens(n : Int) -> String {
  if n >= 1000000 {
    "\{fmt_one_decimal(n.to_double() / 1000000.0)}M"
  } else if n >= 1000 {
    "\{fmt_one_decimal(n.to_double() / 1000.0)}K"
  } else {
    "\{n}"
  }
}

///|
pub impl @posoco.Extension for Stats with fn extension_id(_self : Stats) -> String {
  "posoco_ext_stats"
}

///|
pub impl @posoco.Extension for Stats with fn manifest(self : Stats) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(
    id="posoco_ext_stats",
    observers=[self],
    commands=[self],
  )
}

///|
pub impl @posoco.CommandPort for Stats with fn commands(_self : Stats) -> Array[
  @posoco.CommandDef,
] {
  [
    @posoco.CommandDef::{
      id: "cache_doctor",
      label: "Cache doctor",
      description: "Per-session prompt-cache hit rates with a read-only channel diagnosis",
      category: "stats",
      ctype: @posoco.CommandType::Action,
      params: [],
      aliases: [],
      shortcut: None,
      icon: None,
      visible: true,
      metadata: None,
    },
    @posoco.CommandDef::{
      id: "usage",
      label: "Token usage",
      description: "Cumulative token accounting: input, output, requests, reported cache hits",
      category: "stats",
      ctype: @posoco.CommandType::Action,
      params: [],
      aliases: [],
      shortcut: None,
      icon: None,
      visible: true,
      metadata: None,
    },
  ]
}

///|
/// One doctor report line. Request and token denominators cover only rounds
/// where the provider explicitly reported cache telemetry; usage-only rounds
/// stay visible as `requests` but never masquerade as misses.
fn doctor_line(
  label : String,
  hit_requests : Int,
  cache_reported_requests : Int,
  requests : Int,
  sum_cached : Int,
  sum_cache_input : Int,
) -> String {
  if cache_reported_requests == 0 {
    return "\{label}: cache metrics not reported·\{requests} usage requests"
  }
  let head = "\{label}: \{hit_requests}/\{cache_reported_requests} requests·"
  if sum_cache_input > 0 {
    "\{head}\{fmt_tokens(sum_cached)}/\{fmt_tokens(sum_cache_input)} tok·\{fmt_one_decimal(hit_rate_percent(sum_cached, sum_cache_input))}%"
  } else {
    "\{head}no token totals"
  }
}

///|
fn bucket_json(key : String, bucket : CacheBucket) -> Json {
  Json::object(
    Map::from_array([
      ("session", Json::string(key)),
      ("requests", Json::number(bucket.requests.to_double())),
      (
        "cache_reported_requests",
        Json::number(bucket.cache_reported_requests.to_double()),
      ),
      ("hit_requests", Json::number(bucket.hit_requests.to_double())),
      ("sum_input_tokens", Json::number(bucket.sum_input.to_double())),
      (
        "sum_cache_input_tokens",
        Json::number(bucket.sum_cache_input.to_double()),
      ),
      ("sum_output_tokens", Json::number(bucket.sum_output.to_double())),
      ("sum_cached_tokens", Json::number(bucket.sum_cached.to_double())),
    ]),
  )
}

///|
/// A busy *reporting* channel (>= 5 explicit cache reports) with an
/// essentially zero token hit rate suggests that caching is ineffective.
/// Usage rounds that omit cache telemetry can never trigger this warning.
fn cache_channel_suspicious(totals : CacheTotals) -> Bool {
  totals.cache_reported_requests >= 5 &&
  totals.sum_cache_input > 0 &&
  hit_rate_percent(totals.sum_cached, totals.sum_cache_input) < 5.0
}

///|
pub impl @posoco.CommandPort for Stats with fn invoke(
  self : Stats,
  id : String,
  _args : Json,
) -> @posoco.CommandOutcome raise @posoco.CommandError {
  match id {
    "cache_doctor" => self.cache_doctor_report()
    "usage" => self.usage_report()
    _ => raise @posoco.CommandError::NotFound(id)
  }
}

///|
fn Stats::sorted_bucket_keys(self : Stats) -> Array[String] {
  let keys : Array[String] = []
  for key, _bucket in self.cache_buckets {
    keys.push(key)
  }
  keys.sort()
  keys
}

///|
fn Stats::cache_doctor_report(self : Stats) -> @posoco.CommandOutcome {
  let totals = self.cache_totals()
  let lines : Array[String] = []
  let sessions : Array[Json] = []
  for key in self.sorted_bucket_keys() {
    match self.cache_buckets.get(key) {
      Some(bucket) => {
        sessions.push(bucket_json(key, bucket))
        lines.push(
          doctor_line(
            "session \{key}",
            bucket.hit_requests,
            bucket.cache_reported_requests,
            bucket.requests,
            bucket.sum_cached,
            bucket.sum_cache_input,
          ),
        )
      }
      None => ()
    }
  }
  lines.push(
    doctor_line(
      "aggregate",
      totals.hit_requests,
      totals.cache_reported_requests,
      totals.requests,
      totals.sum_cached,
      totals.sum_cache_input,
    ),
  )
  // Warn only from explicit cache telemetry. Absence of telemetry is a
  // capability/observability fact, not evidence of a zero-hit channel.
  let diagnosis : String? = if cache_channel_suspicious(totals) {
    Some(
      "warning: the channel reports almost no prompt-cache hits — it may not support prompt caching, or an OpenAI-compatible proxy may split session affinity across upstreams; check the provider/proxy configuration",
    )
  } else {
    None
  }
  match diagnosis {
    Some(warning) => lines.push(warning)
    None => ()
  }
  let structured : Array[(String, Json)] = [
    ("kind", Json::string("stats_cache_doctor")),
    ("sessions", Json::array(sessions)),
    (
      "aggregate",
      Json::object(
        Map::from_array([
          ("requests", Json::number(totals.requests.to_double())),
          (
            "cache_reported_requests",
            Json::number(totals.cache_reported_requests.to_double()),
          ),
          ("hit_requests", Json::number(totals.hit_requests.to_double())),
          ("sum_input_tokens", Json::number(totals.sum_input.to_double())),
          (
            "sum_cache_input_tokens",
            Json::number(totals.sum_cache_input.to_double()),
          ),
          ("sum_cached_tokens", Json::number(totals.sum_cached.to_double())),
        ]),
      ),
    ),
  ]
  match diagnosis {
    Some(warning) => structured.push(("diagnosis", Json::string(warning)))
    None => ()
  }
  @posoco.CommandOutcome::Success(
    feedback=lines.join("\n"),
    structured=Some(Json::object(Map::from_array(structured))),
    ui_hint=Some(@posoco.UiHint::None),
  )
}

///|
/// One usage report line: cumulative accounting with explicit labels. Generic
/// request/input/output totals cover every usage-bearing round; cache hit and
/// token rates cover only rounds that explicitly reported cache telemetry.
fn usage_line(
  label : String,
  requests : Int,
  sum_input : Int,
  sum_output : Int,
  cache_reported_requests : Int,
  hit_requests : Int,
  sum_cached : Int,
  sum_cache_input : Int,
) -> String {
  let head = "\{label}: \{requests} requests · in \{fmt_tokens(sum_input)} · out \{fmt_tokens(sum_output)}"
  if cache_reported_requests == 0 {
    return "\{head} · cache n/a"
  }
  let cache = "\{head} · cache hits \{hit_requests}/\{cache_reported_requests}"
  if sum_cache_input > 0 {
    "\{cache} (\{fmt_one_decimal(hit_rate_percent(sum_cached, sum_cache_input))}%)"
  } else {
    cache
  }
}

///|
fn Stats::usage_report(self : Stats) -> @posoco.CommandOutcome {
  let totals = self.cache_totals()
  let lines : Array[String] = []
  let sessions : Array[Json] = []
  for key in self.sorted_bucket_keys() {
    match self.cache_buckets.get(key) {
      Some(bucket) => {
        sessions.push(bucket_json(key, bucket))
        lines.push(
          usage_line(
            "session \{key}",
            bucket.requests,
            bucket.sum_input,
            bucket.sum_output,
            bucket.cache_reported_requests,
            bucket.hit_requests,
            bucket.sum_cached,
            bucket.sum_cache_input,
          ),
        )
      }
      None => ()
    }
  }
  lines.push(
    usage_line(
      "aggregate",
      totals.requests,
      totals.sum_input,
      totals.sum_output,
      totals.cache_reported_requests,
      totals.hit_requests,
      totals.sum_cached,
      totals.sum_cache_input,
    ),
  )
  let structured : Array[(String, Json)] = [
    ("kind", Json::string("stats_usage")),
    ("sessions", Json::array(sessions)),
    (
      "aggregate",
      Json::object(
        Map::from_array([
          ("requests", Json::number(totals.requests.to_double())),
          (
            "cache_reported_requests",
            Json::number(totals.cache_reported_requests.to_double()),
          ),
          ("sum_input_tokens", Json::number(totals.sum_input.to_double())),
          (
            "sum_cache_input_tokens",
            Json::number(totals.sum_cache_input.to_double()),
          ),
          ("sum_output_tokens", Json::number(totals.sum_output.to_double())),
          ("hit_requests", Json::number(totals.hit_requests.to_double())),
          ("sum_cached_tokens", Json::number(totals.sum_cached.to_double())),
        ]),
      ),
    ),
  ]
  @posoco.CommandOutcome::Success(
    feedback=lines.join("\n"),
    structured=Some(Json::object(Map::from_array(structured))),
    ui_hint=Some(@posoco.UiHint::None),
  )
}

///|
pub extend Stats with @posoco.Extension::{extension_id, manifest}

///|
pub extend Stats with @posoco.Observer::{on_event, on_event_at}

///|
pub extend Stats with @posoco.CommandPort::{commands, invoke}
