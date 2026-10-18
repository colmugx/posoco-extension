///|
struct PtcMockInvoker { calls : Array[String] }

///|
impl @mbtx.ToolInvoker for PtcMockInvoker with fn invoke(
  self : PtcMockInvoker, name : String, args : Json,
) -> @protocol.Outcome {
  self.calls.push(name)
  @protocol.Success(content="ok", structured=Some({"name": name, "args": args}))
}

///|
fn test_ptc_tools() -> Array[@posoco.ToolDef] {
  [{
    name: @posoco.ToolName::unchecked("read"),
    description: "Read one file",
    input_schema: {"type": "object"},
    owner: @posoco.OwnerId::unchecked("test"),
    policy: @posoco.ExecutionPolicy::Parallel,
    provenance: Some("test"),
  }]
}

///|
test "PTC model sees only run_code and a stable generated tool catalog" {
  let ptc = @posoco-ext-ptc.PtcExtension(exposed=test_ptc_tools())
  assert_eq(ptc.manifest().tools.length(), 1)
  let defs = ptc.list_tools()
  assert_eq(defs.length(), 1)
  assert_eq(defs[0].name.to_string(), "run_code")
  let prompt = ptc.system_prompt()
  assert_true(prompt.contains("ctx.call"))
  assert_true(prompt.contains("read"))
  assert_eq(prompt, ptc.system_prompt())
}

///|
async test "PTC real MoonBit guest calls trusted bridge and filters result" {
  let mock = PtcMockInvoker::{calls: []}
  let ptc = @posoco-ext-ptc.PtcExtension(exposed=test_ptc_tools(), scoped_invoker=mock)
  let ctx = @posoco.tk_tool_call_ctx(
    name="run_code",
    arguments={
      "description": "Select tool name",
      "code": #|let value = ctx.call("read", {"path": "README.md"})
              #|match value {
              #|  {"name": String(name), ..} => {"picked": name}
              #|  _ => {"picked": "missing"}
              #|}
      ,
    },
  )
  let result = ptc.execute(ctx)
  match result {
    @posoco.ToolOutcome::Success(structured=Some(value), ..) =>
      assert_eq(value, {"picked": "read"})
    _ => fail("guest did not return structured success")
  }
  assert_eq(mock.calls, ["read"])
}

///|
async test "PTC refuses nested tool use without trusted bridge" {
  let ptc = @posoco-ext-ptc.PtcExtension(exposed=test_ptc_tools())
  let result = ptc.execute(
    @posoco.tk_tool_call_ctx(
      name="run_code",
      arguments={
        "description": "Fail closed",
        "code": #|let value = ctx.call("read", {})
                #|value
        ,
      },
    ),
  )
  match result {
    @posoco.ToolOutcome::Success(
      structured=Some({"error": String(code), ..}), ..
    ) => assert_eq(code, "ToolInvocationUnavailable")
    _ => fail("guest did not fail closed")
  }
}
