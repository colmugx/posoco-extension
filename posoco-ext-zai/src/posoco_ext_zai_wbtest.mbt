///|
fn zai_settings(pairs : Array[(String, Json)]) -> @llm.ProviderConfigSource {
  @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(Json::object(Map::from_array(pairs))),
  )
}

///|
test "factory: unconfigured without a key" {
  let provider = ZaiProvider()
  let result = @llm.ProviderFactory::build(provider, zai_settings([]))
  inspect(result is @llm.ProviderBuildResult::Unconfigured, content="true")
}

///|
test "factory: ready catalog defaults to the Z.ai platform" {
  let provider = ZaiProvider()
  let result = @llm.ProviderFactory::build(
    provider,
    zai_settings([
      ("api_key", Json::string("k")),
      ("model", Json::string("glm-5.3-flash")),
    ]),
  )
  guard result is @llm.ProviderBuildResult::Ready(catalog) else {
    fail("expected Ready")
  }
  inspect(catalog.provider_id, content="zai")
  inspect(catalog.slots.length(), content="4")
  inspect(catalog.slots[0].model_id, content="glm-5.3-flash")
  inspect(catalog.slots[0].id, content="zai/glm-5.3-flash")
  inspect(catalog.slots[0].label, content="Z.ai / glm-5.3-flash")
  assert_false(catalog.capabilities.contains("coding_plan"))
}

///|
test "factory: platform setting selects bigmodel" {
  let config = zai_build_config(
    zai_settings([
      ("api_key", Json::string("k")),
      ("platform", Json::string("bigmodel")),
    ]),
  )
  guard config is Some(value) else { fail("expected config") }
  inspect(value.base_url, content="https://open.bigmodel.cn")
  inspect(value.endpoint_prefix, content="/api/paas/v4")
}

///|
test "factory: credential platform beats settings" {
  let source = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(
      Json::object(
        Map::from_array([
          ("api_key", Json::string("settings-key")),
          ("platform", Json::string("zai")),
        ]),
      ),
    ),
    provider_credential=Some(
      @oauth.ProviderCredential::ApiKey({
        secret: "cred-key",
        metadata: Map::from_array([("platform", "bigmodel")]),
      }),
    ),
  )
  let config = zai_build_config(source)
  guard config is Some(value) else { fail("expected config") }
  inspect(value.api_key, content="cred-key")
  inspect(value.base_url, content="https://open.bigmodel.cn")
}

///|
test "factory: base_url override keeps the platform prefix" {
  let config = zai_build_config(
    zai_settings([
      ("api_key", Json::string("k")),
      ("base_url", Json::string("https://proxy.example.com")),
    ]),
  )
  guard config is Some(value) else { fail("expected config") }
  inspect(value.base_url, content="https://proxy.example.com")
  inspect(value.endpoint_prefix, content="/api/paas/v4")
}

///|
test "factory: unknown platform is a typed failure" {
  try
    zai_build_config(
      zai_settings([
        ("api_key", Json::string("k")),
        ("platform", Json::string("eu")),
      ]),
    )
  catch {
    @posoco.CompositionError::ManifestSchemaError(detail~, ..) =>
      inspect(detail, content="unknown platform: eu (expected bigmodel | zai)")
    _ => fail("expected ManifestSchemaError")
  } noraise {
    _ => fail("expected failure")
  }
}

///|
test "factory: OAuth credential is a typed failure" {
  let provider = ZaiProvider()
  let source = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(Json::object({ "api_key": Json::string("k") })),
    provider_credential=Some(
      @oauth.ProviderCredential::OAuth({
        access_token: "t",
        refresh_token: "",
        expires_at: 0,
        token_type: "Bearer",
        metadata: Map::from_array([]),
      }),
    ),
  )
  try @llm.ProviderFactory::build(provider, source) catch {
    @posoco.CompositionError::ManifestSchemaError(manifest_id~, detail~) => {
      inspect(manifest_id, content="posoco_ext_zai")
      inspect(
        detail,
        content="z.ai has no OAuth; use an API key from z.ai/model-api",
      )
    }
    _ => fail("expected ManifestSchemaError")
  } noraise {
    _ => fail("expected failure")
  }
}

///|
test "factory: credential endpoint honors the platform marker" {
  debug_inspect(
    zai_credential_endpoint({
      secret: "k",
      metadata: Map::from_array([("platform", "bigmodel")]),
    }),
    content="Some((\"https://open.bigmodel.cn\", \"/api/paas/v4\"))",
  )
  debug_inspect(
    zai_credential_endpoint({ secret: "k", metadata: Map::from_array([]), }),
    content="None",
  )
}

///|
/// Scripted prompts for the two-step login: a platform choice, then the key.
/// Each request kind is logged so tests can assert the prompt order.
struct ScriptedPrompts {
  answers : Array[String]
  log : Array[String]
  mut index : Int
}

///|
fn ScriptedPrompts::ScriptedPrompts(answers : Array[String]) -> ScriptedPrompts {
  { answers, log: [], index: 0, }
}

///|
impl @oauth.AuthPromptInteraction for ScriptedPrompts with fn prompt(
  self : ScriptedPrompts,
  request : @oauth.AuthPromptRequest,
) -> String raise @oauth.OAuthError {
  match request {
    @oauth.AuthPromptRequest::Select(message~, ..) =>
      self.log.push("select: " + message)
    @oauth.AuthPromptRequest::Secret(message~) =>
      self.log.push("secret: " + message)
  }
  if self.index >= self.answers.length() {
    raise @oauth.OAuthError::Cancelled
  }
  let answer = self.answers[self.index]
  self.index += 1
  answer
}

///|
async test "login: platform choice then key, choice recorded" {
  let prompts = ScriptedPrompts::ScriptedPrompts(["bigmodel", "sk-test"])
  let interaction : &@oauth.AuthPromptInteraction = prompts
  let credential = @llm.ApiKeyFactory::login(ZaiProvider(), interaction)
  inspect(credential.secret, content="sk-test")
  inspect(
    credential.metadata.get("platform") is Some("bigmodel"),
    content="true",
  )
  debug_inspect(
    prompts.log,
    content=(
      #|[
      #|  "select: Connect to bigmodel or Z.ai?",
      #|  "secret: Z.ai API key for bigmodel",
      #|]
    ),
  )
}

///|
async test "login: unknown platform answer is a typed failure" {
  let prompts = ScriptedPrompts::ScriptedPrompts(["eu", "sk-test"])
  let interaction : &@oauth.AuthPromptInteraction = prompts
  try @llm.ApiKeyFactory::login(ZaiProvider(), interaction) catch {
    @oauth.OAuthError::ParseError(detail) =>
      inspect(detail, content="unknown platform choice: eu")
    _ => fail("expected ParseError")
  } noraise {
    _ => fail("expected failure")
  }
}

///|
async test "login: empty key is a typed failure" {
  let prompts = ScriptedPrompts::ScriptedPrompts(["zai", ""])
  let interaction : &@oauth.AuthPromptInteraction = prompts
  try @llm.ApiKeyFactory::login(ZaiProvider(), interaction) catch {
    @oauth.OAuthError::ParseError(detail) =>
      inspect(detail, content="Z.ai API key must not be empty")
    _ => fail("expected ParseError")
  } noraise {
    _ => fail("expected failure")
  }
}
