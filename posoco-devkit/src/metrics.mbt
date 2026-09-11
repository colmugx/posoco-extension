///|
/// One vendor-stated benchmark point as published by an external metrics
/// source: a single `model`+`effort` pair together with the source's `iq`
/// (IQ-style score), `cost_usd` (the source's average cost per run in USD)
/// and `passed`/`total` problem counts. Token totals and durations are what
/// a consumer needs to compare completions of the same task across
/// model+effort pairs; both are omitted when the source omits them — never
/// zero-filled or estimated. Nothing here is estimated locally.
/// The shape models codex-reset-radar's intelligence-efficiency-metrics
/// entries (model/effort/iq/average_price_usd/passed/total plus the optional
/// average_total_tokens/average_minutes).
pub(all) struct MetricsPoint {
  model : String
  effort : String
  iq : Double
  cost_usd : Double
  passed : Int
  total : Int
  /// The source's average total tokens per run (feed field
  /// `average_total_tokens`); present only when the source stated it.
  tokens : Double?
  /// The source's average run duration in minutes (feed field
  /// `average_minutes`); present only when the source stated it.
  minutes : Double?
} derive(Eq, @debug.Debug)

///|
/// A source of authoritative external model metrics. Implementations live
/// in provider adapter extensions, where the vendor/community knowledge
/// resides; consumers depend only on this trait. `read` returning `Err`
/// means the metrics are unavailable — never a fallback estimate.
pub(open) trait ModelMetricsSource {
  async fn read(Self) -> Result[Array[MetricsPoint], String]
}

///|
/// Process-wide registry of named metrics sources. Provider adapter
/// extensions register their source under their provider id on every factory
/// `build`/`refresh` that yields a configured provider, so each registration
/// reflects the currently configured provider (last write wins). Pull-style
/// consumers such as the `/model <provider> pick` command look the provider
/// id up at command time and read the source live. There is deliberately no
/// unregistration on `Unconfigured` builds: a stale entry is never read
/// because consumers only query provider ids behind their slots.
let metrics_registry_cell : Ref[Map[String, &ModelMetricsSource]] = Ref::{
  val: Map::from_array([]),
}

///|
/// Register `source` under `id`, replacing any previous registration for
/// that id (last write wins).
pub fn metrics_registry_register(
  id : String,
  source : &ModelMetricsSource,
) -> Unit {
  metrics_registry_cell.val[id] = source
}

///|
/// The source registered under `id`, or `None` when nothing is registered.
pub fn metrics_registry_lookup(id : String) -> &ModelMetricsSource? {
  metrics_registry_cell.val.get(id)
}

///|
/// Drop the registration under `id`; a no-op for unknown ids.
pub fn metrics_registry_unregister(id : String) -> Unit {
  metrics_registry_cell.val.remove(id)
}
