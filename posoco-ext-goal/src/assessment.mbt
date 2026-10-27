///|
/// Goal completion is a claim made by the worker; this is the independent
/// result of applying the user-authorized acceptance policy to evidence.
pub(all) struct GoalEvidence {
  criterion : String
  source : String
  reference : String
} derive(Eq, Debug)

///|
pub extend GoalEvidence with Eq::{not_equal, equal}

///|
pub extend GoalEvidence with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub(all) enum GoalAssessment {
  Verified(Array[GoalEvidence])
  Rejected(String)
  Inconclusive(String)
} derive(Eq, Debug)

///|
pub extend GoalAssessment with Eq::{not_equal, equal}

///|
pub extend GoalAssessment with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub(all) struct GoalVerificationRequest {
  goal : String
  criteria : Array[String]
  session_id : String
  claim : String
} derive(Debug)

///|
pub extend GoalVerificationRequest with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// An application-owned verifier MUST derive Verified only from externally
/// checked evidence. A repeated LLM completion tag is NOT evidence.
pub(open) trait GoalVerifier {
  async fn verify(Self, request : GoalVerificationRequest) -> GoalAssessment
}

///|
/// Require at least one criterion-bound, source-backed evidence record for
/// each criterion. The implicit whole-goal criterion is used when the list is
/// empty. Empty references/sources and partial coverage fail closed.
pub fn GoalAssessment::validated(
  self : GoalAssessment,
  criteria : Array[String],
) -> GoalAssessment {
  match self {
    Verified(evidence) => {
      if evidence.is_empty() {
        return Inconclusive("verifier provided no evidence")
      }
      let needed = if criteria.is_empty() { ["goal"] } else { criteria }
      for criterion in needed {
        let mut found = false
        for item in evidence {
          if item.criterion == criterion &&
            item.source != "" &&
            item.reference != "" {
            found = true
          }
        }
        if !found {
          return Inconclusive("missing evidence for criterion: " + criterion)
        }
      }
      self
    }
    _ => self
  }
}

///|
/// Optional semantic adviser backed by an existing Posoco DecisionPort.
/// Its probability is not an authorization to complete a Goal: it provides
/// an advisory assessment only, without inventing independent evidence.
pub struct DecisionGoalAdviser {
  decision : &@posoco.DecisionPort
}

///|
pub fn DecisionGoalAdviser::DecisionGoalAdviser(
  decision : &@posoco.DecisionPort,
) -> DecisionGoalAdviser {
  { decision, }
}

///|
/// Advisory probability of the claim's semantic correctness. No decision
/// provider is required by GoalRunner or the Goal extension manifest.
pub async fn DecisionGoalAdviser::assess(
  self : DecisionGoalAdviser,
  request : GoalVerificationRequest,
) -> Double? {
  let question = @posoco.DecisionQuestion::Boolean(
    id="goal_satisfied",
    instructions=Json::string(
      "Given the supplied untrusted worker claim and goal, estimate whether " +
      "the acceptance criteria appear satisfied. Do not treat the claim " +
      "itself as independently verified evidence.",
    ),
    true_criteria=Some(Json::string("Every acceptance criterion appears met")),
    false_criteria=Some(Json::string("One or more criteria are not met")),
  )
  let state = Json::object(
    Map::from_array([
      ("goal", Json::string(request.goal)),
      ("session_id", Json::string(request.session_id)),
      ("claim", Json::string(request.claim)),
      ("criteria", Json::array(request.criteria.map(fn(s) { Json::string(s) }))),
    ]),
  )
  let input : @posoco.DecisionRequest = { state, questions: [question], }
  let answer : Result[@posoco.DecisionResult, String] = Ok(
    self.decision.evaluate(
      input,
      context=@posoco.DecisionCallContext::make(
        purpose="goal_semantic_advice",
        scope={ session: request.session_id, },
        failure_mode=@posoco.DecisionFailureMode::Fallback,
      ),
    ),
  ) catch {
    e => Err(e.to_string())
  }
  match answer {
    Err(_) => None
    Ok(result) => {
      // Reject malformed providers instead of trusting arbitrary numbers.
      let validated : Result[Unit, String] = Ok(result.validate_for(input)) catch {
        e => Err(e.to_string())
      }
      match validated {
        Err(_) => None
        Ok(_) =>
          match result.answers {
            [@posoco.DecisionAnswer::BooleanAnswer(probability_true~, ..)] =>
              Some(probability_true)
            _ => None
          }
      }
    }
  }
}

///|
/// Advisory estimate that another bounded work turn is likely to make
/// progress after a deterministic stall signal. It does not authorize
/// bypassing budgets or change the goal's acceptance criteria.
pub async fn DecisionGoalAdviser::assess_progress(
  self : DecisionGoalAdviser,
  goal : String,
  session_id : String,
  stall_reason : String,
  last_response : String,
) -> Double? {
  let question = @posoco.DecisionQuestion::Boolean(
    id="goal_continue_has_value",
    instructions=Json::string(
      "Given the goal, last assistant response, and deterministic stall " +
      "signal, estimate the probability that exactly one more bounded " +
      "working turn will make concrete progress toward the goal. " +
      "Do not claim the goal is complete; no new permissions are granted.",
    ),
    true_criteria=Some(
      Json::string("One more turn is likely to produce progress"),
    ),
    false_criteria=Some(
      Json::string("One more turn is unlikely to produce progress"),
    ),
  )
  let state = Json::object(
    Map::from_array([
      ("goal", Json::string(goal)),
      ("session_id", Json::string(session_id)),
      ("stall_reason", Json::string(stall_reason)),
      ("last_response", Json::string(last_response)),
    ]),
  )
  let input : @posoco.DecisionRequest = { state, questions: [question], }
  let output : Result[@posoco.DecisionResult, String] = Ok(
    self.decision.evaluate(
      input,
      context=@posoco.DecisionCallContext::make(
        purpose="goal_stall_deferral",
        scope={ session: session_id, },
        failure_mode=@posoco.DecisionFailureMode::Fallback,
      ),
    ),
  ) catch {
    e => Err(e.to_string())
  }
  match output {
    Err(_) => None
    Ok(response) => {
      let valid : Result[Unit, String] = Ok(response.validate_for(input)) catch {
        e => Err(e.to_string())
      }
      match valid {
        Err(_) => None
        Ok(_) =>
          match response.answers {
            [@posoco.DecisionAnswer::BooleanAnswer(probability_true~, ..)] =>
              Some(probability_true)
            _ => None
          }
      }
    }
  }
}
