///|
fn cache_body() -> Json {
  {
    "model": "m",
    "max_tokens": 2048,
    "tools": [{ "name": "read", "description": "read", "input_schema": {} }],
    "system": [{ "type": "text", "text": "stable system" }],
    "messages": [{ "role": "user", "content": [{ "type": "text", "text": "hello" }] }],
  }
}

///|
test "automatic Messages cache uses top-level cache_control" {
  let body = cache_body()
  let cached = apply_messages_cache_policy(body, CacheAutomatic5m)
  assert_eq(jget(jget(cached, key="cache_control"), key="type"), "ephemeral")
  let again = apply_messages_cache_policy(body, CacheAutomatic1h)
  assert_eq(jget(jget(again, key="cache_control"), key="ttl"), "1h")
  assert_eq(body.value("cache_control"), None)
}

///|
test "cache gateway capability mismatch fails loudly" {
  let bad = Ok(apply_messages_cache_policy(
    cache_body(),
    CacheAutomatic5m,
    capabilities={ automatic: false, one_hour: false },
  )) catch { error => Err(error) }
  match bad {
    Err(@posoco.ModelError::RequestBuild(message)) =>
      assert_true(message.contains("capability"))
    _ => fail("expected unsupported cache capability")
  }
}

///|
test "messages cache prefix compares stable tools system and append-only history" {
  let first = cache_body()
  let second : Json = {
    "model": "m",
    "max_tokens": 2048,
    "tools": [{ "name": "read", "description": "read", "input_schema": {} }],
    "system": [{ "type": "text", "text": "stable system" }],
    "messages": [
      { "role": "user", "content": [{ "type": "text", "text": "hello" }] },
      { "role": "assistant", "content": [{ "type": "text", "text": "hi" }] },
    ],
  }
  let check = compare_messages_cache_prefix(first, second)
  assert_true(check.model_stable)
  assert_true(check.tools_stable)
  assert_true(check.system_stable)
  assert_true(check.history_is_prefix)
  assert_eq(check.suffix_message_count, 1)
}

///|
test "cache economics prices actual native 5m writes and hits" {
  let usage : MessagesUsage = {
    input_tokens: 100,
    output_tokens: 10,
    cache_creation_input_tokens: Some(200),
    cache_read_input_tokens: Some(700),
  }
  let creation : MessagesCacheCreation = {
    ephemeral_5m_input_tokens: Some(200),
    ephemeral_1h_input_tokens: Some(0),
  }
  let result = analyze_messages_cache_economics(
    usage,
    creation,
    { ordinary_input: 1.0, cache_read: 0.1, cache_write_5m: 1.25, cache_write_1h: 2.0 },
  )
  assert_eq(result.input_tokens, 1000)
  assert_eq(result.cache_hit_ratio, Some(0.7))
  assert_eq(result.effective_input_cost, Some(420.0))
  assert_eq(result.net_savings, Some(580.0))
}
