///|
/// `/status` live quota refresh for the OpenAI/Codex provider.
///
/// The regression composes the real provider factory, the real router
/// `/status` command, and the real codex status publisher: a build with a
/// Codex OAuth credential must publish a live usage source under the
/// provider id, `/status` must read it at command time, and the statusbar
/// segments must carry the same fresh values the report states.

///|
/// Distinctive percentages, so assertions cannot collide with the shared
/// tracker state other tests in this process capture.
fn live_status_usage_body() -> String {
  "{\"rate_limit\":{" +
  "\"primary_window\":{\"used_percent\":41.5,\"limit_window_seconds\":18000,\"reset_at\":1777936568}," +
  "\"secondary_window\":{\"used_percent\":87.5,\"limit_window_seconds\":604800,\"reset_after_seconds\":120}}" +
  "}"
}

///|
fn live_status_credential(token : String) -> @oauth.Credential {
  @oauth.Credential::Credential(
    access_token=token,
    refresh_token="refresh",
    expires_at=openai_now_epoch_secs() + 3600,
    metadata=Map([("account_id", "acct-live")]),
  )
}

///|
/// Recording transport for the command regression: captures every get and
/// flips to a rejected status to exercise failure preservation.
struct LiveUsageTransport {
  urls : Array[String]
  headers : Array[Map[String, String]]
  body : String
  mut failing : Bool
}

///|
impl OpenAIModelsHttpTransport for LiveUsageTransport with fn get(
  self : LiveUsageTransport,
  url : String,
  headers : Map[String, String],
) -> OpenAIModelsHttpResponse {
  self.urls.push(url)
  self.headers.push(headers)
  if self.failing {
    OpenAIModelsHttpResponse::{ status: 500, body: "rejected", }
  } else {
    OpenAIModelsHttpResponse::{ status: 200, body: self.body, }
  }
}

///|
fn LiveUsageTransport::usage_calls(self : LiveUsageTransport) -> Int {
  let mut count = 0
  for url in self.urls {
    if url.contains("/wham/usage") {
      count += 1
    }
  }
  count
}

///|
/// Build the provider through the real factory and compose the real router
/// over the resulting catalog — the host composition path.
fn live_status_router(
  transport : &OpenAIModelsHttpTransport,
  credential : @oauth.Credential,
  bus : @devkit.EventBus,
) -> @llm.RouterModelPort raise {
  let provider = OpenAIProvider(transport=Some(transport))
  let source = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(@json.parse("{\"model\":\"gpt-codex\"}")),
    provider_credential=Some(@oauth.ProviderCredential::OAuth(credential)),
  )
  match provider.build(source) {
    @llm.ProviderBuildResult::Ready(catalog) =>
      @llm.RouterModelPort::from_catalogs([catalog], bus=Some(bus))
    @llm.ProviderBuildResult::Unconfigured =>
      fail("OAuth source was configured")
  }
}

///|
fn live_status_compose(
  router : @llm.RouterModelPort,
  status : CodexQuotaStatus,
) -> Unit raise {
  let view = @posoco.tk_view(
    requires=[],
    model=@posoco.ScriptedModel([]) as &@posoco.ModelPort,
    ui=@posoco.NoopUiPort() as &@posoco.UiPort,
  )
  @posoco.Lifecycle::on_compose(status, view)
  @posoco.Lifecycle::on_compose(router, view)
}

///|
fn has_live_register(
  ops : Array[@devkit.StatusOp],
  segment~ : String,
  value~ : String,
) -> Bool {
  for op in ops {
    match op {
      @devkit.StatusOp::Register(segment=shown, value=stated, ..) =>
        if shown == segment && stated == Some(value) {
          return true
        }
      _ => ()
    }
  }
  false
}

///|
fn has_live_unregister(
  ops : Array[@devkit.StatusOp],
  segment~ : String,
) -> Bool {
  for op in ops {
    match op {
      @devkit.StatusOp::Unregister(segment=shown) =>
        if shown == segment {
          return true
        }
      _ => ()
    }
  }
  false
}

///|
/// The quota registry is process-global: clear the openai id at scenario
/// boundaries so a foreign build's registration (or this file's own) never
/// bleeds into another test's `/status` read.
fn live_status_registry_reset() -> Unit {
  @devkit.quota_registry_unregister("openai")
}

///|
async test "codex /status pulls live usage and the statusbar shows the same values" {
  live_status_registry_reset()
  let bus = @devkit.EventBus::EventBus()
  let recorder = QuotaBusRecorder::{ events: [], }
  bus.subscribe(recorder as &@devkit.BusSubscriber)
  let transport = LiveUsageTransport::{
    urls: [],
    headers: [],
    body: live_status_usage_body(),
    failing: false,
  }
  let borrowed : &OpenAIModelsHttpTransport = transport
  let router = live_status_router(
    borrowed,
    live_status_credential(codex_test_access_token()),
    bus,
  )
  let status = CodexQuotaStatus(bus=Some(bus))
  live_status_compose(router, status)
  // The build is offline: no usage probe ran yet.
  assert_eq(transport.usage_calls(), 0)
  let outcome = router.invoke("status", Json::null())
  match outcome {
    @posoco.CommandOutcome::Success(feedback~, structured~, ..) => {
      assert_true(feedback.contains("provider: openai"))
      assert_true(feedback.contains("5h: 58.5% left"))
      assert_true(feedback.contains("weekly: 12.5% left"))
      match structured {
        Some(Json::Object(fields)) =>
          match fields.get("quota") {
            Some(Json::Object(quota)) =>
              match quota.get("5h") {
                Some(Json::String("58.5% left")) => ()
                _ => fail("expected the live 5h value in structured status")
              }
            _ => fail("expected structured quota object")
          }
        _ => fail("expected structured status object")
      }
    }
    _ => fail("expected successful status report")
  }
  // The report came from a real usage probe, not the snapshot replay.
  assert_eq(transport.usage_calls(), 1)
  assert_eq(transport.urls[0], "https://chatgpt.com/backend-api/wham/usage")
  assert_eq(
    transport.headers[0].get("Authorization"),
    Some("Bearer " + codex_test_access_token()),
  )
  assert_eq(transport.headers[0].get("chatgpt-account-id"), Some("acct-live"))
  // The statusbar segments carry the same fresh values.
  let ops = codex_status_ops(recorder)
  assert_true(has_live_register(ops, segment="5h", value="58.5% left"))
  assert_true(has_live_register(ops, segment="weekly", value="12.5% left"))
  live_status_registry_reset()
}

///|
async test "repeated codex /status pulls live usage again" {
  live_status_registry_reset()
  let bus = @devkit.EventBus::EventBus()
  let recorder = QuotaBusRecorder::{ events: [], }
  bus.subscribe(recorder as &@devkit.BusSubscriber)
  let transport = LiveUsageTransport::{
    urls: [],
    headers: [],
    body: live_status_usage_body(),
    failing: false,
  }
  let borrowed : &OpenAIModelsHttpTransport = transport
  let router = live_status_router(
    borrowed,
    live_status_credential(codex_test_access_token()),
    bus,
  )
  let status = CodexQuotaStatus(bus=Some(bus))
  live_status_compose(router, status)
  ignore(router.invoke("status", Json::null()))
  assert_eq(transport.usage_calls(), 1)
  let outcome = router.invoke("status", Json::null())
  match outcome {
    @posoco.CommandOutcome::Success(feedback~, ..) => {
      assert_true(feedback.contains("5h: 58.5% left"))
      assert_true(feedback.contains("weekly: 12.5% left"))
    }
    _ => fail("expected successful status report")
  }
  assert_eq(transport.usage_calls(), 2)
  live_status_registry_reset()
}

///|
async test "failed codex usage pull preserves the published statusbar values" {
  live_status_registry_reset()
  let bus = @devkit.EventBus::EventBus()
  let recorder = QuotaBusRecorder::{ events: [], }
  bus.subscribe(recorder as &@devkit.BusSubscriber)
  let transport = LiveUsageTransport::{
    urls: [],
    headers: [],
    body: live_status_usage_body(),
    failing: false,
  }
  let borrowed : &OpenAIModelsHttpTransport = transport
  let router = live_status_router(
    borrowed,
    live_status_credential(codex_test_access_token()),
    bus,
  )
  let status = CodexQuotaStatus(bus=Some(bus))
  live_status_compose(router, status)
  ignore(router.invoke("status", Json::null()))
  let before = codex_shared_quota_tracker().snapshots()
  transport.failing = true
  let outcome = router.invoke("status", Json::null())
  match outcome {
    @posoco.CommandOutcome::Success(feedback~, ..) => {
      // A failed pull never retracts the values already on the bar.
      assert_true(feedback.contains("5h: 58.5% left"))
      assert_true(feedback.contains("weekly: 12.5% left"))
    }
    _ => fail("expected the status report to survive a failed pull")
  }
  assert_eq(transport.usage_calls(), 2)
  let ops = codex_status_ops(recorder)
  assert_false(has_live_unregister(ops, segment="5h"))
  assert_false(has_live_unregister(ops, segment="weekly"))
  // The failed pull never captured: the tracker keeps its snapshot.
  assert_true(codex_shared_quota_tracker().snapshots() == before)
  live_status_registry_reset()
}

///|
async test "api key build registers no live usage source" {
  live_status_registry_reset()
  let transport = LiveUsageTransport::{
    urls: [],
    headers: [],
    body: live_status_usage_body(),
    failing: false,
  }
  let borrowed : &OpenAIModelsHttpTransport = transport
  let provider = OpenAIProvider(transport=Some(borrowed))
  let credential = @oauth.ApiKeyCredential::ApiKeyCredential(secret="sk-test")
  let source = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(@json.parse("{\"model\":\"gpt-4o\"}")),
    provider_credential=Some(@oauth.ProviderCredential::ApiKey(credential)),
  )
  match provider.build(source) {
    @llm.ProviderBuildResult::Ready(_) => ()
    @llm.ProviderBuildResult::Unconfigured => fail("API key was configured")
  }
  // The wham/usage endpoint is OAuth-only: no registry source, no probe.
  assert_true(@devkit.quota_registry_lookup("openai") is None)
  assert_eq(transport.usage_calls(), 0)
}

///|
async test "rebuild with a renewed credential moves the live bearer token" {
  live_status_registry_reset()
  let bus = @devkit.EventBus::EventBus()
  let transport = LiveUsageTransport::{
    urls: [],
    headers: [],
    body: live_status_usage_body(),
    failing: false,
  }
  let borrowed : &OpenAIModelsHttpTransport = transport
  let router = live_status_router(
    borrowed,
    live_status_credential(codex_test_access_token()),
    bus,
  )
  ignore(router.invoke("status", Json::null()))
  assert_eq(transport.usage_calls(), 1)
  assert_eq(
    transport.headers[0].get("Authorization"),
    Some("Bearer " + codex_test_access_token()),
  )
  // The renewed credential flows through the same build path; the registry
  // holds the latest credential snapshot (last write wins).
  let renewed = live_status_router(
    borrowed,
    live_status_credential(codex_renewed_access_token()),
    bus,
  )
  let outcome = renewed.invoke("status", Json::null())
  match outcome {
    @posoco.CommandOutcome::Success(feedback~, ..) =>
      assert_true(feedback.contains("5h: 58.5% left"))
    _ => fail("expected successful status report")
  }
  assert_eq(transport.usage_calls(), 2)
  assert_eq(
    transport.headers[1].get("Authorization"),
    Some("Bearer " + codex_renewed_access_token()),
  )
  live_status_registry_reset()
}

///|
async test "provider switch reads only the active provider's live source" {
  live_status_registry_reset()
  let bus = @devkit.EventBus::EventBus()
  let transport = LiveUsageTransport::{
    urls: [],
    headers: [],
    body: live_status_usage_body(),
    failing: false,
  }
  let borrowed : &OpenAIModelsHttpTransport = transport
  // The host composes the provider first: its build publishes the live
  // source under the openai id.
  let credential = live_status_credential(codex_test_access_token())
  let provider = OpenAIProvider(transport=Some(borrowed))
  let config_source = @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(@json.parse("{\"model\":\"gpt-codex\"}")),
    provider_credential=Some(@oauth.ProviderCredential::OAuth(credential)),
  )
  match provider.build(config_source) {
    @llm.ProviderBuildResult::Ready(_) => ()
    @llm.ProviderBuildResult::Unconfigured =>
      fail("OAuth source was configured")
  }
  let other_slot = @llm.ModelSlot::ModelSlot(
    id="other-slot",
    label="Other",
    provider_id="other",
    model_id="other-model",
    port=@posoco.ScriptedModel([]) as &@posoco.ModelPort,
  )
  let codex_slot = @llm.ModelSlot::ModelSlot(
    id="codex-live",
    label="Codex",
    provider_id="openai",
    model_id="gpt-codex",
    port=@posoco.ScriptedModel([]) as &@posoco.ModelPort,
  )
  let router = @llm.RouterModelPort(
    slots=[other_slot, codex_slot],
    bus=Some(bus),
  )
  assert_eq(router.current_provider_id(), "other")
  let outcome = router.invoke("status", Json::null())
  match outcome {
    @posoco.CommandOutcome::Success(feedback~, ..) => {
      assert_true(feedback.contains("provider: other"))
      assert_true(feedback.contains("quota: no readings yet"))
    }
    _ => fail("expected successful status report")
  }
  assert_eq(transport.usage_calls(), 0)
  // Switching to the codex slot probes the live source immediately.
  ignore(router.invoke("model", Json::string("codex-live")))
  assert_eq(transport.usage_calls(), 1)
  live_status_registry_reset()
}
