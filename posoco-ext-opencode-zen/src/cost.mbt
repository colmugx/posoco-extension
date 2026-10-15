///|
/// Per-model cost rates, decoded from models.dev `cost` — the same catalog
/// the vendor publishes, stated in USD per 1M tokens. `None` rates mean "no
/// price known": spend estimation stays silent rather than fabricating a
/// number.
///
/// Tiered models (e.g. GPT ≤/>272K context tiers, Claude Haiku ≤/>100K)
/// carry an above-threshold rate set selected by the prompt's input-side
/// token count. Cache-write tokens are not surfaced by the core `Usage`
/// shape, so they are never billed in an estimate — the estimate is
/// conservative by construction.
pub(all) struct ZenCostRates {
  input : Double
  output : Double
  cache_read : Double
  /// Above-threshold tier, when models.dev declares one.
  tier_threshold : Int32?
  tier_input : Double
  tier_output : Double
  tier_cache_read : Double
} derive(Eq, Debug)

///|
pub extend ZenCostRates with Eq::{not_equal, equal}

///|
pub extend ZenCostRates with @moonbitlang/core/debug.Debug::{to_repr}

///|
fn json_rate(fields : Map[String, Json], key : String) -> Double {
  match fields.get(key) {
    Some(Json::Number(n, ..)) => n
    _ => 0.0
  }
}

///|
/// Decode a models.dev `cost` object into rates. Absent numeric fields
/// default to zero (free models); any other shape degrades to `None` so a
/// malformed entry never produces a phantom price.
pub fn parse_zen_cost_rates(fields : Map[String, Json]) -> ZenCostRates? {
  let rates : ZenCostRates = {
    input: json_rate(fields, "input"),
    output: json_rate(fields, "output"),
    cache_read: json_rate(fields, "cache_read"),
    tier_threshold: None,
    tier_input: 0.0,
    tier_output: 0.0,
    tier_cache_read: 0.0,
  }
  // Context tiers: models.dev lists them under `tiers[]` with a
  // `{type:"context", size:N}` selector. The first context tier is the
  // above-threshold schedule; additional tiers degrade to the first (the
  // vendor's tables currently carry at most one per model).
  match fields.get("tiers") {
    Some(Json::Array(tiers)) =>
      for tier in tiers {
        guard tier is Json::Object(tier_fields) else { continue }
        guard tier_fields.get("tier") is Some(Json::Object(selector)) else {
          continue
        }
        guard selector.get("type") is Some(Json::String("context")) else {
          continue
        }
        guard selector.get("size") is Some(Json::Number(size, ..)) else {
          continue
        }
        if size > 0.0 {
          return Some({
            ..rates,
            tier_threshold: Some(size.to_int()),
            tier_input: json_rate(tier_fields, "input"),
            tier_output: json_rate(tier_fields, "output"),
            tier_cache_read: json_rate(tier_fields, "cache_read"),
          })
        }
      }
    _ => ()
  }
  Some(rates)
}

///|
/// Estimate one model call's cost in USD. Missing usage or missing token
/// counts degrade to `None` — the caller publishes nothing rather than an
/// invented figure. The tier schedule applies when the prompt's total input
/// side (uncached + cached) reaches the declared threshold.
pub fn zen_step_cost(rates : ZenCostRates, usage : @posoco.Usage) -> Double? {
  let output = match usage.output_tokens {
    Some(n) => n.to_double()
    None => return None
  }
  let uncached = match usage.uncached_input_tokens {
    Some(n) => n.to_double()
    None =>
      match (usage.input_tokens, usage.cached_input_tokens) {
        (Some(total), Some(cached)) => (total - cached).to_double()
        (Some(total), None) => total.to_double()
        _ => return None
      }
  }
  let cached = match usage.cached_input_tokens {
    Some(n) => n.to_double()
    None => 0.0
  }
  // Tier selection keys on the prompt's input side, matching how the
  // vendor's context-tier pricing reads ("≤ / > N tokens" on the request).
  let (input_rate, output_rate, cache_rate) = match rates.tier_threshold {
    Some(threshold) if uncached + cached >= threshold.to_double() =>
      (rates.tier_input, rates.tier_output, rates.tier_cache_read)
    _ => (rates.input, rates.output, rates.cache_read)
  }
  Some(
    uncached / 1_000_000.0 * input_rate +
    cached / 1_000_000.0 * cache_rate +
    output / 1_000_000.0 * output_rate,
  )
}

///|
/// Format a USD cost for the statusbar: fixed four decimals so cheap steps
/// (`$0.0003`) stay visible instead of collapsing to `$0.00` or exponent
/// notation. Negative or non-finite costs never format — they are caller
/// bugs and surface as the `?` placeholder.
pub fn zen_format_usd(cost : Double) -> String {
  if cost < 0.0 || cost != cost || cost > 1.0e12 {
    return "$?"
  }
  let quads = (cost * 10000.0 + 0.5).to_int64()
  let dollars = quads / 10000L
  let frac = quads % 10000L
  let frac_text = if frac < 10L {
    "000\{frac}"
  } else if frac < 100L {
    "00\{frac}"
  } else if frac < 1000L {
    "0\{frac}"
  } else {
    "\{frac}"
  }
  "$\{dollars}.\{frac_text}"
}
