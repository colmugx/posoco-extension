///|
fn cache_body() -> Json {
  {
    "model": "m",
    "max_tokens": 2048,
    "tools": [{ "name": "read", "description": "read", "input_schema": {} }],
    "system": [{ "type": "text", "text": "stable system" }],
    "messages": [
      { "role": "user", "content": [{ "type": "text", "text": "hello" }] },
    ],
  }
}

///|
test "automatic Messages cache uses top-level cache_control" {
  let body = cache_body()
  let cached = apply_messages_cache_policy(body, CacheAutomatic5m)
  assert_eq(jget(jget(cached, key="cache_control"), key="type"), "ephemeral")
  let again = apply_messages_cache_policy(body, CacheAutomatic1h)
  assert_eq(jget(jget(again, key="cache_control"), key="ttl"), "1h")
  assert_eq(jopt(body, key="cache_control"), None)
}

///|
test "cache gateway capability mismatch fails loudly" {
  let bad = Ok(
    apply_messages_cache_policy(cache_body(), CacheAutomatic5m, capabilities={
      automatic: false,
      one_hour: false,
    }),
  ) catch {
    error => Err(error)
  }
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
  let result = analyze_messages_cache_economics(usage, creation, {
    ordinary_input: 1.0,
    cache_read: 0.1,
    cache_write_5m: 1.25,
    cache_write_1h: 2.0,
  })
  assert_eq(result.input_tokens, 1000)
  assert_eq(result.cache_hit_ratio, Some(0.7))
  assert_eq(result.effective_input_cost, Some(420.0))
  assert_eq(result.net_savings, Some(580.0))
}

///|
test "stable system and automatic cache combine in correct prefix order" {
  let body = mark_messages_stable_prefix(cache_body(), StableSystem)
  let marked = apply_messages_cache_policy(body, CacheAutomatic5m)
  let system = jget(marked, key="system")
  let item = jat(system, index=0)
  assert_eq(jget(jget(item, key="cache_control"), key="type"), "ephemeral")
  assert_eq(jget(jget(marked, key="cache_control"), key="type"), "ephemeral")
  let layout = inspect_messages_cache_layout(marked)
  assert_eq(layout.explicit_breakpoints, 1)
  assert_eq(layout.blocks_since_last_explicit, 1)
}

///|
test "stable prefix marker and automatic caching are request options" {
  let body = encode_request(
    model="m",
    max_tokens=2048,
    system=Some([{ "type": "text", "text": "Stable" }]),
    messages=[{ "role": "user", "content": [{ "type": "text", "text": "A" }] }],
    options=MessagesRequestOptions::MessagesRequestOptions(
      stable_prefix=Some(StableSystem),
      cache_mode=CacheAutomatic5m,
    ),
  )
  assert_eq(jget(jget(body, key="cache_control"), key="type"), "ephemeral")
  assert_eq(
    jget(
      jget(jat(jget(body, key="system"), index=0), key="cache_control"),
      key="type",
    ),
    "ephemeral",
  )
}

///|
test "cache TTL order refuses one-hour automatic after five-minute explicit" {
  let body = mark_messages_stable_prefix(cache_body(), StableSystem)
  let value = Ok(apply_messages_cache_policy(body, CacheAutomatic1h)) catch {
    error => Err(error)
  }
  match value {
    Err(@posoco.ModelError::RequestBuild(message)) =>
      assert_true(message.contains("ttl_order"))
    _ => fail("expected 1h after 5m to fail")
  }
}

///|
test "cache prefix flags changed thinking and tool shapes" {
  let previous = cache_body()
  let current = cache_body()
  guard current is Json::Object(fields) else { fail("expected object") }
  fields["thinking"] = { "type": "adaptive" }
  let result = compare_messages_cache_prefix(previous, current)
  assert_false(result.request_settings_stable)
  assert_false(result.prefix_reusable)
}

///|
test "cache economics does not invent TTL distribution" {
  let usage : MessagesUsage = {
    input_tokens: 100,
    output_tokens: 10,
    cache_creation_input_tokens: Some(400),
    cache_read_input_tokens: Some(500),
  }
  let result = analyze_messages_cache_economics(
    usage,
    { ephemeral_5m_input_tokens: None, ephemeral_1h_input_tokens: None, },
    {
      ordinary_input: 1.0,
      cache_read: 0.1,
      cache_write_5m: 1.25,
      cache_write_1h: 2.0,
    },
  )
  assert_eq(result.effective_input_cost, None)
  assert_eq(result.net_savings, None)
  assert_eq(result.cache_hit_ratio, Some(0.5))
}

///|
test "nonstreaming Messages result retains native 5m and 1h cache-write split" {
  let result = parse_response(provider="test", {
    "id": "msg_cached",
    "type": "message",
    "role": "assistant",
    "model": "m",
    "content": [{ "type": "text", "text": "Done" }],
    "stop_reason": "end_turn",
    "stop_sequence": Json::null(),
    "usage": {
      "input_tokens": 100,
      "output_tokens": 20,
      "cache_creation_input_tokens": 300,
      "cache_read_input_tokens": 600,
      "cache_creation": {
        "ephemeral_5m_input_tokens": 100,
        "ephemeral_1h_input_tokens": 200,
      },
    },
  })
  let split = result.cache_creation.unwrap_or({
    ephemeral_5m_input_tokens: None,
    ephemeral_1h_input_tokens: None,
  })
  assert_eq(split.ephemeral_5m_input_tokens, Some(100))
  assert_eq(split.ephemeral_1h_input_tokens, Some(200))
  let economics = result
    .cache_economics({
      ordinary_input: 1.0,
      cache_read: 0.1,
      cache_write_5m: 1.25,
      cache_write_1h: 2.0,
    })
    .unwrap_or({
      input_tokens: 0,
      cache_read_tokens: None,
      cache_write_tokens: None,
      cache_hit_ratio: None,
      effective_input_cost: None,
      uncached_input_cost: None,
      net_savings: None,
    })
  assert_eq(economics.input_tokens, 1000)
  assert_eq(economics.effective_input_cost, Some(685.0))
  assert_eq(economics.net_savings, Some(315.0))
}

///|
test "too many native explicit breakpoints are rejected" {
  let marks : Array[Json] = []
  for i in 0..<5 {
    marks.push({
      "type": "text",
      "text": "part \{i}",
      "cache_control": { "type": "ephemeral" },
    })
  }
  let body : Json = {
    "model": "m",
    "max_tokens": 100,
    "messages": [{ "role": "user", "content": marks }],
  }
  let rejected = Ok(apply_messages_cache_policy(body, CacheExplicit)) catch {
    error => Err(error)
  }
  match rejected {
    Err(@posoco.ModelError::RequestBuild(message)) =>
      assert_true(message.contains("breakpoints"))
    _ => fail("expected breakpoint limit error")
  }
}

///|
test "explicit cache TTL must be 1h before 5m" {
  let body : Json = {
    "model": "m",
    "max_tokens": 100,
    "messages": [
      {
        "role": "user",
        "content": [
          {
            "type": "text",
            "text": "first",
            "cache_control": { "type": "ephemeral" },
          },
          {
            "type": "text",
            "text": "second",
            "cache_control": { "type": "ephemeral", "ttl": "1h" },
          },
        ],
      },
    ],
  }
  let rejected = Ok(apply_messages_cache_policy(body, CacheExplicit)) catch {
    error => Err(error)
  }
  match rejected {
    Err(@posoco.ModelError::RequestBuild(message)) =>
      assert_true(message.contains("ttl_order"))
    _ => fail("expected TTL order error")
  }
}

///|
test "cache lookback risk is diagnostic not a false cache hit" {
  let blocks : Array[Json] = []
  for i in 0..<21 {
    blocks.push({ "type": "text", "text": "block \{i}" })
  }
  let body : Json = {
    "model": "m",
    "max_tokens": 100,
    "messages": [{ "role": "user", "content": blocks }],
  }
  let layout = inspect_messages_cache_layout(body)
  assert_true(layout.lookback_risk)
  assert_eq(layout.blocks_since_last_explicit, 21)
}

///|
test "native lookback counts consecutive tool batches as one position" {
  let tools : Array[Json] = []
  for i in 0..<25 {
    tools.push({
      "type": "tool_result",
      "tool_use_id": "tool-\{i}",
      "content": "ok",
    })
  }
  let body : Json = {
    "model": "m",
    "max_tokens": 1024,
    "messages": [{ "role": "user", "content": tools }],
  }
  let layout = inspect_messages_cache_layout(body)
  assert_eq(layout.scanned_blocks, 1)
  assert_false(layout.lookback_risk)
}

///|
test "empty text block cannot be used as an explicit breakpoint" {
  let body : Json = {
    "model": "m",
    "max_tokens": 1024,
    "messages": [
      {
        "role": "user",
        "content": [
          {
            "type": "text",
            "text": "",
            "cache_control": { "type": "ephemeral" },
          },
        ],
      },
    ],
  }
  let failure = Ok(apply_messages_cache_policy(body, CacheExplicit)) catch {
    e => Err(e)
  }
  match failure {
    Err(@posoco.ModelError::RequestBuild(message)) =>
      assert_true(message.contains("placement"))
    _ => fail("expected empty text cache marker rejection")
  }
}

///|
test "stable-history lookback inserts only safe user checkpoints" {
  let messages : Array[Json] = []
  for i in 0..<28 {
    messages.push(
      Json::object({
        "role": Json::string("user"),
        "content": Json::array([
          Json::object({
            "type": Json::string("text"),
            "text": Json::string("stable-\{i}"),
          }),
        ]),
      }),
    )
  }
  messages.push({
    "role": "user",
    "content": [{ "type": "text", "text": "volatile request" }],
  })
  let request = encode_request(
    model="m",
    max_tokens=2048,
    messages~,
    options=MessagesRequestOptions::MessagesRequestOptions(
      cache_mode=CacheAutomatic5m,
      stable_history_messages=Some(28),
    ),
  )
  let layout = inspect_messages_cache_layout(request)
  assert_eq(layout.explicit_breakpoints, 2)
  assert_eq(jget(jget(request, key="cache_control"), key="type"), "ephemeral")
  let output = jget(request, key="messages")
  let earlier = jget(jat(output, index=17), key="content")
  assert_eq(
    jget(jget(jat(earlier, index=0), key="cache_control"), key="type"),
    "ephemeral",
  )
  let latest = jget(jat(output, index=28), key="content")
  assert_eq(jopt(jat(latest, index=0), key="cache_control"), None)
  // The caller's original canonical messages were never rewritten.
  assert_eq(
    jopt(jat(jget(messages[17], key="content"), index=0), key="cache_control"),
    None,
  )
}

///|
test "history checkpoint budget fails rather than dropping stable positions" {
  let msgs : Array[Json] = []
  for i in 0..<110 {
    msgs.push(
      Json::object({
        "role": Json::string("user"),
        "content": Json::array([
          Json::object({
            "type": Json::string("text"),
            "text": Json::string("stable-\{i}"),
          }),
        ]),
      }),
    )
  }
  let request : Json = { "model": "m", "max_tokens": 2048, "messages": msgs }
  let outcome = Ok(
    mark_messages_stable_history_checkpoints(request, stable_messages=110),
  ) catch {
    error => Err(error)
  }
  match outcome {
    Err(@posoco.ModelError::RequestBuild(message)) =>
      assert_true(message.contains("breakpoints"))
    _ =>
      fail("expected explicit rejection when checkpoint capacity is exceeded")
  }
}

///|
test "existing automatic caching is validated even when request is unchanged" {
  let request : Json = {
    "model": "m",
    "max_tokens": 1024,
    "cache_control": { "type": "ephemeral", "ttl": "1h" },
    "messages": [
      { "role": "user", "content": [{ "type": "text", "text": "Hello" }] },
    ],
  }
  let unchanged = apply_messages_cache_policy(request, CacheUnchanged)
  assert_eq(unchanged, request)
  let unavailable = Ok(
    apply_messages_cache_policy(request, CacheUnchanged, capabilities={
      automatic: false,
      one_hour: false,
    }),
  ) catch {
    error => Err(error)
  }
  match unavailable {
    Err(@posoco.ModelError::RequestBuild(message)) =>
      assert_true(message.contains("capability"))
    _ => fail("expected capability rejection of existing automatic caching")
  }
  let duplicate = Ok(apply_messages_cache_policy(request, CacheAutomatic5m)) catch {
    error => Err(error)
  }
  match duplicate {
    Err(@posoco.ModelError::RequestBuild(message)) =>
      assert_true(message.contains("duplicate_automatic"))
    _ => fail("expected duplicate automatic cache rejection")
  }
  let explicit = Ok(apply_messages_cache_policy(request, CacheExplicit)) catch {
    error => Err(error)
  }
  match explicit {
    Err(@posoco.ModelError::RequestBuild(message)) =>
      assert_true(message.contains("mode_conflict"))
    _ => fail("expected explicit-mode conflict")
  }
}

///|
test "existing automatic cache counts toward four-breakpoint budget" {
  let marks : Array[Json] = []
  for i in 0..<4 {
    marks.push({
      "type": "text",
      "text": "stable-\{i}",
      "cache_control": { "type": "ephemeral" },
    })
  }
  let request : Json = {
    "model": "m",
    "max_tokens": 1024,
    "cache_control": { "type": "ephemeral" },
    "messages": [{ "role": "user", "content": marks }],
  }
  let result = Ok(apply_messages_cache_policy(request, CacheUnchanged)) catch {
    error => Err(error)
  }
  match result {
    Err(@posoco.ModelError::RequestBuild(message)) =>
      assert_true(message.contains("breakpoints"))
    _ => fail("expected combined breakpoint budget check")
  }
}
