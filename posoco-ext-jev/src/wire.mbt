///|
/// Pure Jev System One wire encoder/decoder. HTTP concerns stay in the
/// target-specific DecisionPort implementation so protocol behavior is fully
/// testable offline.

///|
fn jev_question_json(question : @posoco.DecisionQuestion) -> Json {
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
fn question_id(question : @posoco.DecisionQuestion) -> String {
  match question {
    @posoco.DecisionQuestion::Boolean(id~, ..)
    | @posoco.DecisionQuestion::Choice(id~, ..)
    | @posoco.DecisionQuestion::Score(id~, ..) => id
  }
}

///|
/// Encode one provider-neutral request as the official System One payload.
fn build_jev_request(
  request : @posoco.DecisionRequest,
  model : String,
) -> Json raise @posoco.DecisionError {
  request.validate()
  match request.state {
    Json::Number(_, ..) | Json::True | Json::False =>
      raise @posoco.DecisionError::InvalidRequest(
        "TypeSafe Jev state must be string, object, array, or null",
      )
    _ => ()
  }
  let questions : Map[String, Json] = Map::from_array([])
  for question in request.questions {
    questions[question_id(question)] = jev_question_json(question)
  }
  Json::object({
    "state": request.state,
    "model": Json::string(model),
    "questions": Json::object(questions),
  })
}

///|
fn response_parse(message : String) -> @posoco.DecisionError {
  @posoco.DecisionError::ResponseParse("TypeSafe Jev response parse failure: " + message)
}

///|
fn require_object(
  value : Json,
  label : String,
) -> Map[String, Json] raise @posoco.DecisionError {
  match value {
    Object(fields) => fields
    _ => raise response_parse(label + " must be an object")
  }
}

///|
fn require_string(
  fields : Map[String, Json],
  key : String,
  label : String,
) -> String raise @posoco.DecisionError {
  match fields.get(key) {
    Some(String(value)) => value
    Some(_) => raise response_parse(label + "." + key + " must be a string")
    None => raise response_parse(label + "." + key + " is missing")
  }
}

///|
fn require_number(
  fields : Map[String, Json],
  key : String,
  label : String,
) -> Double raise @posoco.DecisionError {
  match fields.get(key) {
    Some(Number(value, ..)) => value
    Some(_) => raise response_parse(label + "." + key + " must be a number")
    None => raise response_parse(label + "." + key + " is missing")
  }
}

///|
fn require_answer_type(
  answer : Map[String, Json],
  expected : String,
  id : String,
) -> Unit raise @posoco.DecisionError {
  let actual = require_string(answer, "type", "answers." + id)
  if actual != expected {
    raise response_parse(
      "answers." + id + ".type expected '" + expected + "' but got '" + actual + "'",
    )
  }
}

///|
fn decode_boolean_answer(
  id : String,
  answer : Map[String, Json],
) -> @posoco.DecisionAnswer raise @posoco.DecisionError {
  require_answer_type(answer, "noul", id)
  @posoco.DecisionAnswer::BooleanAnswer(
    id~,
    probability_true=require_number(answer, "noul", "answers." + id),
  )
}

///|
fn decode_choice_answer(
  id : String,
  options : Array[@posoco.DecisionOption],
  answer : Map[String, Json],
) -> @posoco.DecisionAnswer raise @posoco.DecisionError {
  require_answer_type(answer, "choice", id)
  let selected = require_string(answer, "choice", "answers." + id)
  let probabilities = match answer.get("probabilities") {
    Some(Object(values)) => values
    Some(_) =>
      raise response_parse("answers." + id + ".probabilities must be an object")
    None =>
      raise response_parse("answers." + id + ".probabilities is missing")
  }
  let entries : Array[@posoco.DecisionNamedProbability] = []
  for option in options {
    entries.push({
      id: option.id,
      probability: require_number(
        probabilities,
        option.id,
        "answers." + id + ".probabilities",
      ),
    })
  }
  let confidence = match answer.get("confidence") {
    Some(Number(value, ..)) => Some(value)
    Some(_) =>
      raise response_parse("answers." + id + ".confidence must be a number")
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
fn decode_score_answer(
  id : String,
  levels : Array[Json],
  answer : Map[String, Json],
) -> @posoco.DecisionAnswer raise @posoco.DecisionError {
  require_answer_type(answer, "score", id)
  let score = require_number(answer, "score", "answers." + id)
  let probabilities = match answer.get("probabilities") {
    Some(Object(values)) => values
    Some(_) =>
      raise response_parse("answers." + id + ".probabilities must be an object")
    None =>
      raise response_parse("answers." + id + ".probabilities is missing")
  }
  let values : Array[Double] = []
  for i in 0..<levels.length() {
    values.push(
      require_number(
        probabilities,
        i.to_string(),
        "answers." + id + ".probabilities",
      ),
    )
  }
  let confidence = match answer.get("confidence") {
    Some(Number(value, ..)) => Some(value)
    Some(_) =>
      raise response_parse("answers." + id + ".confidence must be a number")
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
fn decode_usage(
  root : Map[String, Json],
) -> @posoco.DecisionUsage raise @posoco.DecisionError {
  let usage = match root.get("usage") {
    Some(Object(fields)) => fields
    Some(_) => raise response_parse("usage must be an object")
    None => raise response_parse("usage is missing")
  }
  {
    input_tokens: Some(require_number(usage, "input_tokens", "usage").to_int()),
    output_tokens: Some(require_number(usage, "output_tokens", "usage").to_int()),
  }
}

///|
/// Decode and validate the official Jev System One response against the exact
/// request that produced it. Unknown provider fields are intentionally ignored.
fn decode_jev_response(
  payload : Json,
  request : @posoco.DecisionRequest,
) -> @posoco.DecisionResult raise @posoco.DecisionError {
  let root = require_object(payload, "response")
  let model = require_string(root, "model", "response")
  let answers = match root.get("answers") {
    Some(Object(fields)) => fields
    Some(_) => raise response_parse("answers must be an object")
    None => raise response_parse("answers is missing")
  }
  let decoded : Array[@posoco.DecisionAnswer] = []
  for question in request.questions {
    let id = question_id(question)
    let answer = match answers.get(id) {
      Some(Object(fields)) => fields
      Some(_) => raise response_parse("answers." + id + " must be an object")
      None => raise response_parse("answers." + id + " is missing")
    }
    decoded.push(
      match question {
        @posoco.DecisionQuestion::Boolean(..) =>
          decode_boolean_answer(id, answer)
        @posoco.DecisionQuestion::Choice(options~, ..) =>
          decode_choice_answer(id, options, answer)
        @posoco.DecisionQuestion::Score(levels~, ..) =>
          decode_score_answer(id, levels, answer)
      },
    )
  }
  let result : @posoco.DecisionResult = {
    answers: decoded,
    model: Some(model),
    usage: Some(decode_usage(root)),
  }
  result.validate_for(request)
  result
}
