///|
struct PtcMockInvoker {
  calls : Array[String]
}

///|
impl @posoco-ext-ptc.ToolInvoker for PtcMockInvoker with fn invoke(
  self : PtcMockInvoker,
  name : String,
  args : Json,
) -> @protocol.Outcome {
  self.calls.push(name)
  @protocol.Success(
    content="ok",
    structured=Some({ "name": name, "args": args }),
  )
}

///|
fn test_ptc_tools() -> Array[@posoco.ToolDef] {
  [
    {
      name: @posoco.ToolName::unchecked("read"),
      description: "Read one file",
      input_schema: { "type": "object" },
      owner: @posoco.OwnerId::unchecked("test"),
      policy: @posoco.ExecutionPolicy::Parallel,
      provenance: Some("test"),
    },
  ]
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
  let mock = PtcMockInvoker::{ calls: [], }
  let ptc = @posoco-ext-ptc.PtcExtension(
    exposed=test_ptc_tools(),
    scoped_invoker=mock,
  )
  let ctx = @posoco.tk_tool_call_ctx(name="run_code", arguments={
    "description": "Select tool name",
    "code": (
      #|let value = ctx.call("read", {"path": "README.md"})
      #|match value {
      #|  {"name": String(name), ..} => {"picked": name}
      #|  _ => {"picked": "missing"}
      #|}
    ),
  })
  let result = ptc.execute(ctx)
  match result {
    @posoco.ToolOutcome::Success(structured=Some(value), ..) =>
      assert_eq(value, { "picked": "read" })
    _ => fail("guest did not return structured success")
  }
  assert_eq(mock.calls, ["read"])
  let trace = ptc.trace(ctx.effect_id.to_string())
  assert_eq(trace.length(), 1)
  assert_eq(trace[0].name, "read")
}

///|
async test "PTC refuses nested tool use without trusted bridge" {
  let ptc = @posoco-ext-ptc.PtcExtension(exposed=test_ptc_tools())
  let result = ptc.execute(
    @posoco.tk_tool_call_ctx(name="run_code", arguments={
      "description": "Fail closed",
      "code": (
        #|let value = ctx.call("read", {})
        #|value
      ),
    }),
  )
  match result {
    @posoco.ToolOutcome::Success(
      structured=Some({ "error": String(code), .. }),
      ..
    ) => assert_eq(code, "ToolInvocationUnavailable")
    _ => fail("guest did not fail closed")
  }
}

///|
async test "PTC rejects names outside exposed capabilities before invoking bridge" {
  let mock = PtcMockInvoker::{ calls: [], }
  let ptc = @posoco-ext-ptc.PtcExtension(
    exposed=test_ptc_tools(),
    scoped_invoker=mock,
  )
  let result = ptc.execute(
    @posoco.tk_tool_call_ctx(name="run_code", arguments={
      "description": "Reject write",
      "code": (
        #|let value = ctx.call("write", {"path": "secret"})
        #|value
      ),
    }),
  )
  match result {
    @posoco.ToolOutcome::Success(
      structured=Some({ "error": String(code), .. }),
      ..
    ) => assert_eq(code, "CapabilityDenied")
    _ => fail("disallowed tool was not rejected")
  }
  assert_eq(mock.calls.length(), 0)
}

///|
async test "PTC rejects invalid code without spawning a guest" {
  let ptc = @posoco-ext-ptc.PtcExtension()
  let result = ptc.execute(
    @posoco.tk_tool_call_ctx(name="run_code", arguments={
      "description": "Invalid",
      "code": "",
    }),
  )
  assert_true(result is @posoco.ToolOutcome::ToolReportedError(..))
}

///|
async test "PTC background mode fails closed when no Agent task scope exists" {
  let ptc = @posoco-ext-ptc.PtcExtension()
  let result = ptc.execute(
    @posoco.tk_tool_call_ctx(name="run_code", arguments={
      "description": "Schedule a program",
      "code": "{\"ok\": true}",
      "background": true,
    }),
  )
  match result {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) =>
      assert_true(content.contains("background tasks are unavailable"))
    _ => fail("PTC scheduled an unscoped background task")
  }
}

///|
async test "PTC complete script and inline code are mutually exclusive" {
  let ptc = @posoco-ext-ptc.PtcExtension()
  let result = ptc.execute(
    @posoco.tk_tool_call_ctx(name="run_code", arguments={
      "description": "Reject ambiguous source",
      "source": "async fn main {}",
      "code": "{}",
    }),
  )
  assert_true(result is @posoco.ToolOutcome::ToolReportedError(..))
}

///|
async test "run_code rejects a code argument that includes the ptc_run signature" {
  let ptc = @posoco-ext-ptc.PtcExtension()
  let result = ptc.execute(
    @posoco.tk_tool_call_ctx(name="run_code", arguments={
      "description": "Wrapped probe",
      "code": "async fn ptc_run(ctx : PtcContext, input : Json) -> Json {\n  input\n}",
    }),
  )
  match result {
    @posoco.ToolOutcome::ToolReportedError(content~, structured=None) =>
      assert_true(content.contains("body of async fn ptc_run"))
    _ => fail("wrapped code was not rejected before building")
  }
}

///|
async test "run_code build failure carries compiler diagnostics" {
  let ptc = @posoco-ext-ptc.PtcExtension()
  let result = ptc.execute(
    @posoco.tk_tool_call_ctx(name="run_code", arguments={
      "description": "Broken probe",
      "code": "let broken :",
    }),
  )
  match result {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) => {
      assert_true(content.contains("run_code build failed"))
      assert_true(content.contains("the compiler"))
      assert_true(content.length() > 120, msg=content)
    }
    _ => fail("build failure surfaced without diagnostics")
  }
}
