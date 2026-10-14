///|
/// catalog_wbtest.mbt — `/v1/models` decoding
/// (scenarios 5–8, 11–12: valid catalog, empty catalog, malformed payloads,
/// duplicates, missing context window, missing reasoning information).

///|
test "valid catalog decodes the documented fields and preserves raw" {
  let entry = model_entry(
    id="deepseek/deepseek-v4-pro",
    name="DeepSeek V4 Pro",
    fields="\"reasoning\":true,\"supported_reasoning_levels\":[{\"effort\":\"low\"},{\"effort\":\"high\"}],\"context_window\":163840,\"magpie_label\":\"DeepSeek V4 Pro · relay\",\"max_output_tokens\":8192,\"modalities\":{\"input\":[\"text\",\"image\"]},\"native_endpoints\":[\"/v1/messages\"]",
  )
  let report = decode_catalog(models_body(entry))
  inspect(report.duplicates.length(), content="0")
  inspect(report.entries.length(), content="1")
  let info = report.entries[0].info
  inspect(info.model_id, content="deepseek/deepseek-v4-pro")
  inspect(info.label, content="DeepSeek V4 Pro")
  inspect(info.provider_id, content="deepseek")
  debug_inspect(info.context_window, content="Some(163840)")
  debug_inspect(info.efforts, content="[\"low\", \"high\"]")
  debug_inspect(info.capabilities, content="[\"image\"]")
  // No invented defaults, no fabricated grouping.
  debug_inspect(info.default_effort, content="None")
  debug_inspect(info.display_group, content="None")
  // Raw Magpie-specific metadata stays attached, separate from the
  // neutral projection.
  guard report.entries[0].raw is Json::Object(raw) else {
    fail("raw entry lost")
  }
  guard raw.get("magpie_label") is Some(Json::String(label)) else {
    fail("raw magpie_label lost")
  }
  inspect(label, content="DeepSeek V4 Pro · relay")
  guard raw.get("native_endpoints") is Some(Json::Array(endpoints)) else {
    fail("raw native_endpoints lost")
  }
  inspect(endpoints.length(), content="1")
}

///|
test "catalog ordering is server order, deterministic" {
  let body = models_body(
    "\{model_entry(id="b/second")},\{model_entry(id="a/first")},\{model_entry(id="group/third")}",
  )
  let report = decode_catalog(body)
  debug_inspect(
    report.entries.map(fn(e) { e.info.model_id }),
    content="[\"b/second\", \"a/first\", \"group/third\"]",
  )
}

///|
test "empty catalog decodes to an empty report" {
  let report = decode_catalog("{\"data\":[]}")
  inspect(report.entries.length(), content="0")
  inspect(report.duplicates.length(), content="0")
}

///|
test "duplicate identifiers keep the first and report the rest" {
  let body = models_body(
    "\{model_entry(id="dup/model", name="First")},\{model_entry(id="dup/model", name="Second")},\{model_entry(id="dup/model", name="Third")}",
  )
  let report = decode_catalog(body)
  inspect(report.entries.length(), content="1")
  inspect(report.entries[0].info.label, content="First")
  debug_inspect(report.duplicates, content="[\"dup/model\", \"dup/model\"]")
}

///|
test "malformed catalog payloads are rejected, not repaired" {
  for
    body in [
      "not json", "[]", "{\"models\":[]}", "{\"data\":{}}", "{\"data\":[\"text\"]}",
      "{\"data\":[{}]}", "{\"data\":[{\"display_name\":\"x\",\"owned_by\":\"p\"}]}",
      "{\"data\":[{\"id\":\"\",\"display_name\":\"x\",\"owned_by\":\"p\"}]}", "{\"data\":[{\"id\":\"m\",\"owned_by\":\"p\"}]}",
      "{\"data\":[{\"id\":\"m\",\"display_name\":\"x\"}]}", "{\"data\":[{\"id\":7,\"display_name\":\"x\",\"owned_by\":\"p\"}]}",
      "{\"data\":[{\"id\":\"m\",\"display_name\":\"x\",\"owned_by\":\"p\",\"context_window\":\"big\"}]}",
      "{\"data\":[{\"id\":\"m\",\"display_name\":\"x\",\"owned_by\":\"p\",\"supported_reasoning_levels\":[{}]}]}",
      "{\"data\":[{\"id\":\"m\",\"display_name\":\"x\",\"owned_by\":\"p\",\"supported_reasoning_levels\":\"low\"}]}",
      "{\"data\":[{\"id\":\"m\",\"display_name\":\"x\",\"owned_by\":\"p\",\"modalities\":\"all\"}]}",
      "{\"data\":[{\"id\":\"m\",\"display_name\":\"x\",\"owned_by\":\"p\",\"modalities\":{\"input\":\"text\"}}]}",
      "{\"data\":[{\"id\":\"m\",\"display_name\":\"x\",\"owned_by\":\"p\",\"reasoning\":\"yes\"}]}",
    ] {
    try decode_catalog(body) catch {
      MagpieGatewayError::InvalidResponse(_) => ()
      _ => fail("expected InvalidResponse for \{body}")
    } noraise {
      _ => fail("expected InvalidResponse for \{body}")
    }
  }
}

///|
test "missing context window stays unknown" {
  let entry = model_entry(
    id="m/no-window",
    fields="\"reasoning\":false,\"supported_reasoning_levels\":[],\"modalities\":{\"input\":[\"text\"]}",
  )
  let report = decode_catalog(models_body(entry))
  debug_inspect(report.entries[0].info.context_window, content="None")
  debug_inspect(report.entries[0].info.efforts, content="[]")
  debug_inspect(report.entries[0].info.capabilities, content="[]")
}

///|
test "missing reasoning information advertises no efforts" {
  let entry = model_entry(id="m/no-reasoning", fields="\"context_window\":4096")
  let report = decode_catalog(models_body(entry))
  let info = report.entries[0].info
  debug_inspect(info.efforts, content="[]")
  debug_inspect(info.default_effort, content="None")
  debug_inspect(info.capabilities, content="[]")
  debug_inspect(info.context_window, content="Some(4096)")
}

///|
test "reasoning flag with empty levels advertises nothing" {
  let entry = model_entry(
    id="m/flag-only",
    fields="\"reasoning\":true,\"supported_reasoning_levels\":[],\"context_window\":4096",
  )
  let report = decode_catalog(models_body(entry))
  debug_inspect(report.entries[0].info.efforts, content="[]")
}

///|
test "routing-group and provider ids pass through as opaque keys" {
  let body = models_body(
    "\{model_entry(id="group/never-stuck", owned_by="codex")},\{model_entry(id="zai/glm-5.3", owned_by="zai")},\{model_entry(id="plain-name", owned_by="relay")}",
  )
  let report = decode_catalog(body)
  debug_inspect(
    report.entries.map(fn(e) { e.info.model_id }),
    content="[\"group/never-stuck\", \"zai/glm-5.3\", \"plain-name\"]",
  )
}
