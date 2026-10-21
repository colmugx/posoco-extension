///|
/// Goal completion is a claim made by the worker; this is the independent
/// result of applying the user-authorized acceptance policy to evidence.
pub(all) struct GoalEvidence {
  criterion : String
  source : String
  reference : String
} derive(Eq, Debug)

///|
pub(all) enum GoalAssessment {
  Verified(Array[GoalEvidence])
  Rejected(String)
  Inconclusive(String)
} derive(Eq, Debug)

///|
pub(all) struct GoalVerificationRequest {
  goal : String
  criteria : Array[String]
  session_id : String
  claim : String
} derive(Debug)

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
          if item.criterion == criterion && item.source != "" &&
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
      (
        "criteria",
        Json::array(request.criteria.map(fn(s) { Json::string(s) })),
      ),
    ]),
  )
  let input : @posoco.DecisionRequest = {
    state,
    questions: [question],
  }
  let answer : Result[@posoco.DecisionResult, String] = Ok(
    self.decision.evaluate_with_context(
      input,
      context=@posoco.DecisionCallContext::make(
        purpose="goal_semantic_advice",
        scope=Some({ session: request.session_id, }),
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
      let validated : Result[Unit, String] = Ok(
        result.validate_for(input),
      ) catch {
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
