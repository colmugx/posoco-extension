///|
/// planning_wbtest.mbt — deterministic, offline protocol-planning cases.
///
/// Every case decodes a synthetic catalog entry through the same public
/// decoder the manager uses, then plans through the public planning API.
/// Nothing here (or anywhere in the suite) touches a running gateway.

///|
/// Decodes one synthetic entry through the public catalog decoder.
fn entry_of(model : String) -> MagpieCatalogEntry raise {
  let report = decode_catalog(models_body(model))
  guard report.entries is [entry, ..] else { fail("entry fixture") }
  copy_entry(entry)
}

///|
/// A well-formed provider model advertising exactly the given native
/// endpoints (reasoning with the full xhigh ladder, image input).
fn protocol_model(endpoints : Array[String]) -> String {
  let declared = endpoints.map(fn(path) { "\"\{path}\"" }).join(",")
  model_entry(
    id="codex/gpt-6.1-sol",
    fields="\"reasoning\":true,\"supported_reasoning_levels\":[{\"effort\":\"low\"},{\"effort\":\"high\"}],\"context_window\":922000,\"max_input_tokens\":922000,\"max_output_tokens\":128000,\"magpie_label\":\"GPT-6.1-Sol · Codex\",\"native_endpoints\":[\{declared}],\"modalities\":{\"input\":[\"text\",\"image\"]}",
  )
}

///|
let no_requirements : MagpieRequirements = MagpieRequirements::MagpieRequirements()

///|
test "responses-only models plan natively and refuse signed-thinking guarantees" {
  let entry = entry_of(protocol_model(["/v1/responses"]))
  inspect(
    entry.meta.native_path_for(Responses) == Some("/v1/responses"),
    content="true",
  )
  inspect(entry.meta.native_path_for(Messages) is None, content="true")
  // Preference honored on the declared-native protocol.
  let planned = plan_protocol(
    entry,
    requirements=no_requirements,
    preference=Prefer(Responses),
  )
  guard planned is Planned(plan) else { fail("expected a plan") }
  inspect(plan.protocol, content="Responses")
  inspect(plan.endpoint_path == Some("/v1/responses"), content="true")
  inspect(plan.kind, content="Native")
  inspect(plan.confidence, content="DeclaredNative")
  // Signed thinking cannot be guaranteed without native Messages.
  let thinking = MagpieRequirements::MagpieRequirements(
    signed_thinking_replay=true,
  )
  guard plan_protocol(entry, requirements=thinking) is Incompatible(blocked) else {
    fail("expected incompatibility")
  }
  inspect(blocked.model_id, content="codex/gpt-6.1-sol")
  inspect(blocked.blockers.length(), content="3")
  inspect(blocked.policy, content="NativeOnly")
}

///|
test "messages-only models carry signed thinking natively" {
  let entry = entry_of(protocol_model(["/v1/messages"]))
  let thinking = MagpieRequirements::MagpieRequirements(
    signed_thinking_replay=true,
  )
  guard plan_protocol(entry, requirements=thinking) is Planned(plan) else {
    fail("expected a plan")
  }
  inspect(plan.protocol, content="Messages")
  inspect(plan.endpoint_path == Some("/v1/messages"), content="true")
  inspect(plan.kind, content="Native")
  inspect(plan.confidence, content="DeclaredNative")
  guard find_first(plan.capabilities.iter(), fn(capability) {
      capability.feature is SignedThinkingReplay
    })
    is Some(replay) else {
    fail("capability matrix must cover signed thinking")
  }
  inspect(replay.status, content="Available")
  inspect(replay.source, content="ProtocolNative")
}

///|
test "native prompt caching overrides protocol preference" {
  let entry = entry_of(protocol_model(["/v1/messages", "/v1/chat/completions"]))
  let caching = MagpieRequirements::MagpieRequirements(
    native_prompt_caching=true,
  )
  guard plan_protocol(
      entry,
      requirements=caching,
      preference=Prefer(ChatCompletions),
    )
    is Planned(plan) else {
    fail("expected a plan")
  }
  // Cache fidelity outranks the caller preference.
  inspect(plan.protocol, content="Messages")
  inspect(
    plan.reasons
    .iter()
    .any(fn(reason) { reason.contains("native Messages is preferred") }),
    content="true",
  )
  guard find_first(plan.capabilities.iter(), fn(capability) {
      capability.feature is NativePromptCaching
    })
    is Some(caching_capability) else {
    fail("capability matrix must cover prompt caching")
  }
  inspect(caching_capability.source, content="ProtocolNative")
  inspect(caching_capability.detail.contains("stable prefix"), content="true")
}

///|
test "chat-only models translate only when the policy allows it" {
  let entry = entry_of(protocol_model(["/v1/chat/completions"]))
  let streaming_tools = MagpieRequirements::MagpieRequirements(
    tools=true,
    streaming=true,
  )
  guard plan_protocol(
      entry,
      requirements=streaming_tools,
      policy=AllowTranslated,
      preference=Prefer(Responses),
    )
    is Planned(plan) else {
    fail("expected a plan")
  }
  // The preference wins even when it means translated execution.
  inspect(plan.protocol, content="Responses")
  inspect(plan.kind, content="GatewayTranslated")
  // Without a preference, the declared-native chat endpoint outranks
  // translated alternatives.
  guard plan_protocol(entry, requirements=streaming_tools)
    is Planned(native_plan) else {
    fail("expected a plan")
  }
  inspect(native_plan.protocol, content="ChatCompletions")
  inspect(native_plan.kind, content="Native")
  // A signed-thinking requirement cannot be guaranteed: rejected under
  // NativeOnly, planned lossily under AllowTranslated.
  let thinking = MagpieRequirements::MagpieRequirements(
    signed_thinking_replay=true,
  )
  guard plan_protocol(entry, requirements=thinking) is Incompatible(_) else {
    fail("NativeOnly must refuse unguaranteed signed thinking")
  }
  // With no preference, the declared-native chat endpoint wins; the
  // signed-thinking capability is honestly Unknown there.
  guard plan_protocol(entry, requirements=thinking, policy=AllowTranslated)
    is Planned(native_pick) else {
    fail("AllowTranslated must plan with risks visible")
  }
  inspect(native_pick.protocol, content="ChatCompletions")
  inspect(native_pick.kind, content="Native")
  inspect(native_pick.lossy_opt_in, content="false")
  guard find_first(native_pick.capabilities.iter(), fn(capability) {
      capability.feature is SignedThinkingReplay
    })
    is Some(unknown_thinking) else {
    fail("capability matrix must cover signed thinking")
  }
  inspect(unknown_thinking.source, content="Unknown")
  // Forcing the Messages preference yields the lossy translated plan.
  guard plan_protocol(
      entry,
      requirements=thinking,
      policy=AllowTranslated,
      preference=Prefer(Messages),
    )
    is Planned(lossy) else {
    fail("the explicit Messages preference must plan")
  }
  inspect(lossy.protocol, content="Messages")
  inspect(lossy.kind, content="GatewayTranslated")
  inspect(lossy.confidence, content="Inferred")
  inspect(lossy.lossy_opt_in, content="true")
  inspect(
    lossy.risks
    .iter()
    .any(fn(risk) { risk.contains("may not preserve thinking signatures") }),
    content="true",
  )
  inspect(
    lossy.risks
    .iter()
    .any(fn(risk) { risk.contains("explicitly accepted lossy translation") }),
    content="true",
  )
}

///|
test "models advertising multiple native endpoints plan each independently" {
  let entry = entry_of(
    protocol_model(["/v1/chat/completions", "/v1/responses", "/v1/messages"]),
  )
  inspect(entry.meta.native_endpoints.unwrap().length(), content="3")
  for protocol in [Messages, Responses, ChatCompletions] {
    guard entry.meta.native_path_for(protocol) is Some(_) else {
      fail("all three endpoints must be typed")
    }
  }
  // Preference decides when no cache fidelity is required.
  for protocol in [Messages, Responses, ChatCompletions] {
    guard plan_protocol(
        entry,
        requirements=no_requirements,
        preference=Prefer(protocol),
      )
      is Planned(plan) else {
      fail("expected a plan")
    }
    inspect(plan.protocol == protocol, content="true")
    inspect(plan.kind, content="Native")
  }
}

///|
test "missing endpoint metadata is unknown, never a prohibition" {
  let entry = entry_of(
    model_entry(
      id="opencode-zen-free/big-pickle",
      fields="\"reasoning\":true,\"supported_reasoning_levels\":[],\"context_window\":262144,\"modalities\":{\"input\":[\"text\"]}",
    ),
  )
  inspect(entry.meta.native_endpoints is None, content="true")
  // With nothing required, the model plans at gateway level.
  guard plan_protocol(
      entry,
      requirements=no_requirements,
      policy=AllowTranslated,
    )
    is Planned(plan) else {
    fail("expected a plan")
  }
  inspect(plan.kind, content="GatewayTranslated")
  inspect(plan.confidence, content="Inferred")
  inspect(
    plan.risks
    .iter()
    .any(fn(risk) { risk.contains("unknown, not a prohibition") }),
    content="true",
  )
  // NativeOnly demands declarations it does not have: explicit, not silent.
  guard plan_protocol(entry, requirements=no_requirements)
    is Incompatible(blocked) else {
    fail("NativeOnly must be explicit about undeclared endpoints")
  }
  inspect(
    blocked.blockers
    .iter()
    .all(fn(blocker) {
      blocker.reasons
      .iter()
      .any(fn(reason) { reason.contains("no declared native endpoint") })
    }),
    content="true",
  )
}

///|
test "reasoning without advertised effort stays a risk, not a prohibition" {
  let entry = entry_of(
    model_entry(
      id="group/auto-muse-spark-1-3-contributor-free",
      owned_by="our-free-model",
      fields="\"reasoning\":true,\"supported_reasoning_levels\":[],\"context_window\":1048576,\"modalities\":{\"input\":[\"text\"]}",
    ),
  )
  let requirements = MagpieRequirements::MagpieRequirements(
    reasoning_output=true,
  )
  guard plan_protocol(entry, requirements~, policy=AllowTranslated)
    is Planned(_) else {
    fail("reasoning output alone must plan")
  }
  // Requesting an effort the model does not advertise is a declared mismatch.
  let with_effort = MagpieRequirements::MagpieRequirements(
    reasoning_output=true,
    reasoning_effort=Some("high"),
  )
  guard plan_protocol(entry, requirements=with_effort) is Incompatible(blocked) else {
    fail("declared-empty levels must reject the requested effort")
  }
  inspect(
    blocked.blockers
    .iter()
    .any(fn(blocker) {
      blocker.reasons
      .iter()
      .any(fn(reason) { reason.contains("not in the advertised levels") })
    }),
    content="true",
  )
}

///|
test "effort names are exact strings, nonstandard included" {
  let entry = entry_of(
    model_entry(
      id="our-free-model/auto-mimo-v2-6-flash-free",
      owned_by="our-free-model",
      fields="\"reasoning\":true,\"supported_reasoning_levels\":[{\"effort\":\"light\"},{\"effort\":\"balanced\"},{\"effort\":\"deep\"}],\"context_window\":1048576,\"modalities\":{\"input\":[\"text\"]}",
    ),
  )
  inspect(
    entry.meta.reasoning_levels == Some(["light", "balanced", "deep"]),
    content="true",
  )
  guard plan_protocol(
      entry,
      requirements=MagpieRequirements::MagpieRequirements(
        reasoning_effort=Some("deep"),
      ),
      policy=AllowTranslated,
    )
    is Planned(plan) else {
    fail("a nonstandard but advertised effort must plan")
  }
  guard find_first(plan.capabilities.iter(), fn(capability) {
      capability.feature is ReasoningEffort
    })
    is Some(effort) else {
    fail("capability matrix must cover effort")
  }
  inspect(effort.status, content="Available")
  inspect(effort.source, content="CatalogDeclared")
  // The full ladder is untouched by planning.
  inspect(entry.info.efforts == ["light", "balanced", "deep"], content="true")
}

///|
test "text-only models reject image requirements; image models carry them" {
  let text_only = entry_of(
    model_entry(
      id="relay/text-only",
      fields="\"reasoning\":false,\"supported_reasoning_levels\":[],\"context_window\":32768,\"modalities\":{\"input\":[\"text\"]}",
    ),
  )
  let images = MagpieRequirements::MagpieRequirements(images=true)
  guard plan_protocol(text_only, requirements=images) is Incompatible(blocked) else {
    fail("text-only must reject images explicitly")
  }
  inspect(
    blocked.blockers
    .iter()
    .all(fn(blocker) {
      blocker.reasons
      .iter()
      .any(fn(reason) { reason.contains("text-only input") })
    }),
    content="true",
  )
  // No policy repairs declared facts.
  guard plan_protocol(text_only, requirements=images, policy=AllowTranslated)
    is Incompatible(_) else {
    fail("translation cannot add image input")
  }
  let image_capable = entry_of(protocol_model(["/v1/responses"]))
  guard plan_protocol(image_capable, requirements=images) is Planned(plan) else {
    fail("image-capable models must plan")
  }
  guard find_first(plan.capabilities.iter(), fn(capability) {
      capability.feature is Images
    })
    is Some(image_capability) else {
    fail("capability matrix must cover images")
  }
  inspect(image_capability.status, content="Available")
  inspect(image_capability.source, content="CatalogDeclared")
}

///|
test "unknown input context is reported, not guessed" {
  let entry = entry_of(
    model_entry(
      id="copilot/kimi-k3-base",
      owned_by="copilot",
      fields="\"reasoning\":true,\"supported_reasoning_levels\":[{\"effort\":\"low\"},{\"effort\":\"high\"},{\"effort\":\"max\"}],\"native_endpoints\":[\"/v1/chat/completions\"]",
    ),
  )
  inspect(entry.meta.context_window is None, content="true")
  inspect(entry.meta.context_length is None, content="true")
  inspect(entry.meta.max_input_tokens is None, content="true")
  inspect(entry.meta.modalities_input is None, content="true")
  guard plan_protocol(
      entry,
      requirements=MagpieRequirements::MagpieRequirements(
        tools=true,
        streaming=true,
      ),
      policy=AllowTranslated,
    )
    is Planned(plan) else {
    fail("unknown context must not block planning")
  }
  inspect(
    plan.risks
    .iter()
    .any(fn(risk) { risk.contains("input context size is unknown") }),
    content="true",
  )
}

///|
async test "catalog refresh changing protocol metadata changes the plan" {
  let responses_only = models_body(protocol_model(["/v1/responses"]))
  let with_messages = models_body(
    protocol_model(["/v1/responses", "/v1/messages"]),
  )
  let manager = manager_with(
    transport=FakeTransport([
      Respond(code=200, body=hello_body()),
      Respond(code=200, body=responses_only),
      Respond(code=200, body=hello_body()),
      Respond(code=200, body=with_messages),
    ]),
    config=local_config(),
  )
  refresh_ok(manager)
  let thinking = MagpieRequirements::MagpieRequirements(
    signed_thinking_replay=true,
  )
  let entry_before = manager.catalog_entry("codex/gpt-6.1-sol").unwrap()
  guard plan_protocol(entry_before, requirements=thinking) is Incompatible(_) else {
    fail("responses-only cannot guarantee signed thinking")
  }
  // The gateway now declares native Messages for the same id.
  refresh_ok(manager)
  let entry_after = manager.catalog_entry("codex/gpt-6.1-sol").unwrap()
  guard plan_protocol(entry_after, requirements=thinking) is Planned(plan) else {
    fail("declared native Messages must plan")
  }
  inspect(plan.protocol, content="Messages")
  inspect(plan.kind, content="Native")
  // The refresh changed protocol metadata, not the selection registry:
  // the manager's neutral control surface is untouched.
  inspect(manager.active_selection().model_id, content="")
}

///|
test "identical inputs produce identical plans" {
  let entry = entry_of(protocol_model(["/v1/chat/completions", "/v1/messages"]))
  let requirements = MagpieRequirements::MagpieRequirements(
    tools=true,
    streaming=true,
    images=true,
    reasoning_output=true,
    reasoning_effort=Some("high"),
    token_usage_integrity=true,
    cancellation=true,
  )
  let first = plan_protocol(
    entry,
    requirements~,
    preference=Prefer(Responses),
    policy=AllowTranslated,
  )
  let second = plan_protocol(
    entry,
    requirements~,
    preference=Prefer(Responses),
    policy=AllowTranslated,
  )
  inspect(first == second, content="true")
}

///|
test "the requested-feature matrix is fixed-order and complete" {
  let entry = entry_of(protocol_model(["/v1/messages"]))
  let requirements = MagpieRequirements::MagpieRequirements(
    cancellation=true,
    token_usage_integrity=true,
    native_prompt_caching=true,
    reasoning_effort=Some("high"),
    signed_thinking_replay=true,
    reasoning_output=true,
    images=true,
    streaming=true,
    tools=true,
  )
  guard plan_protocol(entry, requirements~) is Planned(plan) else {
    fail("expected a plan")
  }
  inspect(
    plan.capabilities
    .map(fn(capability) { capability.feature.to_string() })
    .join(" | "),
    content=(
      #|tools | streaming | images | reasoning output | signed thinking replay | reasoning effort | native prompt caching | token usage integrity | cancellation
    ),
  )
  // Every requested feature is available on this fully-capable entry.
  inspect(
    plan.capabilities
    .iter()
    .all(fn(capability) { capability.status is Available }),
    content="true",
  )
}

///|
test "routing groups are delegated without weakening native model policy" {
  let group = entry_of(
    model_entry(
      id="group/deepseek-v4.1-flash",
      owned_by="deepseek",
      fields="\"reasoning\":true,\"context_window\":262144,\"modalities\":{\"input\":[\"text\"]}",
    ),
  )
  let requirements = MagpieRequirements::MagpieRequirements(
    tools=true,
    streaming=true,
    cancellation=true,
  )
  guard plan_protocol(group, requirements~) is Incompatible(_) else {
    fail("an explicitly native-only request must reject dynamic routing")
  }
  guard plan_protocol(group, requirements~, policy=AllowGatewayGroups)
    is Planned(plan) else {
    fail("group must be dispatched through the gateway")
  }
  inspect(plan.model_id, content="group/deepseek-v4.1-flash")
  inspect(plan.kind, content="GatewayTranslated")
  inspect(plan.endpoint_path is None, content="true")
  inspect(plan.lossy_opt_in, content="false")
  let strict_model = entry_of(
    model_entry(id="relay/no-native-endpoint", owned_by="relay"),
  )
  guard plan_protocol(strict_model, requirements~, policy=AllowGatewayGroups)
    is Incompatible(_) else {
    fail("gateway-group policy must not loosen concrete-model selection")
  }
}

///|
test "routing groups cannot claim upstream-native fidelity" {
  let group = entry_of(
    model_entry(
      id="group/deepseek-v4.1-flash",
      owned_by="deepseek",
      fields="\"reasoning\":true,\"modalities\":{\"input\":[\"text\"]}",
    ),
  )
  for
    requirements in [
      MagpieRequirements::MagpieRequirements(signed_thinking_replay=true),
      MagpieRequirements::MagpieRequirements(native_prompt_caching=true),
    ] {
    guard plan_protocol(group, requirements~, policy=AllowGatewayGroups)
      is Incompatible(_) else {
      fail("routing-group execution must not promise native-only fidelity")
    }
  }
}
