///|
/// Per-tool execution timing and outcome counts within a session or aggregate.
priv struct ToolTiming {
  mut calls : Int32
  mut succeeded : Int32
  mut failed : Int32
  mut abandoned : Int32
  mut rejected : Int32
  mut sum_ms : Int64
  mut max_ms : Int64
}

///|
/// Per-session turn, model-request, and tool-execution telemetry derived
/// purely from core `TurnEvent` lifecycle anchors.
priv struct TimingBucket {
  mut turns : Int32
  mut completed_turns : Int32
  mut failed_turns : Int32
  mut cancelled_turns : Int32
  mut sum_turn_ms : Int64
  mut last_turn_ms : Int64?
  mut model_requests : Int32
  mut sum_model_ms : Int64
  mut ttft_rounds : Int32
  mut sum_ttft_ms : Int64
  mut tool_calls : Int32
  mut tool_failures : Int32
  mut tool_rejected : Int32
  mut sum_tool_ms : Int64
  tools : Map[String, ToolTiming]
}

///|
priv enum TurnOutcome {
  Completed
  Failed
  Cancelled
}

///|
priv enum ToolOutcomeKind {
  Succeeded
  Failed
  Abandoned
}

///|
fn new_tool_timing() -> ToolTiming {
  {
    calls: 0,
    succeeded: 0,
    failed: 0,
    abandoned: 0,
    rejected: 0,
    sum_ms: 0,
    max_ms: 0,
  }
}

///|
fn new_timing_bucket() -> TimingBucket {
  {
    turns: 0,
    completed_turns: 0,
    failed_turns: 0,
    cancelled_turns: 0,
    sum_turn_ms: 0,
    last_turn_ms: None,
    model_requests: 0,
    sum_model_ms: 0,
    ttft_rounds: 0,
    sum_ttft_ms: 0,
    tool_calls: 0,
    tool_failures: 0,
    tool_rejected: 0,
    sum_tool_ms: 0,
    tools: Map::from_array([]),
  }
}

///|
fn Stats::timing_bucket(self : Stats, key : String) -> TimingBucket {
  match self.timing_buckets.get(key) {
    Some(bucket) => bucket
    None => {
      let bucket = new_timing_bucket()
      self.timing_buckets[key] = bucket
      bucket
    }
  }
}

///|
fn tool_timing_entry(bucket : TimingBucket, name : String) -> ToolTiming {
  match bucket.tools.get(name) {
    Some(entry) => entry
    None => {
      let entry = new_tool_timing()
      bucket.tools[name] = entry
      entry
    }
  }
}

///|
fn in_flight_tool_key(session_key : String, call_id : String) -> String {
  "\{session_key}\u{0}\{call_id}"
}

///|
fn non_negative_span(end_ms : Int64, start_ms : Int64) -> Int64 {
  let span = end_ms - start_ms
  if span > 0 {
    span
  } else {
    0
  }
}

///|
fn Stats::note_turn_started(self : Stats, key : String, now : Int64) -> Unit {
  self.active_turns[key] = now
  self.active_model_requests[key] = now
}

///|
fn Stats::note_model_request_started(
  self : Stats,
  key : String,
  now : Int64,
) -> Unit {
  self.active_model_requests[key] = now
}

///|
fn Stats::note_ttft(self : Stats, key : String, ttft_ms : Int64) -> Unit {
  if ttft_ms < 0 {
    return
  }
  let bucket = self.timing_bucket(key)
  bucket.ttft_rounds += 1
  bucket.sum_ttft_ms += ttft_ms
}

///|
fn Stats::note_model_response(self : Stats, key : String, now : Int64) -> Unit {
  let bucket = self.timing_bucket(key)
  bucket.model_requests += 1
  match self.active_model_requests.get(key) {
    Some(started) => {
      bucket.sum_model_ms += non_negative_span(now, started)
      self.active_model_requests.remove(key)
    }
    None => ()
  }
}

///|
fn Stats::note_tool_started(
  self : Stats,
  key : String,
  call : @posoco.ToolCall,
) -> Unit {
  let now = (self.clock)()
  self.active_tools[in_flight_tool_key(key, call.call_id.value)] = now
}

///|
fn Stats::note_tool_finished(
  self : Stats,
  key : String,
  call : @posoco.ToolCall,
  kind : ToolOutcomeKind,
) -> Unit {
  let inflight_key = in_flight_tool_key(key, call.call_id.value)
  let elapsed = match self.active_tools.get(inflight_key) {
    Some(started_ms) => {
      self.active_tools.remove(inflight_key)
      non_negative_span((self.clock)(), started_ms)
    }
    None => 0
  }
  let bucket = self.timing_bucket(key)
  let entry = tool_timing_entry(bucket, call.name.value)
  bucket.tool_calls += 1
  bucket.sum_tool_ms += elapsed
  entry.calls += 1
  entry.sum_ms += elapsed
  if elapsed > entry.max_ms {
    entry.max_ms = elapsed
  }
  match kind {
    Succeeded => entry.succeeded += 1
    Failed => {
      bucket.tool_failures += 1
      entry.failed += 1
    }
    Abandoned => {
      bucket.tool_failures += 1
      entry.abandoned += 1
    }
  }
}

///|
fn Stats::note_tool_rejected(
  self : Stats,
  key : String,
  call : @posoco.ToolCall,
) -> Unit {
  let bucket = self.timing_bucket(key)
  let entry = tool_timing_entry(bucket, call.name.value)
  bucket.tool_rejected += 1
  entry.rejected += 1
}

///|
fn Stats::clear_session_in_flight_tools(self : Stats, key : String) -> Unit {
  let prefix = "\{key}\u{0}"
  let stale : Array[String] = []
  for inflight_key, _ in self.active_tools {
    if inflight_key.has_prefix(prefix) {
      stale.push(inflight_key)
    }
  }
  for inflight_key in stale {
    self.active_tools.remove(inflight_key)
  }
}

///|
fn Stats::note_turn_ended(
  self : Stats,
  key : String,
  outcome : TurnOutcome,
) -> Unit {
  self.active_model_requests.remove(key)
  self.clear_session_in_flight_tools(key)
  match self.active_turns.get(key) {
    Some(started) => {
      self.active_turns.remove(key)
      let elapsed = non_negative_span((self.clock)(), started)
      let bucket = self.timing_bucket(key)
      bucket.turns += 1
      bucket.sum_turn_ms += elapsed
      bucket.last_turn_ms = Some(elapsed)
      match outcome {
        Completed => bucket.completed_turns += 1
        Failed => bucket.failed_turns += 1
        Cancelled => bucket.cancelled_turns += 1
      }
    }
    None => ()
  }
}

///|
/// Uncached input tokens on rounds that explicitly reported cache telemetry.
fn uncached_cache_input(sum_cache_input : Int32, sum_cached : Int32) -> Int32 {
  let diff = sum_cache_input - sum_cached
  if diff > 0 {
    diff
  } else {
    0
  }
}

///|
/// Compact duration rendering: ms below 1s, one-decimal seconds below 60s,
/// minutes + one-decimal seconds above.
fn fmt_duration_ms(ms : Int64) -> String {
  if ms < 1000 {
    "\{ms}ms"
  } else if ms < 60000 {
    "\{fmt_one_decimal(ms.to_double() / 1000.0)}s"
  } else {
    let mins = ms / 60000
    let rem_ms = ms % 60000
    "\{mins}m\{fmt_one_decimal(rem_ms.to_double() / 1000.0)}s"
  }
}

///|
fn sorted_tool_entries(
  tools : Map[String, ToolTiming],
) -> Array[(String, ToolTiming)] {
  let entries : Array[(String, ToolTiming)] = []
  for name, timing in tools {
    entries.push((name, timing))
  }
  entries.sort_by(fn(a, b) {
    let (name_a, timing_a) = a
    let (name_b, timing_b) = b
    if timing_a.sum_ms != timing_b.sum_ms {
      if timing_a.sum_ms > timing_b.sum_ms {
        -1
      } else {
        1
      }
    } else if timing_a.calls != timing_b.calls {
      if timing_a.calls > timing_b.calls {
        -1
      } else {
        1
      }
    } else {
      name_a.compare(name_b)
    }
  })
  entries
}

///|
fn tool_timing_json(name : String, timing : ToolTiming) -> Json {
  Json::object(
    Map::from_array([
      ("name", Json::string(name)),
      ("calls", Json::number(timing.calls.to_double())),
      ("succeeded", Json::number(timing.succeeded.to_double())),
      ("failed", Json::number(timing.failed.to_double())),
      ("abandoned", Json::number(timing.abandoned.to_double())),
      ("rejected", Json::number(timing.rejected.to_double())),
      ("sum_ms", Json::number(timing.sum_ms.to_double())),
      ("max_ms", Json::number(timing.max_ms.to_double())),
    ]),
  )
}

///|
fn format_tool_summary(tools : Map[String, ToolTiming]) -> String? {
  let entries = sorted_tool_entries(tools)
  if entries.length() == 0 {
    return None
  }
  let parts : Array[String] = []
  for item in entries {
    let (name, t) = item
    let details : Array[String] = ["max \{fmt_duration_ms(t.max_ms)}"]
    if t.failed > 0 {
      details.push("\{t.failed} failed")
    }
    if t.abandoned > 0 {
      details.push("\{t.abandoned} abandoned")
    }
    if t.rejected > 0 {
      details.push("\{t.rejected} rejected")
    }
    let detail_str = details.join(", ")
    parts.push(
      "\{name} \{t.calls} (\{fmt_duration_ms(t.sum_ms)}, \{detail_str})",
    )
  }
  Some("tools: " + parts.join(" · "))
}

///|
fn timing_cache_brief(bucket : CacheBucket?) -> String {
  match bucket {
    Some(b) =>
      if b.cache_reported_requests == 0 {
        "n/a"
      } else if b.sum_cache_input > 0 {
        "\{b.hit_requests}/\{b.cache_reported_requests} (\{fmt_one_decimal(hit_rate_percent(b.sum_cached, b.sum_cache_input))}%, \{fmt_tokens(b.sum_cached)} saved)"
      } else {
        "\{b.hit_requests}/\{b.cache_reported_requests}"
      }
    None => "n/a"
  }
}

///|
fn timing_cache_totals_brief(totals : CacheTotals) -> String {
  if totals.cache_reported_requests == 0 {
    "n/a"
  } else if totals.sum_cache_input > 0 {
    "\{totals.hit_requests}/\{totals.cache_reported_requests} (\{fmt_one_decimal(hit_rate_percent(totals.sum_cached, totals.sum_cache_input))}%, \{fmt_tokens(totals.sum_cached)} saved)"
  } else {
    "\{totals.hit_requests}/\{totals.cache_reported_requests}"
  }
}

///|
fn perf_line(
  label : String,
  bucket : TimingBucket,
  cache_brief : String,
) -> String {
  let model_part = if bucket.ttft_rounds > 0 {
    let avg_ttft = bucket.sum_ttft_ms / bucket.ttft_rounds.to_int64()
    "\{bucket.model_requests} model (\{fmt_duration_ms(bucket.sum_model_ms)}, avg ttft \{fmt_duration_ms(avg_ttft)})"
  } else {
    "\{bucket.model_requests} model (\{fmt_duration_ms(bucket.sum_model_ms)})"
  }
  let tool_part = if bucket.tool_failures > 0 || bucket.tool_rejected > 0 {
    "\{bucket.tool_calls} tools (\{fmt_duration_ms(bucket.sum_tool_ms)}, \{bucket.tool_failures} err/\{bucket.tool_rejected} rej)"
  } else {
    "\{bucket.tool_calls} tools (\{fmt_duration_ms(bucket.sum_tool_ms)})"
  }
  "\{label}: \{bucket.turns} turns (\{fmt_duration_ms(bucket.sum_turn_ms)}) · \{model_part} · \{tool_part} · cache \{cache_brief}"
}

///|
fn timing_bucket_json(session : String?, bucket : TimingBucket) -> Json {
  let fields : Array[(String, Json)] = []
  match session {
    Some(s) => fields.push(("session", Json::string(s)))
    None => ()
  }
  fields.push(("turns", Json::number(bucket.turns.to_double())))
  fields.push(
    ("completed_turns", Json::number(bucket.completed_turns.to_double())),
  )
  fields.push(("failed_turns", Json::number(bucket.failed_turns.to_double())))
  fields.push(
    ("cancelled_turns", Json::number(bucket.cancelled_turns.to_double())),
  )
  fields.push(("sum_turn_ms", Json::number(bucket.sum_turn_ms.to_double())))
  match bucket.last_turn_ms {
    Some(ms) => fields.push(("last_turn_ms", Json::number(ms.to_double())))
    None => ()
  }
  fields.push(
    ("model_requests", Json::number(bucket.model_requests.to_double())),
  )
  fields.push(("sum_model_ms", Json::number(bucket.sum_model_ms.to_double())))
  fields.push(("ttft_rounds", Json::number(bucket.ttft_rounds.to_double())))
  fields.push(("sum_ttft_ms", Json::number(bucket.sum_ttft_ms.to_double())))
  fields.push(("tool_calls", Json::number(bucket.tool_calls.to_double())))
  fields.push(("tool_failures", Json::number(bucket.tool_failures.to_double())))
  fields.push(("tool_rejected", Json::number(bucket.tool_rejected.to_double())))
  fields.push(("sum_tool_ms", Json::number(bucket.sum_tool_ms.to_double())))
  let tools_json : Array[Json] = []
  for item in sorted_tool_entries(bucket.tools) {
    let (name, timing) = item
    tools_json.push(tool_timing_json(name, timing))
  }
  fields.push(("tools", Json::array(tools_json)))
  Json::object(Map::from_array(fields))
}

///|
fn Stats::sorted_all_session_keys(self : Stats) -> Array[String] {
  let seen : Map[String, Unit] = Map::from_array([])
  for key, _ in self.cache_buckets {
    seen[key] = ()
  }
  for key, _ in self.timing_buckets {
    seen[key] = ()
  }
  let keys : Array[String] = []
  for key, _ in seen {
    keys.push(key)
  }
  keys.sort()
  keys
}

///|
fn Stats::aggregate_timing(self : Stats) -> TimingBucket {
  let agg = new_timing_bucket()
  for _key, bucket in self.timing_buckets {
    agg.turns += bucket.turns
    agg.completed_turns += bucket.completed_turns
    agg.failed_turns += bucket.failed_turns
    agg.cancelled_turns += bucket.cancelled_turns
    agg.sum_turn_ms += bucket.sum_turn_ms
    agg.model_requests += bucket.model_requests
    agg.sum_model_ms += bucket.sum_model_ms
    agg.ttft_rounds += bucket.ttft_rounds
    agg.sum_ttft_ms += bucket.sum_ttft_ms
    agg.tool_calls += bucket.tool_calls
    agg.tool_failures += bucket.tool_failures
    agg.tool_rejected += bucket.tool_rejected
    agg.sum_tool_ms += bucket.sum_tool_ms
    for name, timing in bucket.tools {
      let target = tool_timing_entry(agg, name)
      target.calls += timing.calls
      target.succeeded += timing.succeeded
      target.failed += timing.failed
      target.abandoned += timing.abandoned
      target.rejected += timing.rejected
      target.sum_ms += timing.sum_ms
      if timing.max_ms > target.max_ms {
        target.max_ms = timing.max_ms
      }
    }
  }
  agg
}

///|
fn Stats::perf_report(self : Stats) -> @posoco.CommandOutcome {
  let agg = self.aggregate_timing()
  let cache_totals = self.cache_totals()
  let lines : Array[String] = []
  let sessions : Array[Json] = []
  for key in self.sorted_all_session_keys() {
    let bucket = match self.timing_buckets.get(key) {
      Some(b) => b
      None => new_timing_bucket()
    }
    sessions.push(timing_bucket_json(Some(key), bucket))
    lines.push(
      perf_line(
        "session \{key}",
        bucket,
        timing_cache_brief(self.cache_buckets.get(key)),
      ),
    )
  }
  lines.push(
    perf_line("aggregate", agg, timing_cache_totals_brief(cache_totals)),
  )
  match format_tool_summary(agg.tools) {
    Some(summary) => lines.push(summary)
    None => ()
  }
  let cache_json = Json::object(
    Map::from_array([
      ("requests", Json::number(cache_totals.requests.to_double())),
      (
        "cache_reported_requests",
        Json::number(cache_totals.cache_reported_requests.to_double()),
      ),
      ("hit_requests", Json::number(cache_totals.hit_requests.to_double())),
      ("sum_input_tokens", Json::number(cache_totals.sum_input.to_double())),
      (
        "sum_cache_input_tokens",
        Json::number(cache_totals.sum_cache_input.to_double()),
      ),
      ("sum_cached_tokens", Json::number(cache_totals.sum_cached.to_double())),
      (
        "sum_uncached_cache_input_tokens",
        Json::number(
          uncached_cache_input(
            cache_totals.sum_cache_input,
            cache_totals.sum_cached,
          ).to_double(),
        ),
      ),
      ("sum_output_tokens", Json::number(cache_totals.sum_output.to_double())),
    ]),
  )
  let structured = Json::object(
    Map::from_array([
      ("kind", Json::string("stats_perf")),
      ("sessions", Json::array(sessions)),
      ("aggregate", timing_bucket_json(None, agg)),
      ("cache", cache_json),
    ]),
  )
  @posoco.CommandOutcome::Success(
    feedback=lines.join("\n"),
    structured=Some(structured),
    ui_hint=Some(@posoco.UiHint::None),
  )
}
