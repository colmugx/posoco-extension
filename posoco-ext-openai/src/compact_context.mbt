///|
/// ModelInfo serde default: absent metadata is false, never a slug guess.
fn model_responses_lite(
  fields : Map[String, Json],
) -> Bool raise @posoco.ModelError {
  match fields.get("use_responses_lite") {
    Some(Json::True) => true
    Some(Json::False) | None => false
    _ =>
      raise @posoco.ModelError::ResponseParse(
        "OpenAI models use_responses_lite must be a boolean",
      )
  }
}
