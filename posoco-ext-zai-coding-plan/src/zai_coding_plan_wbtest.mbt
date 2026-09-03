///|
fn zcp_settings(pairs : Array[(String, Json)]) -> @llm.ProviderConfigSource {
  @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(Json::object(Map::from_array(pairs))),
  )
}

///|
test "profile endpoints" {
  debug_inspect(
    zai_coding_plan_profile_endpoint("coding"),
    content="Some((\"https://api.z.ai\", \"/api/coding/paas/v4\"))",
  )
  debug_inspect(
    zai_coding_plan_profile_endpoint("cn_coding"),
    content="Some((\"https://open.bigmodel.cn\", \"/api/coding/paas/v4\"))",
  )
  debug_inspect(zai_coding_plan_profile_endpoint("general"), content="None")
}

///|
test "factory: unconfigured without a key" {
  let provider = ZaiCodingPlanProvider()
  let result = @llm.ProviderFactory::build(provider, zcp_settings([]))
  inspect(result is @llm.ProviderBuildResult::Unconfigured, content="true")
}

///|
test "factory: ready catalog with coding-plan default endpoint" {
  let provider = ZaiCodingPlanProvider()
  let result = @llm.ProviderFactory::build(
    provider,
    zcp_settings([
      ("api_key", Json::string("k")),
      ("model", Json::string("glm-5.3-flash")),
    ]),
  )
  guard result is @llm.ProviderBuildResult::Ready(catalog) else {
    fail("expected Ready")
  }
  inspect(catalog.provider_id, content="zai-coding-plan")
  inspect(catalog.slots.length(), content="4")
  inspect(catalog.slots[0].model_id, content="glm-5.3-flash")
  inspect(catalog.slots[0].id, content="zai-coding-plan/glm-5.3-flash")
  inspect(catalog.slots[0].label, content="Z.ai Coding Plan / glm-5.3-flash")
  assert_true(catalog.capabilities.contains("coding_plan"))
  let config = zai_coding_plan_build_config(
    zcp_settings([("api_key", Json::string("k"))]),
  )
  guard config is Some(value) else { fail("expected config") }
  inspect(value.base_url, content="https://api.z.ai")
  inspect(value.endpoint_prefix, content="/api/coding/paas/v4")
}

///|
test "factory: cn_coding profile selects bigmodel" {
  let config = zai_coding_plan_build_config(
    zcp_settings([
      ("api_key", Json::string("k")),
      ("profile", Json::string("cn_coding")),
    ]),
  )
  guard config is Some(value) else { fail("expected config") }
  inspect(value.base_url, content="https://open.bigmodel.cn")
  inspect(value.endpoint_prefix, content="/api/coding/paas/v4")
}

///|
test "factory: OAuth credential is a typed failure" {
  let provider = ZaiCodingPlanProvider()
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
      inspect(manifest_id, content="posoco_ext_zai_coding_plan")
      inspect(
        detail,
        content="the GLM Coding Plan has no OAuth; use a coding-plan API key",
      )
    }
    _ => fail("expected ManifestSchemaError")
  } noraise {
    _ => fail("expected failure")
  }
}

///|
test "factory: unknown profile is a typed failure" {
  try
    zai_coding_plan_build_config(
      zcp_settings([
        ("api_key", Json::string("k")),
        ("profile", Json::string("eu")),
      ]),
    )
  catch {
    @posoco.CompositionError::ManifestSchemaError(detail~, ..) =>
      inspect(
        detail,
        content="unknown profile: eu (expected coding | cn_coding)",
      )
    _ => fail("expected ManifestSchemaError")
  } noraise {
    _ => fail("expected failure")
  }
}

///|
test "factory: unknown effort names the coding-plan manifest" {
  try
    zai_coding_plan_build_config(
      zcp_settings([
        ("api_key", Json::string("k")),
        ("reasoning_effort", Json::string("ultra")),
      ]),
    )
  catch {
    @posoco.CompositionError::ManifestSchemaError(manifest_id~, detail~) => {
      inspect(manifest_id, content="posoco_ext_zai_coding_plan")
      inspect(detail, content="unsupported reasoning effort: ultra")
    }
    _ => fail("expected ManifestSchemaError")
  } noraise {
    _ => fail("expected failure")
  }
}

///|
test "manifest: coding-plan extension identity" {
  let config = @zai.ZaiConfig::for_model(
    "k",
    "glm-5.3",
    base_url="https://api.z.ai",
    endpoint_prefix="/api/coding/paas/v4",
  )
  let port = ZaiCodingPlanModelPort(config)
  inspect(port.extension_id(), content="posoco_ext_zai_coding_plan")
  inspect(port.manifest().id, content="posoco_ext_zai_coding_plan")
}

///|
/// Scripted single-secret login prompts; requests are logged so tests can
/// assert that no platform picker is shown.
struct ZcpPrompts {
  answers : Array[String]
  log : Array[String]
  mut index : Int
}

///|
fn ZcpPrompts::ZcpPrompts(answers : Array[String]) -> ZcpPrompts {
  { answers, log: [], index: 0, }
}

///|
impl @oauth.AuthPromptInteraction for ZcpPrompts with fn prompt(
  self : ZcpPrompts,
  request : @oauth.AuthPromptRequest,
) -> String raise @oauth.OAuthError {
  match request {
    @oauth.AuthPromptRequest::Select(..) => self.log.push("select")
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
async test "login: collects the plan key without a platform picker" {
  let prompts = ZcpPrompts::ZcpPrompts(["sk-plan"])
  let interaction : &@oauth.AuthPromptInteraction = prompts
  let credential = @llm.ApiKeyFactory::login(
    ZaiCodingPlanProvider(),
    interaction,
  )
  inspect(credential.secret, content="sk-plan")
  debug_inspect(
    prompts.log,
    content=(
      #|["secret: GLM Coding Plan API key"]
    ),
  )
}

///|
async test "login: empty key is a typed failure" {
  let prompts = ZcpPrompts::ZcpPrompts([""])
  let interaction : &@oauth.AuthPromptInteraction = prompts
  try @llm.ApiKeyFactory::login(ZaiCodingPlanProvider(), interaction) catch {
    @oauth.OAuthError::ParseError(detail) =>
      inspect(detail, content="GLM Coding Plan API key must not be empty")
    _ => fail("expected ParseError")
  } noraise {
    _ => fail("expected failure")
  }
}
