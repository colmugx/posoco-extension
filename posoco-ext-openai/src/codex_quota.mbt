///
/// Codex quota capture — provider-stated usage percentages from response
/// headers.
///
/// Codex is the push-shaped provider: there is no standalone polling
/// endpoint. The authoritative numbers ride on every model response as
/// `x-codex-primary-*` (5-hour window), `x-codex-secondary-*` (weekly) and
/// `x-codex-credits-*` headers. The adapter captures them during chat
/// calls; `read()` replays the latest snapshot and `fetched_at_ms` makes
/// staleness explicit, so consumers can degrade to warn-only when no model
/// traffic has refreshed the numbers.

///|
fn codex_header(headers : @http.Headers, name : String) -> String? {
  match headers.get(name) {
    Some(value) => Some(value)
    None => None
  }
}

///|
fn codex_header_double(headers : @http.Headers, name : String) -> Double? {
  match codex_header(headers, name) {
    Some(raw) => {
      let value : Double = @string.from_str(raw.trim()) catch {
        _ => return None
      }
      Some(value)
    }
    None => None
  }
}

///|
/// Codex's boolean header vocabulary: `true`/`1` versus `false`/`0`,
/// compared case-insensitively; anything else is absent.
fn codex_header_bool(headers : @http.Headers, name : String) -> Bool? {
  match codex_header(headers, name) {
    Some(raw) => {
      let value = raw.trim().to_lower()
      if value == "true" || value == "1" {
        Some(true)
      } else if value == "false" || value == "0" {
        Some(false)
      } else {
        None
      }
    }
    None => None
  }
}

///|
/// `x-codex-*-reset-at` states unix seconds; the shared reading vocabulary
/// is milliseconds.
fn codex_reset_at_ms(headers : @http.Headers, family : String) -> Int64? {
  match codex_header(headers, family + "-reset-at") {
    Some(raw) => {
      let seconds : Int64 = @string.from_str(raw.trim()) catch {
        _ => return None
      }
      Some(seconds * 1000L)
    }
    None => None
  }
}

///|
/// Parse one response's quota headers into readings, without performing
/// I/O. Windows map by header family — `primary` is the 5-hour window and
/// `secondary` the weekly one, the pairing Codex's own UI relies on. A
/// window without a `used-percent` header states nothing and is skipped;
/// responses without any quota headers yield an empty array.
pub fn parse_codex_quota_headers(
  headers : @http.Headers,
  fetched_at_ms~ : Int64,
) -> Array[@devkit.QuotaReading] {
  let readings : Array[@devkit.QuotaReading] = []
  match codex_header_double(headers, "x-codex-primary-used-percent") {
    Some(used_percent) =>
      readings.push({
        window: "5h",
        used_percent: Some(used_percent),
        amount: None,
        available: None,
        reset_at_ms: codex_reset_at_ms(headers, "x-codex-primary"),
        fetched_at_ms,
      })
    None => ()
  }
  match codex_header_double(headers, "x-codex-secondary-used-percent") {
    Some(used_percent) =>
      readings.push({
        window: "weekly",
        used_percent: Some(used_percent),
        amount: None,
        available: None,
        reset_at_ms: codex_reset_at_ms(headers, "x-codex-secondary"),
        fetched_at_ms,
      })
    None => ()
  }
  match codex_header_bool(headers, "x-codex-credits-has-credits") {
    Some(available) => {
      let amount : (String, String)? = match
        codex_header(headers, "x-codex-credits-balance") {
        Some(raw) => {
          let trimmed = raw.trim()
          if trimmed.length() > 0 {
            Some((trimmed.to_owned(), "credits"))
          } else {
            None
          }
        }
        None => None
      }
      readings.push({
        window: "balance",
        used_percent: None,
        amount,
        available: Some(available),
        reset_at_ms: None,
        fetched_at_ms,
      })
    }
    None => ()
  }
  readings
}

///|
/// Captures the latest Codex quota snapshot from response headers and
/// replays it as a `QuotaSource`. Shared by reference with the model port,
/// which feeds it on every chat response.
pub(all) struct CodexQuotaTracker {
  mut latest : Array[@devkit.QuotaReading]?
  now_ms : () -> Int64
}

///|
pub fn CodexQuotaTracker::CodexQuotaTracker(
  now_ms? : () -> Int64 = fn() { @async.now() },
) -> CodexQuotaTracker {
  { latest: None, now_ms, }
}

///|
/// Record the readings stated by one response. Responses without quota
/// headers (API-key endpoints, unrelated providers) leave the previous
/// snapshot untouched instead of erasing it.
pub fn CodexQuotaTracker::capture(
  self : CodexQuotaTracker,
  headers : @http.Headers,
) -> Unit {
  let parsed = parse_codex_quota_headers(headers, fetched_at_ms=(self.now_ms)())
  if parsed.length() > 0 {
    self.latest = Some(parsed)
  }
}

///|
/// Record readings captured out-of-band (the usage endpoint probe). An empty
/// array states nothing and leaves the previous snapshot untouched, matching
/// `capture`.
pub fn CodexQuotaTracker::capture_readings(
  self : CodexQuotaTracker,
  readings : Array[@devkit.QuotaReading],
) -> Unit {
  if readings.length() > 0 {
    self.latest = Some(readings)
  }
}

///|
/// Process-wide tracker. One process serves one ChatGPT account, and the
/// ports that capture headers (factory build, every catalog slot, every
/// credential/effort rebuild) plus the status publisher live in different
/// composition lifetimes — the shared cell is the one rendezvous point.
/// Tests and hosts that prefer isolation construct their own tracker.
let codex_shared_quota_cell : Ref[CodexQuotaTracker?] = Ref::{ val: None, }

///|
/// The process-shared Codex quota tracker; minted once, then replayed.
pub fn codex_shared_quota_tracker() -> CodexQuotaTracker {
  match codex_shared_quota_cell.val {
    Some(tracker) => tracker
    None => {
      let tracker = CodexQuotaTracker::CodexQuotaTracker()
      codex_shared_quota_cell.val = Some(tracker)
      tracker
    }
  }
}

///|
/// Read-only copy of the latest snapshot, for hosts and tests.
pub fn CodexQuotaTracker::snapshots(
  self : CodexQuotaTracker,
) -> Array[@devkit.QuotaReading] {
  match self.latest {
    Some(list) => list.map(fn(reading) { reading })
    None => []
  }
}

///|
pub impl @devkit.QuotaSource for CodexQuotaTracker with fn read(
  self : CodexQuotaTracker,
) -> Result[Array[@devkit.QuotaReading], String] {
  match self.latest {
    Some(list) => Ok(list.map(fn(reading) { reading }))
    None => Err("no Codex quota snapshot captured yet")
  }
}
