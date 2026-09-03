///|
/// Whitebox helper: register a pi tool carrying (or omitting) promptSnippet /
/// promptGuidelines, exercising the same state shape registerTool produces.
extern "js" fn wbtest_register_pi_tool_prompt(
  host : JsPiHost,
  name : String,
  snippet : String,
  guidelines_json : String,
) -> Unit =
  #| (host, name, snippet, guidelinesJson) => {
  #|   const guidelines = JSON.parse(guidelinesJson);
  #|   host.state.tools.push({
  #|     name,
  #|     description: "",
  #|     parameters: { type: "object", properties: {} },
  #|     ...(snippet === "" ? {} : { promptSnippet: snippet }),
  #|     ...(Array.isArray(guidelines) && guidelines.length > 0
  #|       ? { promptGuidelines: guidelines }
  #|       : {}),
  #|   });
  #|   host.state.catalogVersion += 1;
  #| }

///|
fn wbtest_hook(adaptor : PiAdaptor) -> &@posoco.PipelineHook {
  adaptor.hook as &@posoco.PipelineHook
}

///|
/// Join every Text block of the first message's content (the hook appends
/// its block as an additional element after the base prompt text).
fn wbtest_system_text(messages : Array[@kernel.Message]) -> String {
  match messages[0] {
    @kernel.SystemMessage(content~) => {
      let parts : Array[String] = []
      for block in content {
        match block {
          @kernel.Text(text) => parts.push(text)
          _ => ()
        }
      }
      parts.join("\n")
    }
    _ => ""
  }
}

///|
async test "before_model appends one delimited pi-tools block to the system message" {
  let adaptor = pi_adaptor_new()
  wbtest_register_pi_tool_prompt(
    adaptor.host,
    "probe_search",
    "Search the web and return synthesized results.",
    "[\"Prefer multi-query research.\", \"Prefer multi-query research.\", \"   \"]",
  )
  let messages : Array[@kernel.Message] = [
    @kernel.SystemMessage(content=[@kernel.Text("BASE PROMPT")]),
    @kernel.UserMessage(content=[@kernel.Text("hello")]),
  ]
  let rewritten = wbtest_hook(adaptor).before_model(messages)
  inspect(rewritten.length(), content="2")
  let system = wbtest_system_text(rewritten)
  inspect(system.contains("<pi-tools>"), content="true")
  inspect(system.contains("Available tools:"), content="true")
  inspect(
    system.contains(
      "- probe_search: Search the web and return synthesized results.",
    ),
    content="true",
  )
  inspect(system.contains("Guidelines:"), content="true")
  // Duplicate and blank guidelines collapse; the bullet appears exactly once.
  inspect(
    system.split("- Prefer multi-query research.").length() - 1,
    content="1",
  )
  inspect(system.contains("</pi-tools>"), content="true")
  // The injected block rides as its own content element after the base text.
  match rewritten[0] {
    @kernel.SystemMessage(content~) => inspect(content.length(), content="2")
    _ => fail("expected system message")
  }
  // Non-system messages pass through untouched.
  inspect(rewritten[1] == messages[1], content="true")
  // The input array is not mutated.
  inspect(wbtest_system_text(messages), content="BASE PROMPT")
}

///|
async test "before_model without snippets returns the messages unchanged" {
  let adaptor = pi_adaptor_new()
  wbtest_register_pi_tool_prompt(adaptor.host, "plain_tool", "", "[]")
  let messages : Array[@kernel.Message] = [
    @kernel.SystemMessage(content=[@kernel.Text("BASE PROMPT")]),
    @kernel.UserMessage(content=[@kernel.Text("hello")]),
  ]
  let rewritten = wbtest_hook(adaptor).before_model(messages)
  inspect(rewritten.length(), content="2")
  inspect(rewritten == messages, content="true")
}

///|
async test "before_model creates the system message when none exists" {
  let adaptor = pi_adaptor_new()
  wbtest_register_pi_tool_prompt(
    adaptor.host,
    "solo",
    "Solo snippet.",
    "[\"Be terse.\"]",
  )
  let rewritten = wbtest_hook(adaptor).before_model([
    @kernel.UserMessage(content=[@kernel.Text("hi")]),
  ])
  inspect(rewritten.length(), content="2")
  inspect(
    wbtest_system_text(rewritten).contains("- solo: Solo snippet."),
    content="true",
  )
  inspect(
    rewritten[1] == @kernel.UserMessage(content=[@kernel.Text("hi")]),
    content="true",
  )
  let from_empty = wbtest_hook(adaptor).before_model([])
  inspect(from_empty.length(), content="1")
  inspect(
    wbtest_system_text(from_empty).contains("Guidelines:"),
    content="true",
  )
}

///|
async test "guidelines-only tools render without an Available tools section" {
  let adaptor = pi_adaptor_new()
  wbtest_register_pi_tool_prompt(
    adaptor.host,
    "quiet",
    "",
    "[\"Share sources.\"]",
  )
  let rewritten = wbtest_hook(adaptor).before_model([
    @kernel.SystemMessage(content=[@kernel.Text("BASE")]),
  ])
  let system = wbtest_system_text(rewritten)
  inspect(system.contains("Available tools:"), content="false")
  inspect(system.contains("- Share sources."), content="true")
}

///|
async test "hidden tools contribute no snippet or guideline to the block" {
  let adaptor = pi_adaptor_new()
  wbtest_register_pi_tool_prompt(
    adaptor.host,
    "shadowed",
    "Shadowed snippet.",
    "[\"Shadowed guideline.\"]",
  )
  wbtest_register_pi_tool_prompt(adaptor.host, "live", "Live snippet.", "[]")
  pi_adaptor_set_hidden_tools_json(adaptor, "[\"shadowed\"]")
  let messages : Array[@kernel.Message] = [
    @kernel.SystemMessage(content=[@kernel.Text("BASE")]),
  ]
  let system = wbtest_system_text(wbtest_hook(adaptor).before_model(messages))
  inspect(system.contains("- shadowed:"), content="false")
  inspect(system.contains("Shadowed snippet"), content="false")
  inspect(system.contains("Shadowed guideline"), content="false")
  inspect(system.contains("- live: Live snippet."), content="true")
  // The diagnostic block agrees with what the hook injects.
  inspect(
    pi_adaptor_prompt_block_json(adaptor).contains("shadowed"),
    content="false",
  )
  // Clearing the set restores visibility live.
  pi_adaptor_set_hidden_tools_json(adaptor, "[]")
  inspect(
    pi_adaptor_prompt_block_json(adaptor).contains(
      "- shadowed: Shadowed snippet.",
    ),
    content="true",
  )
}

///|
test "manifest contributes the hook" {
  let adaptor = pi_extension()
  inspect(adaptor.manifest().hooks.length(), content="1")
}
