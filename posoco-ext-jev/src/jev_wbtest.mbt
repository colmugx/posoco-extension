///|
fn jev_test_request() -> @posoco.DecisionRequest {
  {
    state: Json::object({
      "query": Json::string("review the ticket"),
    }),
    questions: [
      @posoco.DecisionQuestion::Boolean(
        id="safe",
        instructions=Json::string("Is the operation safe?"),
        true_criteria=Some(Json::string("No side effects")),
        false_criteria=Some(Json::string("Has side effects")),
      ),
      @posoco.DecisionQuestion::Choice(
        id="route",
        instructions=Json::string("Choose the best route"),
        options=[
          { id: "fast", description: Some(Json::string("Fast path")), },
          { id: "deep", description: Some(Json::string("Deep path")), },
        ],
      ),
      @posoco.DecisionQuestion::Score(
        id="effort",
        instructions=Json::string("How much effort?"),
        levels=[
          Json::string("low"),
          Json::string("medium"),
          Json::string("high"),
        ],
      ),
    ],
  }
}

///|
test "jev encodes boolean choice and score in one System One request" {
  let payload = build_jev_request(jev_test_request(), "jev-latest")
  guard payload is Object(root) else {
    fail("expected request object")
  }
  assert_true(root.get("model") is Some(String("jev-latest")))
  guard root.get("questions") is Some(Object(questions)) else {
    fail("expected questions object")
  }
  guard questions.get("safe") is Some(Object(safe)) else {
    fail("expected boolean question")
  }
  assert_true(safe.get("type") is Some(String("noul")))
  guard safe.get("criteria") is Some(Object(criteria)) else {
    fail("expected noul criteria")
  }
  assert_true(criteria.get("true") is Some(String("No side effects")))
  assert_true(criteria.get("false") is Some(String("Has side effects")))
  guard questions.get("route") is Some(Object(route)) else {
    fail("expected choice question")
  }
  assert_true(route.get("type") is Some(String("choice")))
  guard route.get("criteria") is Some(Object(options)) else {
    fail("expected choice criteria")
  }
  assert_true(options.get("fast") is Some(String("Fast path")))
  assert_true(options.get("deep") is Some(String("Deep path")))
  guard questions.get("effort") is Some(Object(effort)) else {
    fail("expected score question")
  }
  assert_true(effort.get("type") is Some(String("score")))
  guard effort.get("criteria") is Some(Array(levels)) else {
    fail("expected score criteria")
  }
  assert_eq(levels.length(), 3)
}

///|
test "jev decodes official System One response shape" {
  let request = jev_test_request()
  let payload = Json::object({
    "model": Json::string("speed_v12_snowy_flower"),
    "answers": Json::object({
      "safe": Json::object({
        "type": Json::string("noul"),
        "noul": Json::number(0.8),
        "stats": Json::object({}),
      }),
      "route": Json::object({
        "type": Json::string("choice"),
        "choice": Json::string("deep"),
        "confidence": Json::number(0.75),
        "probabilities": Json::object({
          "fast": Json::number(0.25),
          "deep": Json::number(0.75),
        }),
        "stats": Json::object({}),
      }),
      "effort": Json::object({
        "type": Json::string("score"),
        "score": Json::number(1.7),
        "confidence": Json::number(0.7),
        "legend": Json::object({
          "0": Json::string("low"),
          "1": Json::string("medium"),
          "2": Json::string("high"),
        }),
        "probabilities": Json::object({
          "0": Json::number(0.1),
          "1": Json::number(0.1),
          "2": Json::number(0.8),
        }),
        "stats": Json::object({}),
      }),
    }),
    "usage": Json::object({
      "input_tokens": Json::number(120.0),
      "output_tokens": Json::number(15.0),
    }),
  })
  let result = decode_jev_response(payload, request)
  assert_eq(result.model, Some("speed_v12_snowy_flower"))
  assert_eq(result.usage, Some({ input_tokens: Some(120), output_tokens: Some(15), }))
  match result.answers[0] {
    @posoco.DecisionAnswer::BooleanAnswer(id~, probability_true~) => {
      assert_eq(id, "safe")
      assert_eq(probability_true, 0.8)
    }
    _ => fail("expected BooleanAnswer")
  }
  match result.answers[1] {
    @posoco.DecisionAnswer::ChoiceAnswer(
      id~,
      selected~,
      probabilities~,
      confidence~,
    ) => {
      assert_eq(id, "route")
      assert_eq(selected, "deep")
      assert_eq(probabilities.length(), 2)
      assert_eq(confidence, Some(0.75))
    }
    _ => fail("expected ChoiceAnswer")
  }
  match result.answers[2] {
    @posoco.DecisionAnswer::ScoreAnswer(
      id~,
      score~,
      probabilities~,
      confidence~,
    ) => {
      assert_eq(id, "effort")
      assert_eq(score, 1.7)
      assert_eq(probabilities, [0.1, 0.1, 0.8])
      assert_eq(confidence, Some(0.7))
    }
    _ => fail("expected ScoreAnswer")
  }
}

///|
test "jev rejects provider-incompatible primitive state locally" {
  let request : @posoco.DecisionRequest = {
    state: Json::boolean(true),
    questions: [
      @posoco.DecisionQuestion::Boolean(
        id="q",
        instructions=Json::string("question"),
        true_criteria=None,
        false_criteria=None,
      ),
    ],
  }
  let mut rejected = false
  ignore(build_jev_request(request, "jev-latest")) catch {
    @posoco.DecisionError::InvalidRequest(_) => rejected = true
    _ => fail("expected InvalidRequest")
  }
  assert_true(rejected)
}

///|
test "jev manifest contributes exactly one decision port" {
  let port = JevDecisionPort(JevConfig("test-key"))
  let manifest = port.manifest()
  assert_eq(manifest.id, "posoco_ext_jev")
  assert_eq(manifest.decisions.length(), 1)
  assert_eq(manifest.models.length(), 0)
  assert_eq(manifest.tools.length(), 0)
  assert_eq(manifest.hooks.length(), 0)
  assert_eq(manifest.requires.length(), 0)
}

///|
test "jev HTTP status normalization distinguishes bad request rate limit and transport" {
  assert_true(jev_http_error(400, 10) is @posoco.DecisionError::RequestBuild(_))
  assert_true(jev_http_error(429, 10) is @posoco.DecisionError::RateLimited(_))
  assert_true(jev_http_error(503, 10) is @posoco.DecisionError::Transport(_))
}

///|
priv struct JevTestCredentialStore {
  value : @oauth.ProviderCredential?
}

///|
impl @oauth.ProviderCredentialStore for JevTestCredentialStore with fn read(
  self : JevTestCredentialStore,
  _provider_id : String,
) -> @oauth.ProviderCredential? {
  self.value
}

///|
impl @oauth.ProviderCredentialStore for JevTestCredentialStore with fn write(
  _self : JevTestCredentialStore,
  _provider_id : String,
  _credential : @oauth.ProviderCredential,
) -> Unit {
  ()
}

///|
impl @oauth.ProviderCredentialStore for JevTestCredentialStore with fn delete(
  _self : JevTestCredentialStore,
  _provider_id : String,
) -> Unit {
  ()
}

///|
async test "jev credential store API key overrides config fallback" {
  let store = JevTestCredentialStore::{
    value: Some(
      @oauth.ProviderCredential::ApiKey(
        @oauth.ApiKeyCredential::ApiKeyCredential(secret="stored-key"),
      ),
    ),
  }
  let port = JevDecisionPort(
    JevConfig("fallback-key"),
    credential_store=Some(store as &@oauth.ProviderCredentialStore),
  )
  assert_eq(port.resolve_api_key(), "stored-key")
}

///|
async test "jev credential store miss falls back to config API key" {
  let store = JevTestCredentialStore::{ value: None, }
  let port = JevDecisionPort(
    JevConfig("fallback-key"),
    credential_store=Some(store as &@oauth.ProviderCredentialStore),
  )
  assert_eq(port.resolve_api_key(), "fallback-key")
}

///|
async test "jev stored OAuth credential never falls back to config API key" {
  let store = JevTestCredentialStore::{
    value: Some(
      @oauth.ProviderCredential::OAuth(
        @oauth.Credential::Credential(
          access_token="oauth-token",
          refresh_token="refresh",
          expires_at=0,
        ),
      ),
    ),
  }
  let port = JevDecisionPort(
    JevConfig("fallback-key"),
    credential_store=Some(store as &@oauth.ProviderCredentialStore),
  )
  let mut rejected = false
  ignore(port.resolve_api_key()) catch {
    @posoco.DecisionError::RequestBuild(_) => rejected = true
    _ => fail("expected RequestBuild for OAuth credential")
  }
  assert_true(rejected)
}

///|
async test "jev missing store credential and fallback reports RequestBuild" {
  let store = JevTestCredentialStore::{ value: None, }
  let port = JevDecisionPort(
    JevConfig::stored(),
    credential_store=Some(store as &@oauth.ProviderCredentialStore),
  )
  let mut rejected = false
  ignore(port.resolve_api_key()) catch {
    @posoco.DecisionError::RequestBuild(_) => rejected = true
    _ => fail("expected RequestBuild for missing credential")
  }
  assert_true(rejected)
}
