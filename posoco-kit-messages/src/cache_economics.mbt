///|
/// Native cache economics. All rates are *relative input token multipliers*
/// supplied by the caller for its concrete model and billing contract.
/// Never infer an upstream price from a model id or invent a hit count.
pub(all) struct MessagesCacheRates {
  ordinary_input : Double
  cache_read : Double
  cache_write_5m : Double
  cache_write_1h : Double
} derive(Debug)

///|
pub extend MessagesCacheRates with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Per-TTL cache creation counters from the protocol's usage.cache_creation.
/// These are native observations, not estimates.
pub(all) struct MessagesCacheCreation {
  ephemeral_5m_input_tokens : Int32?
  ephemeral_1h_input_tokens : Int32?
} derive(Eq, Debug)

///|
pub extend MessagesCacheCreation with Eq::{equal, not_equal}

///|
pub extend MessagesCacheCreation with @moonbitlang/core/debug.Debug::{to_repr}

///|
fn optional_cache_counter(
  data : Map[String, Json],
  name : String,
) -> Int32? raise @posoco.ModelError {
  match data.get(name) {
    Some(Json::Number(n, ..)) if n >= 0.0 && n <= 2147483647.0 && n == n.floor() =>
      Some(n.to_int())
    None | Some(Json::Null) => None
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "messages cache creation counter is invalid (stage=usage.cache_creation, category=invalid)",
      )
  }
}

///|
pub fn parse_messages_cache_creation(
  usage : Json,
) -> MessagesCacheCreation raise @posoco.ModelError {
  guard usage is Json::Object(fields) else {
    raise @posoco.ModelError::ResponseParse(
      "messages usage must be an object (stage=usage, category=shape)",
    )
  }
  match fields.get("cache_creation") {
    Some(Json::Object(data)) =>
      {
        ephemeral_5m_input_tokens: optional_cache_counter(
          data, "ephemeral_5m_input_tokens",
        ),
        ephemeral_1h_input_tokens: optional_cache_counter(
          data, "ephemeral_1h_input_tokens",
        ),
      }
    None | Some(Json::Null) =>
      { ephemeral_5m_input_tokens: None, ephemeral_1h_input_tokens: None, }
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "messages cache_creation must be an object (stage=usage.cache_creation, category=shape)",
      )
  }
}

///|
/// Usage with unknown per-TTL write distribution cannot be priced precisely;
/// cost fields are therefore optional and never silently assign 5m or 1h.
pub(all) struct MessagesCacheEconomics {
  input_tokens : Int32
  cache_read_tokens : Int32?
  cache_write_tokens : Int32?
  cache_hit_ratio : Double?
  effective_input_cost : Double?
  uncached_input_cost : Double?
  net_savings : Double?
} derive(Debug)

///|
pub extend MessagesCacheEconomics with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn analyze_messages_cache_economics(
  usage : MessagesUsage,
  creation : MessagesCacheCreation,
  rates : MessagesCacheRates,
) -> MessagesCacheEconomics raise @posoco.ModelError {
  let total = usage.prompt_total()
  let cache_write = usage.cache_creation_input_tokens
  let read = usage.cache_read_input_tokens
  let hit_ratio = match read {
    Some(n) if total > 0 => Some(n.to_double() / total.to_double())
    _ => None
  }
  let valid_rates = rates.ordinary_input >= 0.0 &&
    rates.cache_read >= 0.0 &&
    rates.cache_write_5m >= 0.0 &&
    rates.cache_write_1h >= 0.0 &&
    rates.ordinary_input < 1.0e100 &&
    rates.cache_read < 1.0e100 &&
    rates.cache_write_5m < 1.0e100 &&
    rates.cache_write_1h < 1.0e100
  if !valid_rates {
    raise @posoco.ModelError::RequestBuild(
      "messages cache economics needs nonnegative finite rates (stage=economics, category=rates)",
    )
  }
  let split_valid = match
    (
      creation.ephemeral_5m_input_tokens,
      creation.ephemeral_1h_input_tokens,
      cache_write,
    ) {
    (Some(a), Some(b), Some(n)) =>
      if a <= 2147483647 - b {
        a + b == n
      } else {
        false
      }
    (Some(a), None, Some(n)) => a == n
    (None, Some(b), Some(n)) => b == n
    (None, None, Some(n)) => n == 0
    (_, _, None) =>
      creation.ephemeral_5m_input_tokens is None &&
      creation.ephemeral_1h_input_tokens is None
  }
  if !split_valid &&
    (
      creation.ephemeral_5m_input_tokens is Some(_) ||
      creation.ephemeral_1h_input_tokens is Some(_)
    ) {
    raise @posoco.ModelError::ResponseParse(
      "messages cache TTL write counters disagree (stage=economics, category=cache_creation)",
    )
  }
  let costs_known = match (read, cache_write) {
    (Some(_), Some(0)) => true
    (Some(_), Some(_)) =>
      split_valid &&
      (
        creation.ephemeral_5m_input_tokens is Some(_) ||
        creation.ephemeral_1h_input_tokens is Some(_)
      )
    _ => false
  }
  let baseline = total.to_double() * rates.ordinary_input
  let actual = if costs_known {
    let reads = read.unwrap_or(0).to_double() * rates.cache_read
    let five = creation.ephemeral_5m_input_tokens.unwrap_or(0).to_double() *
      rates.cache_write_5m
    let hour = creation.ephemeral_1h_input_tokens.unwrap_or(0).to_double() *
      rates.cache_write_1h
    Some(
      usage.input_tokens.to_double() * rates.ordinary_input +
      reads +
      five +
      hour,
    )
  } else {
    None
  }
  {
    input_tokens: total,
    cache_read_tokens: read,
    cache_write_tokens: cache_write,
    cache_hit_ratio: hit_ratio,
    effective_input_cost: actual,
    uncached_input_cost: Some(baseline),
    net_savings: match actual {
      Some(cost) => Some(baseline - cost)
      None => None
    },
  }
}

///|
/// Convenience over the native MessagesResult produced by either the
/// non-streaming decoder or the SSE state machine. Missing usage is an
/// unknown result, not zero usage. Incomplete TTL distribution is retained
/// as unknown cost by analyze_messages_cache_economics.
pub fn MessagesResult::cache_economics(
  result : MessagesResult,
  rates : MessagesCacheRates,
) -> MessagesCacheEconomics? raise @posoco.ModelError {
  match result.usage {
    Some(native) =>
      Some(
        analyze_messages_cache_economics(
          native,
          result.cache_creation.unwrap_or({
            ephemeral_5m_input_tokens: None,
            ephemeral_1h_input_tokens: None,
          }),
          rates,
        ),
      )
    None => None
  }
}
