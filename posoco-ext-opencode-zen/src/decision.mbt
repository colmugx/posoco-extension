///|
/// OpenCode Jev decision wire: the vendor's official System One endpoint,
/// served by the gateway for every model whose derived wire is `SystemOne`
/// (the `jev-*` family). The request/response codec below is the pure wire
/// vocabulary; HTTP, auth, headers, and error mapping live in the
/// target-specific DecisionPort implementation so protocol behavior stays
/// fully testable offline. The Go plane (`posoco-ext-opencode-go`) reuses
/// this codec the same way it reuses every other wire piece of this package;
/// its call implementation remains its own.

///|
let systemone_default_timeout_ms : Int32 = 30000

///|
fn systemone_question_json(question : @posoco.DecisionQuestion) -> Json {
  match question {
    @posoco.DecisionQuestion::Boolean(
      instructions~,
      true_criteria~,
      false_criteria~,
      ..
    ) => {
      let fields : Map[String, Json] = {
        "type": Json::string("noul"),
        "instructions": instructions,
      }
      let criteria : Map[String, Json] = Map::from_array([])
      match true_criteria {
        Some(value) => criteria["true"] = value
        None => ()
      }
      match false_criteria {
        Some(value) => criteria["false"] = value
        None => ()
      }
      if !criteria.is_empty() {
        fields["criteria"] = Json::object(criteria)
      }
      Json::object(fields)
    }
    @posoco.DecisionQuestion::Choice(instructions~, options~, ..) => {
      let criteria : Map[String, Json] = Map::from_array([])
      for option in options {
        criteria[option.id] = match option.description {
          Some(description) => description
          None => Json::null()
        }
      }
      Json::object({
        "type": Json::string("choice"),
        "instructions": instructions,
        "criteria": Json::object(criteria),
      })
    }
    @posoco.DecisionQuestion::Score(instructions~, levels~, ..) =>
      Json::object({
        "type": Json::string("score"),
        "instructions": instructions,
        "criteria": Json::array(levels),
      })
  }
}

///|
fn systemone_question_id(question : @posoco.DecisionQuestion) -> String {
  match question {
    @posoco.DecisionQuestion::Boolean(id~, ..)
    | @posoco.DecisionQuestion::Choice(id~, ..)
    | @posoco.DecisionQuestion::Score(id~, ..) => id
  }
}

///|
/// Encode one provider-neutral request as the official System One payload.
/// Primitive JSON states have no System One representation and are rejected
/// locally instead of round-tripping to the gateway.
pub fn systemone_request_json(
  request : @posoco.DecisionRequest,
  model : String,
) -> Json raise @posoco.DecisionError {
  request.validate()
  match request.state {
    Json::Number(_, ..) | Json::True | Json::False =>
      raise @posoco.DecisionError::InvalidRequest(
        "System One state must be string, object, array, or null",
      )
    _ => ()
  }
  let questions : Map[String, Json] = Map::from_array([])
  for question in request.questions {
    questions[systemone_question_id(question)] = systemone_question_json(
      question,
    )
  }
  Json::object({
    "state": request.state,
    "model": Json::string(model),
    "questions": Json::object(questions),
  })
}

///|
fn systemone_parse_failure(message : String) -> @posoco.DecisionError {
  @posoco.DecisionError::ResponseParse(
    "System One response parse failure: " + message,
  )
}

///|
fn systemone_require_object(
  value : Json,
  label : String,
) -> Map[String, Json] raise @posoco.DecisionError {
  match value {
    Object(fields) => fields
    _ => raise systemone_parse_failure(label + " must be an object")
  }
}

///|
fn systemone_require_string(
  fields : Map[String, Json],
  key : String,
  label : String,
) -> String raise @posoco.DecisionError {
  match fields.get(key) {
    Some(String(value)) => value
    Some(_) =>
      raise systemone_parse_failure(label + "." + key + " must be a string")
    None => raise systemone_parse_failure(label + "." + key + " is missing")
  }
}

///|
fn systemone_require_number(
  fields : Map[String, Json],
  key : String,
  label : String,
) -> Double raise @posoco.DecisionError {
  match fields.get(key) {
    Some(Number(value, ..)) => value
    Some(_) =>
      raise systemone_parse_failure(label + "." + key + " must be a number")
    None => raise systemone_parse_failure(label + "." + key + " is missing")
  }
}

///|
fn systemone_require_answer_type(
  answer : Map[String, Json],
  expected : String,
  id : String,
) -> Unit raise @posoco.DecisionError {
  let actual = systemone_require_string(answer, "type", "answers." + id)
  if actual != expected {
    raise systemone_parse_failure(
      "answers." +
      id +
      ".type expected '" +
      expected +
      "' but got '" +
      actual +
      "'",
    )
  }
}

///|
fn systemone_boolean_answer(
  id : String,
  answer : Map[String, Json],
) -> @posoco.DecisionAnswer raise @posoco.DecisionError {
  systemone_require_answer_type(answer, "noul", id)
  @posoco.DecisionAnswer::BooleanAnswer(
    id~,
    probability_true=systemone_require_number(answer, "noul", "answers." + id),
  )
}

///|
fn systemone_choice_answer(
  id : String,
  options : Array[@posoco.DecisionOption],
  answer : Map[String, Json],
) -> @posoco.DecisionAnswer raise @posoco.DecisionError {
  systemone_require_answer_type(answer, "choice", id)
  let selected = systemone_require_string(answer, "choice", "answers." + id)
  let probabilities = match answer.get("probabilities") {
    Some(Object(values)) => values
    Some(_) =>
      raise systemone_parse_failure(
        "answers." + id + ".probabilities must be an object",
      )
    None =>
      raise systemone_parse_failure(
        "answers." + id + ".probabilities is missing",
      )
  }
  let entries : Array[@posoco.DecisionNamedProbability] = []
  for option in options {
    entries.push({
      id: option.id,
      probability: systemone_require_number(
        probabilities,
        option.id,
        "answers." + id + ".probabilities",
      ),
    })
  }
  let confidence = match answer.get("confidence") {
    Some(Number(value, ..)) => Some(value)
    Some(_) =>
      raise systemone_parse_failure(
        "answers." + id + ".confidence must be a number",
      )
    None => None
  }
  @posoco.DecisionAnswer::ChoiceAnswer(
    id~,
    selected~,
    probabilities=entries,
    confidence~,
  )
}

///|
fn systemone_score_answer(
  id : String,
  levels : Array[Json],
  answer : Map[String, Json],
) -> @posoco.DecisionAnswer raise @posoco.DecisionError {
  systemone_require_answer_type(answer, "score", id)
  let score = systemone_require_number(answer, "score", "answers." + id)
  let probabilities = match answer.get("probabilities") {
    Some(Object(values)) => values
    Some(_) =>
      raise systemone_parse_failure(
        "answers." + id + ".probabilities must be an object",
      )
    None =>
      raise systemone_parse_failure(
        "answers." + id + ".probabilities is missing",
      )
  }
  let values : Array[Double] = []
  for i in 0..<levels.length() {
    values.push(
      systemone_require_number(
        probabilities,
        i.to_string(),
        "answers." + id + ".probabilities",
      ),
    )
  }
  let confidence = match answer.get("confidence") {
    Some(Number(value, ..)) => Some(value)
    Some(_) =>
      raise systemone_parse_failure(
        "answers." + id + ".confidence must be a number",
      )
    None => None
  }
  @posoco.DecisionAnswer::ScoreAnswer(
    id~,
    score~,
    probabilities=values,
    confidence~,
  )
}

///|
fn systemone_usage(
  root : Map[String, Json],
) -> @posoco.DecisionUsage raise @posoco.DecisionError {
  let usage = match root.get("usage") {
    Some(Object(fields)) => fields
    Some(_) => raise systemone_parse_failure("usage must be an object")
    None => raise systemone_parse_failure("usage is missing")
  }
  {
    input_tokens: Some(
      systemone_require_number(usage, "input_tokens", "usage").to_int(),
    ),
    output_tokens: Some(
      systemone_require_number(usage, "output_tokens", "usage").to_int(),
    ),
  }
}

///|
/// Decode and validate the official System One response against the exact
/// request that produced it. Unknown provider fields are intentionally
/// ignored.
pub fn systemone_parse_response(
  payload : Json,
  request : @posoco.DecisionRequest,
) -> @posoco.DecisionResult raise @posoco.DecisionError {
  let root = systemone_require_object(payload, "response")
  let model = systemone_require_string(root, "model", "response")
  let answers = match root.get("answers") {
    Some(Object(fields)) => fields
    Some(_) => raise systemone_parse_failure("answers must be an object")
    None => raise systemone_parse_failure("answers is missing")
  }
  let decoded : Array[@posoco.DecisionAnswer] = []
  for question in request.questions {
    let id = systemone_question_id(question)
    let answer = match answers.get(id) {
      Some(Object(fields)) => fields
      Some(_) =>
        raise systemone_parse_failure("answers." + id + " must be an object")
      None => raise systemone_parse_failure("answers." + id + " is missing")
    }
    decoded.push(
      match question {
        @posoco.DecisionQuestion::Boolean(..) =>
          systemone_boolean_answer(id, answer)
        @posoco.DecisionQuestion::Choice(options~, ..) =>
          systemone_choice_answer(id, options, answer)
        @posoco.DecisionQuestion::Score(levels~, ..) =>
          systemone_score_answer(id, levels, answer)
      },
    )
  }
  let result : @posoco.DecisionResult = {
    answers: decoded,
    model: Some(model),
    usage: Some(systemone_usage(root)),
  }
  result.validate_for(request)
  result
}

///|
/// Upper bound for the provider error body embedded in a decision error.
let systemone_error_body_cap : Int32 = 2048

///|
/// Char-wise copy keeps the cut on a Unicode boundary.
fn cap_systemone_error_body(text : String) -> String {
  if text.length() <= systemone_error_body_cap {
    text
  } else {
    let sb = StringBuilder()
    let mut count = 0
    for c in text {
      if count >= systemone_error_body_cap {
        break
      }
      sb.write_char(c)
      count += 1
    }
    sb.to_string() + "...(truncated, body_chars=\{text.length()})"
  }
}

///|
/// Map a non-2xx decision call onto the existing DecisionError classes.
/// Every message names the provider and the model so failures are traceable
/// to the exact backend call; the provider's error body (the primary
/// diagnostic) rides along when it decoded as text.
fn systemone_http_error(
  provider_id : String,
  model : String,
  status : Int32,
  body_bytes : Int32,
  body~ : String? = None,
) -> @posoco.DecisionError {
  let subject = "provider=\{provider_id} model=\{model}"
  let detail = match body {
    Some(text) => ", body=\{cap_systemone_error_body(text)}"
    None => ", body_bytes=\{body_bytes}"
  }
  if status == 429 {
    @posoco.DecisionError::RateLimited({
      message: "decision rate limited (status=429\{detail}, \{subject})",
      reset_at_ms: None,
      provider_code: None,
    })
  } else if status == 400 {
    @posoco.DecisionError::RequestBuild(
      "decision request rejected (status=400\{detail}, \{subject})",
    )
  } else {
    @posoco.DecisionError::Transport(
      "decision HTTP status=\{status}\{detail}, \{subject}",
    )
  }
}

///|
/// The provider-owned decision port for one System One model of this
/// gateway. Credentials and endpoint come verbatim from the slot's config —
/// the same `base_url`/`api_key` the chat wires use; there is no fallback to
/// any other decision backend.
pub(all) struct OpenCodeZenDecisionPort {
  config : OpenCodeZenConfig
}

///|
pub fn OpenCodeZenDecisionPort::OpenCodeZenDecisionPort(
  config : OpenCodeZenConfig,
) -> OpenCodeZenDecisionPort {
  { config, }
}

///|
fn OpenCodeZenDecisionPort::decision_url(
  self : OpenCodeZenDecisionPort,
) -> String {
  self.config.base_url + self.config.endpoint_prefix + "/systemone"
}

///|
/// Effective timeout: the explicit per-call fact wins, then the shared
/// default. The gateway decision endpoint has no config-level knob.
fn OpenCodeZenDecisionPort::timeout_ms(
  self : OpenCodeZenDecisionPort,
  context~ : @posoco.DecisionCallContext,
) -> Int32 {
  match context.timeout_ms {
    Some(ms) if ms > 0 => ms
    _ => systemone_default_timeout_ms
  }
}
