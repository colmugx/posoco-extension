///|
/// The pull-style spend reading for the Console (pay-as-you-go) plane.
///
/// What this provider can state truthfully is the locally accumulated,
/// rates-derived session spend; OpenCode publishes no balance API an API key
/// can read (the console shows it through browser-only server actions), so
/// no balance figure is ever fabricated here — the console is where the
/// authoritative balance lives. The reading is `window="spend"` with the
/// cumulative estimate as `(value, "USD")`; before the first recorded step
/// there is nothing to state and the read returns an empty list.
pub(all) struct ZenSpendQuotaSource {
  tracker : ZenSpendTracker
}

///|
pub fn ZenSpendQuotaSource::ZenSpendQuotaSource(
  tracker~ : ZenSpendTracker,
) -> ZenSpendQuotaSource {
  { tracker, }
}

///|
pub impl @devkit.QuotaSource for ZenSpendQuotaSource with fn read(
  self : ZenSpendQuotaSource,
) -> Result[Array[@devkit.QuotaReading], String] {
  let now = @async.now()
  let readings : Array[@devkit.QuotaReading] = []
  for session_id, total in self.tracker.buckets {
    readings.push({
      window: "spend(" + session_id + ")",
      used_percent: None,
      amount: Some((zen_format_usd(total), "USD")),
      available: None,
      reset_at_ms: None,
      fetched_at_ms: now,
    })
  }
  Ok(readings)
}

///|
pub extend ZenSpendQuotaSource with @devkit.QuotaSource::{read}

///|
/// Register the pull-style spend reading under the provider id, mirroring the
/// deepseek/zai pattern: every configured build/refresh re-registers, and
/// pull consumers (the `/status` command, the model picker) read live at
/// command time.
pub fn zen_register_quota_sources() -> Unit {
  let source : &@devkit.QuotaSource = ZenSpendQuotaSource(
    tracker=zen_spend_tracker(),
  )
  @devkit.quota_registry_register(zen_provider_id, source)
}
