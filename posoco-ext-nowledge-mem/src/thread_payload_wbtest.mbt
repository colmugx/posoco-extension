///|
fn thread_msg(role : NmemRole, content : String) -> NmemThreadMessage {
  { role, content, metadata: Map::from_array([]), }
}

///|
test "thread_id: lowercases and keeps [a-z0-9._-]" {
  inspect(thread_id("Posoco", "Session 1"), content="posoco-session-1")
  inspect(thread_id("DEMO", "a.b_c-d"), content="demo-a.b_c-d")
  inspect(thread_id("posoco", "ABC"), content="posoco-abc")
}

///|
test "thread_id: a run of invalid characters collapses to one dash" {
  inspect(thread_id("demo", "a??b c"), content="demo-a-b-c")
  inspect(thread_id("demo", "a  b"), content="demo-a-b")
  inspect(thread_id("demo", "a//b"), content="demo-a-b")
}

///|
test "thread_id: invalid leading characters produce a leading dash" {
  inspect(thread_id("?demo", "s"), content="-demo-s")
}

///|
test "thread_id: literal dashes are kept next to replacement dashes" {
  inspect(thread_id("demo", "a-?b"), content="demo-a--b")
}

///|
test "thread_title: first user message wins, capped at 120 characters" {
  inspect(
    thread_title(
      [
        thread_msg(Assistant, "hi there"),
        thread_msg(User, "  please fix the bug  "),
      ],
      "cetas",
    ),
    content="please fix the bug",
  )
  let long = repeat_text("y", 200)
  inspect(
    thread_title([thread_msg(User, long)], "cetas").length(),
    content="120",
  )
}

///|
test "thread_title: falls back to the host label without a user message" {
  inspect(thread_title([], "cetas"), content="Cetas session")
  inspect(
    thread_title([thread_msg(Assistant, "only assistant")], "cetas"),
    content="Cetas session",
  )
}

///|
test "should_sync: needs at least one user and one assistant message" {
  inspect(should_sync([]), content="false")
  inspect(should_sync([thread_msg(User, "hi")]), content="false")
  inspect(should_sync([thread_msg(Assistant, "hello")]), content="false")
  inspect(
    should_sync([thread_msg(User, "hi"), thread_msg(Assistant, "hello")]),
    content="true",
  )
}

///|
test "build_thread_body: full JSON shape with optional agent ids" {
  let config : NmemConfig = {
    api_url: "http://127.0.0.1:14242",
    mcp_url: "http://127.0.0.1:14242/mcp",
    api_key: None,
    space: None,
    agent_id: Some("agent-1"),
    host_agent_id: None,
    source_app: "posoco",
  }
  let body = build_thread_body(
    thread_id="posoco-session-1",
    title="hello",
    messages=[
      {
        role: User,
        content: "hello",
        metadata: Map::from_array([
          ("external_id", Json::string("posoco-session_1-1")),
          ("source_app", Json::string("posoco")),
        ]),
      },
      {
        role: Assistant,
        content: "[Tool: bash]",
        metadata: Map::from_array([
          ("external_id", Json::string("posoco-session_1-2")),
          ("source_app", Json::string("posoco")),
        ]),
      },
    ],
    config~,
    session_id="session_1",
    sync_reason="agent_end",
  )
  json_inspect(body, content={
    "thread_id": "posoco-session-1",
    "title": "hello",
    "messages": [
      {
        "role": "user",
        "content": "hello",
        "metadata": {
          "external_id": "posoco-session_1-1",
          "source_app": "posoco",
        },
      },
      {
        "role": "assistant",
        "content": "[Tool: bash]",
        "metadata": {
          "external_id": "posoco-session_1-2",
          "source_app": "posoco",
        },
      },
    ],
    "source": "posoco",
    "project": null,
    "tool_version": "posoco-ext-nowledge-mem/0.1.0",
    "metadata": {
      "session_id": "session_1",
      "sync_reason": "agent_end",
      "agent_id": "agent-1",
    },
  })
}

///|
test "build_thread_body: minimal config omits agent ids in metadata" {
  let body = build_thread_body(
    thread_id="demo-s1",
    title="Cetas session",
    messages=[],
    config=plain_config(),
    session_id="s1",
    sync_reason="session_shutdown:exit",
  )
  json_inspect(body, content={
    "thread_id": "demo-s1",
    "title": "Cetas session",
    "messages": [],
    "source": "posoco",
    "project": null,
    "tool_version": "posoco-ext-nowledge-mem/0.1.0",
    "metadata": { "session_id": "s1", "sync_reason": "session_shutdown:exit" },
  })
}
