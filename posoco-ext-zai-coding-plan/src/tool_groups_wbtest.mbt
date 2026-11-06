///|
/// Declared provider tool groups: policy, endpoint derivation, and the
/// status-bar projection. Pure functions only — no connection, no events.
test "declares the three official coding-plan servers for a coding model" {
  let groups = zai_coding_plan_declared_groups(
    model="glm-5.3-flash",
    host=zai_coding_plan_profile_host("coding").unwrap(),
  )
  inspect(groups.length(), content="3")
  inspect(
    groups.map(fn(group) { group.group }).join(","),
    content="web_search_prime,web_reader,zread",
  )
  inspect(
    groups[0].endpoint,
    content="https://api.z.ai/api/mcp/web_search_prime/mcp",
  )
  inspect(groups[1].endpoint, content="https://api.z.ai/api/mcp/web_reader/mcp")
  inspect(groups[2].endpoint, content="https://api.z.ai/api/mcp/zread/mcp")
  inspect(groups[0].title, content="Web Search")
}

///|
test "cn profile resolves to the bigmodel host" {
  inspect(
    zai_coding_plan_profile_host("cn_coding").unwrap(),
    content="https://open.bigmodel.cn",
  )
  let groups = zai_coding_plan_declared_groups(
    model="glm-5.3",
    host=zai_coding_plan_profile_host("cn_coding").unwrap(),
  )
  inspect(
    groups[0].endpoint,
    content="https://open.bigmodel.cn/api/mcp/web_search_prime/mcp",
  )
}

///|
test "an unknown profile has no host instead of a guess" {
  inspect(zai_coding_plan_profile_host("pay_as_you_go") is None, content="true")
}

///|
test "an empty model declares nothing" {
  let groups = zai_coding_plan_declared_groups(
    model="",
    host="https://api.z.ai",
  )
  inspect(groups.length(), content="0")
}

///|
test "an unusable host declares nothing" {
  inspect(
    zai_coding_plan_declared_groups(model="glm-5.3", host="").length(),
    content="0",
  )
  inspect(
    zai_coding_plan_declared_groups(model="glm-5.3", host="/").length(),
    content="0",
  )
}

///|
test "a trailing slash on the host is tolerated" {
  let groups = zai_coding_plan_declared_groups(
    model="glm-5.3",
    host="https://api.z.ai/",
  )
  inspect(
    groups[0].endpoint,
    content="https://api.z.ai/api/mcp/web_search_prime/mcp",
  )
}

///|
test "a host with a port is used verbatim" {
  // The caller resolves the host (the provider's own endpoint resolution
  // drops any override path); the declaration must not re-interpret it.
  let groups = zai_coding_plan_declared_groups(
    model="glm-5.3",
    host="http://127.0.0.1:8080",
  )
  inspect(
    groups[0].endpoint,
    content="http://127.0.0.1:8080/api/mcp/web_search_prime/mcp",
  )
}

///|
test "every declared group carries selection guidance, unknown groups do not" {
  for group in zai_coding_plan_mcp_group_names() {
    inspect(zai_coding_plan_tool_guidance(group) is Some(_), content="true")
  }
  inspect(zai_coding_plan_tool_guidance("soon") is None, content="true")
}

///|
test "guidance names the fallback conditions: failure and out-of-scope" {
  for group in zai_coding_plan_mcp_group_names() {
    let guidance = zai_coding_plan_tool_guidance(group).unwrap()
    inspect(guidance.contains("rate-limited"), content="true")
    inspect(guidance.contains("fall back to other tools"), content="true")
  }
}

///|
test "inactive and withdrawing hide the segment" {
  inspect(ZaiToolsState::Inactive.segment_value() is None, content="true")
  inspect(
    ZaiToolsState::Withdrawing(total=3).segment_value() is None,
    content="true",
  )
  inspect(ZaiToolsState::Inactive.segment_color() is None, content="true")
  inspect(
    ZaiToolsState::Withdrawing(total=3).segment_color() is None,
    content="true",
  )
}

///|
test "connecting, ready, and degraded render counts with distinct colours" {
  let connecting = ZaiToolsState::Connecting(connected=1, total=3)
  inspect(connecting.segment_value().unwrap(), content="1/3")
  inspect(connecting.segment_color().unwrap(), content="info")
  let ready = ZaiToolsState::Ready(total=3)
  inspect(ready.segment_value().unwrap(), content="3/3")
  inspect(ready.segment_color().unwrap(), content="success")
  let degraded = ZaiToolsState::Degraded(connected=2, total=3)
  inspect(degraded.segment_value().unwrap(), content="2/3")
  inspect(degraded.segment_color().unwrap(), content="warning")
}

///|
test "counts are clamped so a buggy plane cannot render 4/3" {
  let state = ZaiToolsState::Connecting(connected=9, total=3)
  inspect(state.segment_value().unwrap(), content="3/3")
  inspect(state.connected(), content="3")
  let negative = ZaiToolsState::Degraded(connected=-1, total=3)
  inspect(negative.segment_value().unwrap(), content="0/3")
  inspect(
    ZaiToolsState::Connecting(connected=2, total=0).segment_value().unwrap(),
    content="0/0",
  )
}

///|
test "a settled connect is ready only when every server answered" {
  inspect(
    ZaiToolsState::settled(connected=3, total=3).to_repr(),
    content="Ready(total=3)",
  )
  inspect(
    ZaiToolsState::settled(connected=2, total=3).to_repr(),
    content="Degraded(connected=2, total=3)",
  )
  inspect(
    ZaiToolsState::settled(connected=0, total=3).to_repr(),
    content="Degraded(connected=0, total=3)",
  )
  // A zero-server declaration never claims success.
  inspect(
    ZaiToolsState::settled(connected=0, total=0).to_repr(),
    content="Degraded(connected=0, total=0)",
  )
}
