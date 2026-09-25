///|
async test "memoh session store is intentionally ephemeral" {
  let memoh = Memoh()
  let first = memoh.load("s1")
  assert_eq(first.messages.length(), 0)
  assert_eq(first.metadata.length(), 0)

  let user = @posoco.Message::UserMessage(content=[
    @posoco.Content::Text("hello"),
  ])
  let dirty = @posoco.Session::{
    messages: [user],
    metadata: Map::from_array([("marker", Json::string("value"))]),
  }

  memoh.save("s1", dirty)
  memoh.append_messages("s1", 0, [user][:])
  memoh.truncate("s1", 0)

  let after = memoh.load("s1")
  assert_eq(after.messages.length(), 0)
  assert_eq(after.metadata.length(), 0)
}

///|
test "memoh extension contributes session store and context hook" {
  let memoh = Memoh()
  assert_eq(memoh.extension_id(), "posoco_ext_memoh")
  let manifest = memoh.manifest()
  assert_eq(manifest.sessions.length(), 1)
  assert_eq(manifest.hooks.length(), 1)
  assert_eq(manifest.tools.length(), 0)
}

///|
fn tk_memoh_impl(name : String) -> @acp.ProtocolNullable[@acp.Implementation] {
  @acp.ProtocolNullable::Value({
    name,
    title: @acp.ProtocolNullable::Omitted,
    version: "test",
    meta: @acp.ProtocolNullable::Omitted,
  })
}

///|
test "client contract accepts Memoh" {
  require_memoh_client(tk_memoh_impl("memoh"))
}

///|
test "client contract rejects another ACP client" {
  let result : Result[Unit, MemohError] = Ok(
    require_memoh_client(tk_memoh_impl("zed")),
  ) catch {
    error => Err(error)
  }
  match result {
    Err(InvalidClient(..)) => ()
    _ => fail("expected InvalidClient")
  }
}

///|
fn tk_context_block(text : String) -> @acp.ContentBlock {
  @acp.ContentBlock::Resource({
    annotations: @acp.ProtocolNullable::Omitted,
    resource: @acp.EmbeddedResourceResource::Text({
      mime_type: @acp.ProtocolNullable::Value("text/markdown"),
      text,
      uri: MEMOH_CURRENT_TURN_URI,
      meta: @acp.ProtocolNullable::Omitted,
    }),
    meta: @acp.ProtocolNullable::Omitted,
  })
}

///|
test "prompt decoder separates host context from user text and image" {
  let prompt = decode_memoh_prompt([
    tk_context_block("runtime context"),
    @acp.ContentBlock::Text({
      annotations: @acp.ProtocolNullable::Omitted,
      text: "fix it",
      meta: @acp.ProtocolNullable::Omitted,
    }),
    @acp.ContentBlock::Image({
      annotations: @acp.ProtocolNullable::Omitted,
      data: "aGVsbG8=",
      mime_type: "image/png",
      uri: @acp.ProtocolNullable::Omitted,
      meta: @acp.ProtocolNullable::Omitted,
    }),
  ])
  assert_eq(prompt.context.text, "runtime context")
  assert_eq(prompt.user_content.length(), 2)
  assert_true(prompt.user_content[0] is @posoco.Content::Text("fix it"))
  assert_true(
    prompt.user_content[1] is @posoco.Content::Image(
      media_type="image/png",
      data="aGVsbG8=",
    ),
  )
}

///|
test "prompt decoder requires exactly one current-turn context" {
  let missing : Result[MemohPrompt, MemohError] = Ok(
    decode_memoh_prompt([
      @acp.ContentBlock::Text({
        annotations: @acp.ProtocolNullable::Omitted,
        text: "hello",
        meta: @acp.ProtocolNullable::Omitted,
      }),
    ]),
  ) catch {
    error => Err(error)
  }
  match missing {
    Err(MissingContext) => ()
    _ => fail("expected MissingContext")
  }

  let duplicate : Result[MemohPrompt, MemohError] = Ok(
    decode_memoh_prompt([
      tk_context_block("a"),
      tk_context_block("b"),
    ]),
  ) catch {
    error => Err(error)
  }
  match duplicate {
    Err(InvalidContext(..)) => ()
    _ => fail("expected InvalidContext")
  }
}

///|
async test "context hook injects after stable system prompt and clears at turn end" {
  let memoh = Memoh()
  let prompt = decode_memoh_prompt([
    tk_context_block("runtime context"),
    @acp.ContentBlock::Text({
      annotations: @acp.ProtocolNullable::Omitted,
      text: "user request",
      meta: @acp.ProtocolNullable::Omitted,
    }),
  ])
  let user = memoh.prepare_turn(prompt)
  let stable : @posoco.Message = @posoco.Message::SystemMessage(content=[
    @posoco.Content::Text("stable charter"),
  ])
  let messages = [stable, user]
  let injected = memoh.before_model(messages)
  assert_eq(injected.length(), 3)
  match injected[0] {
    @posoco.Message::SystemMessage(content~) =>
      assert_true(content[0] is @posoco.Content::Text("stable charter"))
    _ => fail("expected stable system message first")
  }
  match injected[1] {
    @posoco.Message::SystemMessage(content~) =>
      match content[0] {
        @posoco.Content::Text(text) => {
          assert_true(text.contains("runtime context"))
          assert_true(text.contains("<memoh-context"))
        }
        _ => fail("expected text host context")
      }
    _ => fail("expected Memoh host context second")
  }
  match injected[2] {
    @posoco.Message::UserMessage(content~) =>
      assert_true(content[0] is @posoco.Content::Text("user request"))
    _ => fail("expected untouched user message")
  }

  memoh.on_turn_end()
  let after = memoh.before_model(messages)
  assert_true(after === messages)
}
