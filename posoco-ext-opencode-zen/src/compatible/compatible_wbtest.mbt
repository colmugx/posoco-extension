///|
test "resolver isolates DeepSeek, GLM and standard OpenAI compatibility" {
  assert_eq(resolve("deepseek-v4.1-flash").id, "deepseek")
  assert_eq(resolve("glm-5.3-flash").id, "glm")
  assert_eq(resolve("kimi-k3").id, "standard")
  assert_eq(resolve("gpt-5.1").id, "standard")
  assert_eq(resolve("minimax-m3").id, "standard")
}

///|
test "standard OpenAI-compatible request never receives vendor thinking" {
  let body : Map[String, Json] = {}
  resolve("generic-chat").apply_request(body, false, None)
  assert_true(body.get("thinking") is None)
  assert_true(body.get("reasoning_effort") is None)
  resolve("generic-chat").apply_request(body, true, Some("low"))
  assert_true(body.get("thinking") is None)
  assert_eq(body["reasoning_effort"].stringify(), "\"low\"")
}

///|
test "DeepSeek thinking is explicit; its rules never apply to GLM" {
  let ds_body : Map[String, Json] = {}
  resolve("deepseek-r1").apply_request(ds_body, false, None)
  assert_eq(ds_body["thinking"].stringify(), "{\"type\":\"disabled\"}")
  let glm_body : Map[String, Json] = {}
  resolve("glm-5").apply_request(glm_body, false, None)
  assert_true(glm_body.get("thinking") is None)
}
