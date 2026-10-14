///|
/// count_tokens.mbt — codec for `/v1/messages/count_tokens`.
///
/// The endpoint accepts the same message/tool shapes as the main request
/// (model is required; `max_tokens` is not part of this endpoint) and
/// replies with a single `{"input_tokens": N}` object. N is the prompt
/// total in the same convention as the main flow's `input_tokens` — cache
/// dimensions do not apply here.

///|
/// Assemble a token-counting request body. Reuses the wire message encoding
/// (`message_to_wire` output) and tool encoding, so transcript fidelity
/// matches the main request path.
pub fn count_tokens_request(
  model~ : String,
  messages~ : Array[Json],
  system~ : Json? = None,
  tools~ : Array[Json] = [],
  thinking~ : ThinkingConfig? = None,
) -> Json raise @posoco.ModelError {
  if model == "" {
    raise @posoco.ModelError::RequestBuild(
      "messages count_tokens model must be non-empty (stage=encode, category=model)",
    )
  }
  if messages.is_empty() {
    raise @posoco.ModelError::RequestBuild(
      "messages count_tokens requires at least one message (stage=encode, category=empty)",
    )
  }
  let fields : Array[(String, Json)] = [("model", Json::string(model))]
  match system {
    Some(system) => fields.push(("system", system))
    None => ()
  }
  fields.push(("messages", Json::array(messages.copy())))
  if !tools.is_empty() {
    fields.push(("tools", Json::array(tools.copy())))
  }
  match thinking {
    Some(config) => fields.push(("thinking", config.to_wire()))
    None => ()
  }
  Json::object(Map::from_array(fields))
}

///|
/// Parse the counting response into the reported prompt token count.
/// Negative, fractional, missing, or non-numeric values are typed errors —
/// never coerced.
pub fn parse_count_tokens_response(
  provider~ : String,
  body : Json,
) -> Int32 raise @posoco.ModelError {
  let fields = match body {
    Json::Object(fields) => fields
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} count_tokens parse failure (stage=response, category=not_object)",
      )
  }
  match fields.get("input_tokens") {
    Some(Json::Number(n, ..)) =>
      if n >= 0.0 && n <= 2147483647.0 && n == n.floor() {
        n.to_int()
      } else {
        raise @posoco.ModelError::ResponseParse(
          "\{provider} count_tokens parse failure (stage=input_tokens, category=out_of_range)",
        )
      }
    Some(Json::Null) | Some(_) =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} count_tokens parse failure (stage=input_tokens, category=wrong_type)",
      )
    None =>
      raise @posoco.ModelError::ResponseParse(
        "\{provider} count_tokens parse failure (stage=input_tokens, category=missing)",
      )
  }
}
