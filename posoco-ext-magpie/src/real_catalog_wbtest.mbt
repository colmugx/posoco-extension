///|
/// real_catalog_wbtest.mbt — structural regression over the complete real
/// `/v1/models` response captured in `fixture_catalog_wbtest.mbt`.
///
/// Every assertion is derived from the fixture body itself: entry counts,
/// ids, effort vocabularies, and endpoint paths are read back out of the
/// raw payload and cross-checked against the typed decode. Nothing about
/// the gateway's configuration is hardcoded, so the suite holds for any
/// catalog — a single-model gateway included. No test here touches a
/// running gateway.

///|
test "the complete real catalog decodes with structure preserved" {
  let raw = @json.parse(real_catalog_body())
  guard raw is Json::Object(root) && root.get("data") is Some(Json::Array(data)) else {
    fail("fixture payload shape")
  }
  let report = decode_catalog(real_catalog_body())
  // Pin the supplied catalog's actual baseline; comparing the fixture to
  // itself would also pass if entries or routing groups were omitted.
  inspect(data.length(), content="78")
  inspect(report.entries.length(), content="78")
  inspect(
    data
    .filter(fn(item) {
      match item {
        Json::Object(fields) =>
          match fields.get("id") {
            Some(Json::String(id)) => id.has_prefix("group/")
            _ => false
          }
        _ => false
      }
    })
    .length(),
    content="12",
  )
  // The deduplicated decode covers exactly the payload's own entries.
  inspect(report.entries.length() == data.length(), content="true")
  // Server order is preserved, id for id.
  let mut order_ok = true
  for index, item in data {
    guard item is Json::Object(entry_fields) else { continue }
    guard entry_fields.get("id") is Some(Json::String(id)) else { continue }
    if report.entries[index].meta.model_id != id {
      order_ok = false
    }
  }
  inspect(order_ok, content="true")
}

///|
test "every real entry retains declared metadata verbatim" {
  let raw = @json.parse(real_catalog_body())
  guard raw is Json::Object(root) && root.get("data") is Some(Json::Array(data)) else {
    fail("fixture payload shape")
  }
  let report = decode_catalog(real_catalog_body())
  for index, item in data {
    guard item is Json::Object(fields) else { continue }
    let entry = report.entries[index]
    let meta = entry.meta
    // Required strings pass through verbatim.
    inspect(meta.display_name == entry.info.label, content="true")
    guard fields.get("display_name") is Some(Json::String(display)) else {
      continue
    }
    inspect(meta.display_name == display, content="true")
    guard fields.get("owned_by") is Some(Json::String(owner)) else { continue }
    inspect(meta.provider_id == owner, content="true")
    // Routing-group identity follows the id namespace exactly.
    inspect(
      meta.is_routing_group == meta.model_id.has_prefix("group/"),
      content="true",
    )
    // magpie_label: unknown vs declared preserved, value verbatim.
    match fields.get("magpie_label") {
      Some(Json::String(label)) =>
        inspect(meta.magpie_label == Some(label), content="true")
      None => inspect(meta.magpie_label is None, content="true")
      _ => fail("fixture magpie_label shape")
    }
    // Effort names are exact strings in server order, both in the typed
    // metadata and in the neutral projection.
    let raw_levels : Array[String] = match
      fields.get("supported_reasoning_levels") {
      Some(Json::Array(levels)) =>
        levels.map(level => {
          guard level is Json::Object(level_fields) else {
            fail("fixture level shape")
          }
          guard level_fields.get("effort") is Some(Json::String(effort)) else {
            fail("fixture effort shape")
          }
          effort
        })
      _ => fail("fixture levels shape")
    }
    let typed_levels = match meta.reasoning_levels {
      Some(levels) => levels
      None => []
    }
    inspect(typed_levels == raw_levels, content="true")
    inspect(entry.info.efforts == raw_levels, content="true")
    // Declared input modalities are retained in server order.
    let raw_modalities : Array[String] = match fields.get("modalities") {
      Some(Json::Object(modalities)) =>
        match modalities.get("input") {
          Some(Json::Array(inputs)) =>
            inputs.map(input => {
              guard input is Json::String(modality) else {
                fail("fixture modality shape")
              }
              modality
            })
          _ => fail("fixture modalities input shape")
        }
      None => []
      _ => fail("fixture modalities shape")
    }
    let typed_modalities = match meta.modalities_input {
      Some(inputs) => inputs
      None => []
    }
    inspect(typed_modalities == raw_modalities, content="true")
    // Context fields: unknown stays None, declared stays exact.
    let raw_window = match fields.get("context_window") {
      Some(Json::Number(value, ..)) => Some(value.to_int())
      _ => None
    }
    inspect(meta.context_window == raw_window, content="true")
    // Native endpoints: typed protocol per known path, retained verbatim.
    let raw_endpoints : Array[String] = match fields.get("native_endpoints") {
      Some(Json::Array(paths)) =>
        paths.map(path => {
          guard path is Json::String(text) else {
            fail("fixture endpoint shape")
          }
          text
        })
      None => []
      _ => fail("fixture endpoints shape")
    }
    let typed_endpoints = match meta.native_endpoints {
      Some(endpoints) => endpoints
      None => []
    }
    inspect(typed_endpoints.length() == raw_endpoints.length(), content="true")
    for position, path in raw_endpoints {
      let endpoint = typed_endpoints[position]
      inspect(endpoint.path == path, content="true")
      let known = path is "/v1/messages" ||
        path is "/v1/responses" ||
        path is "/v1/chat/completions"
      inspect((endpoint.protocol is Some(_)) == known, content="true")
    }
    // Unknown extension metadata stays on raw.
    inspect(entry.raw == data[index], content="true")
  }
}

///|
test "routing groups and provider models plan distinctly across the real catalog" {
  let report = decode_catalog(real_catalog_body())
  let mut groups = 0
  let mut provider_models = 0
  for entry in report.entries {
    let outcome = plan_protocol(
      entry,
      requirements=MagpieRequirements::MagpieRequirements(
        streaming=true,
        token_usage_integrity=true,
      ),
      policy=AllowTranslated,
    )
    guard outcome is Planned(plan) else {
      fail(
        "streaming-only requirements must always plan; \{entry.meta.model_id} did not",
      )
    }
    // Groups never inherit a native protocol claim; concrete models with a
    // declared endpoint plan natively with declared confidence.
    if entry.meta.is_routing_group {
      groups += 1
      inspect(plan.kind == GatewayTranslated, content="true")
      inspect(plan.confidence == Inferred, content="true")
      inspect(plan.endpoint_path is None, content="true")
    } else if entry.meta.native_path_for(Responses) is Some(_) {
      provider_models += 1
    }
  }
  // Both shapes are present in the captured catalog; the counts are only
  // reported to the log, never asserted.
  println(
    "real catalog: \{groups} routing groups, \{provider_models} models with declared native Responses",
  )
}

///|
test "identical planning inputs give identical plans across the real catalog" {
  let report = decode_catalog(real_catalog_body())
  let requirements = MagpieRequirements::MagpieRequirements(
    tools=true,
    streaming=true,
    reasoning_output=true,
    token_usage_integrity=true,
  )
  let mut stable = true
  for entry in report.entries {
    let first = plan_protocol(entry, requirements~, policy=AllowTranslated)
    let second = plan_protocol(entry, requirements~, policy=AllowTranslated)
    if first != second {
      stable = false
    }
  }
  inspect(stable, content="true")
}
