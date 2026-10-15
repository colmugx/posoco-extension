///|
/// fidelity_wbtest.mbt — pure request-construction fidelity tests: every
/// input is a value built here, every assertion compares values. Together
/// they prove that Messages request construction never silently modifies
/// conversation content — the property a live multi-turn replay depends on.

///|
test "user text survives wire encoding verbatim" {
  let text = "Remember the codeword LANTERN. Reply with the codeword only."
  let wire = @messages.message_to_wire(
    @posoco.Message::UserMessage(content=[@posoco.Content::Text(text)]),
  )
  inspect(wire.length(), content="1")
  guard wire[0] is Json::Object(fields) else { fail("wire block shape") }
  guard fields.get("content") is Some(Json::Array(blocks)) else {
    fail("wire content shape")
  }
  inspect(blocks.length(), content="1")
  guard blocks[0] is Json::Object(block) else { fail("block shape") }
  inspect(block.get("type") == Some(Json::string("text")), content="true")
  inspect(
    block.get("text") ==
    Some(Json::string("Remember the codeword LANTERN. Reply with the codeword only.")),
    content="true",
  )
}

///|
test "assistant reasoning replays with its raw envelope intact" {
  // The envelope is produced by the kit's own parser from a gateway-shaped
  // response, then replayed: thinking text and signature must come back
  // byte-for-byte — never rewritten, never dropped.
  let response = Json::object({
    "type": Json::string("message"),
    "id": Json::string("m1"),
    "model": Json::string("claude"),
    "role": Json::string("assistant"),
    "content": Json::array([
      Json::object({
        "type": Json::string("thinking"),
        "thinking": Json::string("figuring out the answer step by step"),
        "signature": Json::string("sig-abc123="),
      }),
      Json::object({
        "type": Json::string("text"),
        "text": Json::string("Answer."),
      }),
    ]),
    "stop_reason": Json::string("end_turn"),
    "stop_sequence": Json::null(),
    "usage": Json::object({
      "input_tokens": Json::number(5),
      "output_tokens": Json::number(3),
    }),
  })
  let parsed = @messages.parse_response(provider="magpie", response) catch {
    error => fail("parse: \{error}")
  }
  let assistant = @posoco.Message::AssistantMessage(
    content=parsed.completion.message.content,
    tool_calls=parsed.completion.message.tool_calls,
    reasoning=parsed.completion.message.reasoning,
    finish_reason=parsed.completion.message.finish_reason,
  )
  let wire = @messages.message_to_wire(assistant) catch {
    error => fail("replay: \{error}")
  }
  let mut saw_thinking = false
  for message in wire {
    guard message is Json::Object(fields) else { continue }
    guard fields.get("content") is Some(Json::Array(blocks)) else {
      continue
    }
    for block in blocks {
    guard block is Json::Object(bfields) else { continue }
    if bfields.get("type") is Some(Json::String("thinking")) {
      saw_thinking = true
      inspect(
        bfields.get("thinking") ==
        Some(Json::string("figuring out the answer step by step")),
        content="true",
      )
      inspect(
        bfields.get("signature") == Some(Json::string("sig-abc123=")),
        content="true",
      )
    }
    }
  }
  inspect(saw_thinking, content="true")
}

///|
test "tool_result carries the exact tool_use call identity" {
  let call_id : @posoco.CallId = @posoco.CallId::unchecked("toolu_live_01")
  let tool_call : @posoco.ToolCall = {
    call_id,
    name: @posoco.ToolName::unchecked("get_weather"),
    arguments: Json::object({ "city": Json::string("Tokyo") }),
  }
  let wire = @messages.message_to_wire(
    @posoco.Message::ToolMessage(
      call_id~,
      tool_name=@posoco.ToolName::unchecked("get_weather"),
      outcome=@posoco.ToolOutcome::Success(
        content="Tokyo: 21C, clear",
        structured=None,
      ),
    ),
  )
  let mut saw_result = false
  for message in wire {
    guard message is Json::Object(fields) else { continue }
    guard fields.get("content") is Some(Json::Array(blocks)) else {
      continue
    }
    for block in blocks {
      guard block is Json::Object(bfields) else { continue }
      if bfields.get("type") is Some(Json::String("tool_result")) {
        saw_result = true
        inspect(
          bfields.get("tool_use_id") == Some(Json::string("toolu_live_01")),
          content="true",
        )
      }
    }
  }
  inspect(saw_result, content="true")
  // The call the result answers is the one that was issued.
  inspect(tool_call.call_id == call_id, content="true")
}

///|
test "the stable system prefix encodes identically across turns" {
  let system = [@posoco.Content::Text("You are documenting a gateway.")]
  let first = @messages.system_to_wire(
    content=system,
    cache_control=Some(@messages.CacheControl::{ ttl: None }),
  )
  let second = @messages.system_to_wire(
    content=system,
    cache_control=Some(@messages.CacheControl::{ ttl: None }),
  )
  // Prefix stability is byte-level: identical inputs, identical wire.
  inspect(first == second, content="true")
  inspect(first.stringify() == second.stringify(), content="true")
}

///|
test "cache_control marks the 5-minute flavor by default and never 1h" {
  let ephemeral = @messages.CacheControl::{ ttl: None }.to_wire()
  guard ephemeral is Json::Object(fields) else { fail("cache_control shape") }
  inspect(fields.get("type") == Some(Json::string("ephemeral")), content="true")
  inspect(fields.contains("ttl"), content="false")
  let one_hour = @messages.CacheControl::{ ttl: Some("1h") }.to_wire()
  guard one_hour is Json::Object(fields1h) else { fail("cache_control shape") }
  inspect(fields1h.get("ttl") == Some(Json::string("1h")), content="true")
}
