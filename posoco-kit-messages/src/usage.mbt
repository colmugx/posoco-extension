///|
/// usage.mbt — Messages wire usage parsing and the explicit conversion rules
/// into canonical Posoco Usage.
///
/// The Messages dialect reports four counter dimensions:
///
/// - `input_tokens`: prompt tokens EXCLUDING cache activity.
/// - `output_tokens`: completion tokens.
/// - `cache_creation_input_tokens`: prompt tokens written to the cache.
/// - `cache_read_input_tokens`: prompt tokens served from the cache.
///
/// The billed prompt total is therefore
/// `input_tokens + cache_creation_input_tokens + cache_read_input_tokens`,
/// while canonical Posoco `Usage.input_tokens` is documented as the
/// provider-reported prompt TOTAL (cache hit rate = cached / input).
/// The projection below makes that asymmetry explicit; nothing is inferred
/// beyond reported dimensions.

///|
/// Native Messages usage, exactly as reported (validated). `None` marks a
/// dimension the endpoint did not report; it is never coerced to zero.
pub(all) struct MessagesUsage {
  input_tokens : Int32
  output_tokens : Int32
  cache_creation_input_tokens : Int32?
  cache_read_input_tokens : Int32?
} derive(Eq, Debug)

///|
pub extend MessagesUsage with Eq::{not_equal, equal}

///|
pub extend MessagesUsage with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The billed prompt total: wire `input_tokens` plus every cache dimension
/// the endpoint actually reported. Absent cache dimensions contribute
/// nothing; no counter is fabricated.
pub fn MessagesUsage::prompt_total(
  self : MessagesUsage,
) -> Int32 raise @posoco.ModelError {
  let mut total = self.input_tokens
  match self.cache_creation_input_tokens {
    Some(n) => {
      if total > 2147483647 - n {
        raise @posoco.ModelError::ResponseParse(
          "messages usage parse failure (stage=prompt_total, category=overflow)",
        )
      }
      total += n
    }
    None => ()
  }
  match self.cache_read_input_tokens {
    Some(n) => {
      if total > 2147483647 - n {
        raise @posoco.ModelError::ResponseParse(
          "messages usage parse failure (stage=prompt_total, category=overflow)",
        )
      }
      total += n
    }
    None => ()
  }
  total
}

///|
/// Canonical projection:
///
/// - `input_tokens` = billed prompt total (see `prompt_total`), because the
///   canonical contract computes cache hit rates against the prompt total.
/// - `output_tokens` = wire `output_tokens` verbatim.
/// - `total_tokens` = prompt total + output (the canonical convention; the
///   wire has no total field).
/// - `cached_input_tokens` = `cache_read_input_tokens` verbatim; `None`
///   stays `None`.
/// - `uncached_input_tokens` = wire `input_tokens` +
///   `cache_creation_input_tokens` (the non-read portion), reported only
///   when at least one cache dimension was reported; otherwise `None` —
///   the miss portion of an unreported cache dimension is never guessed.
pub fn MessagesUsage::to_canonical(
  self : MessagesUsage,
) -> @posoco.Usage raise @posoco.ModelError {
  let input_total = self.prompt_total()
  if input_total > 2147483647 - self.output_tokens {
    raise @posoco.ModelError::ResponseParse(
      "messages usage parse failure (stage=total_tokens, category=overflow)",
    )
  }
  let cache_reported = self.cache_creation_input_tokens is Some(_) ||
    self.cache_read_input_tokens is Some(_)
  {
    input_tokens: Some(input_total),
    output_tokens: Some(self.output_tokens),
    total_tokens: Some(input_total + self.output_tokens),
    cached_input_tokens: self.cache_read_input_tokens,
    uncached_input_tokens: if cache_reported {
      let mut miss = self.input_tokens
      match self.cache_creation_input_tokens {
        Some(n) =>
          // Already proved by prompt_total() that this addition fits.
          miss += n
        None => ()
      }
      Some(miss)
    } else {
      None
    },
  }
}

///|
/// Required counter field: missing is a typed error, never zero-filled.
fn usage_int_field(
  provider~ : String,
  usage : Map[String, Json],
  key~ : String,
) -> Int32 raise @posoco.ModelError {
  match usage.get(key) {
    Some(Json::Number(n, ..)) =>
      if n >= 0.0 && n <= 2147483647.0 && n == n.floor() {
        n.to_int()
      } else {
        raise @posoco.ModelError::ResponseParse(
          "\{provider} usage parse failure (stage=\{key}, category=out_of_range)",
        )
      }
    Some(Json::Null) | Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} usage parse failure (stage=\{key}, category=wrong_type)",
      )
    None =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} usage parse failure (stage=\{key}, category=missing)",
      )
  }
}

///|
fn usage_optional_int_field(
  provider~ : String,
  usage : Map[String, Json],
  key~ : String,
) -> Int32? raise @posoco.ModelError {
  match usage.get(key) {
    Some(Json::Number(n, ..)) =>
      if n >= 0.0 && n <= 2147483647.0 && n == n.floor() {
        Some(n.to_int())
      } else {
        raise @posoco.ModelError::ResponseParse(
          "\{provider} usage parse failure (stage=\{key}, category=out_of_range)",
        )
      }
    Some(Json::Null) | None => None
    Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} usage parse failure (stage=\{key}, category=wrong_type)",
      )
  }
}

///|
/// Parse the wire usage object. `input_tokens` and `output_tokens` are
/// protocol-required counters: missing or malformed values are typed errors,
/// never zero-filled, so partial usage can not masquerade as a complete
/// reading. Optional cache counters accept explicit null as "not reported".
pub fn parse_messages_usage(
  provider~ : String,
  usage : Json,
) -> MessagesUsage raise @posoco.ModelError {
  let fields = match usage {
    Json::Object(fields) => fields
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} usage parse failure (stage=usage, category=not_object)",
      )
  }
  {
    input_tokens: usage_int_field(provider~, fields, key="input_tokens"),
    output_tokens: usage_int_field(provider~, fields, key="output_tokens"),
    cache_creation_input_tokens: usage_optional_int_field(
      provider~,
      fields,
      key="cache_creation_input_tokens",
    ),
    cache_read_input_tokens: usage_optional_int_field(
      provider~,
      fields,
      key="cache_read_input_tokens",
    ),
  }
}
