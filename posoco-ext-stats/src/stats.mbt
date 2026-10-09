///|
/// Speed and prompt-cache metrics derived purely from core turn events:
/// `ttft` (round start → first streamed token, published the moment the
/// first token arrives), `tps` (output tokens over the decode span — last
/// delta chunk minus first delta chunk — so prefill, tool gaps, and the
/// commit tail stay out of the denominator), `avg` (the running per-round
/// mean of settled `tps`), and `cache` (the process aggregate of
/// per-session prompt-cache accounting). During streaming the `tps` segment
/// shows a live estimate (streamed chars over the calibrated chars-per-token
/// ratio, prefixed `≈`), replaced by the exact rate when the round settles;
/// a mid-stream `Usage` chunk makes the live rate exact early. Everything
/// publishes through the devkit status protocol (segments `ttft`/`tps`/
/// `avg`/`cache`, priorities 50/60/70/80, source `posoco_ext_stats`); with
/// `bus = None` the observer still maintains its state and publishes
/// nowhere.
///
/// A "round" is one model response: `ModelResponseReceived` closes the round
/// (settling metrics, then re-anchoring at the current time) so a tool loop
/// measures one round per response without a fresh `TurnStarted`. Terminal
/// tool events re-anchor the pending round at the last effect end, so the
/// next round's `ttft` excludes tool-execution time; without a core
/// "request dispatched" event that anchor is the closest observable bound.
/// Each round with usage also accumulates into a per-session bucket (keyed
/// by the dispatched `EventScope` session id, falling back to a `"(no
/// scope)"` process bucket). Cache reporting is tracked separately from
/// generic usage: `cached_input_tokens=None` means unknown, while `Some(0)`
/// is an explicit zero-hit report. The clock is injectable for deterministic
/// tests; `live_interval_ms` throttles live publishes (default 250ms).
pub struct Stats {
  bus : @devkit.EventBus?
  clock : () -> Int64
  live_interval_ms : Int64
  mut round_started_ms : Int64?
  mut first_token_ms : Int64?
  mut last_chunk_ms : Int64?
  mut delta_chars : Int
  mut streamed_output_tokens : Int?
  mut chars_per_token : Double
  mut last_live_ms : Int64?
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
  live_interval_ms? : Int64 = 250,
) -> Stats {
  {
    bus,
    clock,
    live_interval_ms,
    round_started_ms: None,
    first_token_ms: None,
    last_chunk_ms: None,
    delta_chars: 0,
    streamed_output_tokens: None,
    chars_per_token: 3.5,
    last_live_ms: None,
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
      self.reset_round()
    }
    StreamChunkReceived(chunk~) => self.note_chunk(chunk)
    ToolCallSucceeded(..)
    | ToolCallFailed(..)
    | ToolCallRejected(..)
    | ToolCallAbandoned(..) =>
      // The pending round re-anchors at the last effect end so the next
      // ttft excludes tool-execution time.
      if self.first_token_ms is None {
        self.round_started_ms = Some((self.clock)())
      }
    ModelResponseReceived(usage~, ..) => {
      match usage {
        Some(u) => self.note_cache_usage(scope_key(scope), u)
        None => ()
      }
      self.close_round(usage)
    }
    TurnFailed(_) | TurnCompleted => self.reset_round()
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
/// Reset the per-round live-tracking state. Round anchoring is owned by the
/// callers (`TurnStarted`, round close, terminal tool events).
fn Stats::reset_round(self : Stats) -> Unit {
  self.first_token_ms = None
  self.last_chunk_ms = None
  self.delta_chars = 0
  self.streamed_output_tokens = None
  self.last_live_ms = None
}

///|
/// Publish one status segment. No-op without a bus.
fn Stats::publish_segment(
  self : Stats,
  segment~ : String,
  priority~ : Int,
  value~ : String,
) -> Unit {
  match self.bus {
    Some(bus) =>
      @devkit.publish_status_register(
        bus,
        source="posoco_ext_stats",
        segment~,
        priority~,
        value~,
      )
    None => ()
  }
}

///|
/// Route one streamed chunk: delta chunks mark first/last token, accumulate
/// chars, and attempt a throttled live publish; a `Usage` chunk with output
/// tokens makes the live rate exact; `Finish` carries no rate signal.
fn Stats::note_chunk(self : Stats, chunk : @posoco.StreamChunk) -> Unit {
  match chunk {
    TextDelta(token~) | ReasoningDelta(token~) =>
      self.note_delta(token.length())
    ToolCallDelta(arguments_delta~, ..) =>
      match arguments_delta {
        Some(args) => self.note_delta(args.length())
        None => ()
      }
    Usage(output_tokens~, ..) =>
      if output_tokens > 0 {
        self.streamed_output_tokens = Some(output_tokens)
        self.publish_live((self.clock)())
      }
    Finish(..) => ()
  }
}

///|
/// One delta chunk arrived; `chars` is its UTF-16 length. The clock is read
/// once and reused for the first-token mark, the last-chunk mark, and the
/// throttled live publish.
fn Stats::note_delta(self : Stats, chars : Int) -> Unit {
  let now = (self.clock)()
  match (self.round_started_ms, self.first_token_ms) {
    (Some(started), None) => {
      self.first_token_ms = Some(now)
      self.publish_segment(
        segment="ttft",
        priority=50,
        value="\{now - started}ms",
      )
    }
    _ => ()
  }
  self.last_chunk_ms = Some(now)
  self.delta_chars += chars
  self.publish_live(now)
}

///|
/// Publish the live `tps` estimate. No publish before `live_interval_ms`
/// has elapsed since the round's first token, and at most one per interval
/// afterwards. The rate is cumulative since the first token: exact when a
/// `Usage` chunk reported output tokens, else estimated from chars and
/// marked `≈`.
fn Stats::publish_live(self : Stats, now : Int64) -> Unit {
  if self.bus is None {
    return
  }
  let first = match self.first_token_ms {
    Some(first) => first
    None => return
  }
  let elapsed = now - first
  if elapsed <= 0 || elapsed < self.live_interval_ms {
    return
  }
  match self.last_live_ms {
    Some(last) => if now - last < self.live_interval_ms { return }
    None => ()
  }
  self.last_live_ms = Some(now)
  let exact = self.streamed_output_tokens is Some(_)
  let tokens : Double = match self.streamed_output_tokens {
    Some(n) => n.to_double()
    None => self.delta_chars.to_double() / self.chars_per_token
  }
  let rate = tokens * 1000.0 / elapsed.to_double()
  let prefix : String = if exact { "" } else { "≈" }
  self.publish_segment(
    segment="tps",
    priority=60,
    value="\{prefix}\{fmt_one_decimal(rate)}/s",
  )
}

///|
/// Best available token count for settlement: a mid-stream `Usage` chunk
/// when it reported output tokens, else the calibrated char estimate. The
/// flag marks whether the value is exact.
fn Stats::estimate_tokens(self : Stats) -> (Double, Bool)? {
  match self.streamed_output_tokens {
    Some(n) => Some((n.to_double(), true))
    None =>
      if self.delta_chars > 0 {
        Some((self.delta_chars.to_double() / self.chars_per_token, false))
      } else {
        None
      }
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
  // Decode span: first → last delta chunk. Prefill, tool gaps, and the
  // commit tail after the last chunk stay out of the denominator.
  let decode_ms : Int64? = match (self.first_token_ms, self.last_chunk_ms) {
    (Some(first), Some(last)) => {
      let span = last - first
      if span > 0 && span <= 2147483647 {
        Some(span)
      } else {
        None
      }
    }
    _ => None
  }
  let tokens : (Double, Bool)? = match usage {
    Some(u) =>
      match u.output_tokens {
        Some(n) =>
          if n > 0 {
            Some((n.to_double(), true))
          } else {
            self.estimate_tokens()
          }
        None => self.estimate_tokens()
      }
    None => self.estimate_tokens()
  }
  let tps : (Double, Bool)? = match (tokens, decode_ms) {
    (Some((t, exact)), Some(span)) =>
      Some((t * 1000.0 / span.to_double(), exact))
    _ => None
  }
  match tps {
    Some((rate, _)) => {
      self.sum_tps += rate
      self.tps_rounds += 1
    }
    None => ()
  }
  // Recalibrate the chars-per-token ratio only from exact output counts.
  let exact_out : Int? = match usage {
    Some(u) =>
      match u.output_tokens {
        Some(n) => if n > 0 { Some(n) } else { None }
        None => None
      }
    None => None
  }
  match exact_out {
    Some(out) =>
      if self.delta_chars > 0 {
        let ratio = self.delta_chars.to_double() / out.to_double()
        self.chars_per_token = if ratio < 1.0 {
          1.0
        } else if ratio > 10.0 {
          10.0
        } else {
          ratio
        }
      }
    None => ()
  }
  self.round_started_ms = Some(now)
  self.reset_round()
  match tps {
    Some((rate, exact)) => {
      let prefix : String = if exact { "" } else { "≈" }
      self.publish_segment(
        segment="tps",
        priority=60,
        value="\{prefix}\{fmt_one_decimal(rate)}/s",
      )
    }
    None => ()
  }
  if self.tps_rounds > 0 {
    self.publish_segment(
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
      self.publish_segment(
        segment="cache",
        priority=80,
        value=cache_status_value(totals),
      )
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
  @posoco.ExtensionManifest(id="posoco_ext_stats", observers=[self], commands=[
    self,
  ])
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
