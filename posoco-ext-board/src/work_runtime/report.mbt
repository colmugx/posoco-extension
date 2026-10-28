///|
/// Validate one submitted work report: it must be an object with a non-empty
/// `outcome` and `summary`. The Board repeats its own validation on commit;
/// this gate keeps a malformed report from replacing a good earlier one,
/// because the report is stored on the run before `finish` submits it.
pub fn validate_work_report(report : Json) -> Result[Unit, String] {
  let fields = match report {
    Object(fields) => fields
    _ => return Err("work report must be a JSON object")
  }
  let outcome = match fields.get("outcome") {
    Some(String(value)) if !value.trim().is_empty() => value
    _ => return Err("work report outcome must not be empty")
  }
  let summary = match fields.get("summary") {
    Some(String(value)) if !value.trim().is_empty() => value
    _ => return Err("work report summary must not be empty")
  }
  let _ = (outcome, summary)
  Ok(())
}

///|
/// The minimal durable review report of one completed work attempt: the worker
/// result as both `outcome` and `summary`, with explicitly empty change,
/// evidence, risk, note, question and artifact lists. A blank result still gets
/// a readable fallback: the Board rejects an empty outcome or summary, and a
/// silent empty report would tell a reviewer nothing.
pub fn minimal_review_report(result : String) -> Json {
  let text = result.trim().to_owned()
  let readable = if text.is_empty() { "Work completed." } else { text }
  Json::object({
    "outcome": Json::string(readable),
    "summary": Json::string(readable),
    "changes": Json::array([]),
    "verification": Json::array([]),
    "risks": Json::array([]),
    "notes": Json::array([]),
    "open_questions": Json::array([]),
    "artifacts": Json::array([]),
  })
}
