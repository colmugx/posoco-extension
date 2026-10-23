///|
struct BunrakuMockInvoker {
  calls : Array[String]
}

///|
impl @posoco-ext-bunraku.ToolInvoker for BunrakuMockInvoker with fn invoke(
  self : BunrakuMockInvoker,
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
  let ptc = @posoco-ext-bunraku.BunrakuExtension(exposed=test_ptc_tools())
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
async test "settled nested calls emit one append-only event each" {
  let mock = BunrakuMockInvoker::{ calls: [], }
  let observed : Array[@posoco-ext-bunraku.NestedCallEvent] = []
  let ptc = @posoco-ext-bunraku.BunrakuExtension(
    exposed=test_ptc_tools(),
    scoped_invoker=mock,
    call_observers=[fn(event) { observed.push(event) }],
  )
  let result = ptc.execute(
    @posoco.tk_tool_call_ctx(name="run_code", arguments={
      "description": "Trace probe",
      "code": (
        #|let value = ctx.call("read", {"path": "README.md"})
        #|value
      ),
    }),
  )
  guard result is @posoco.ToolOutcome::Success(..) else {
    fail("guest did not succeed")
  }
  assert_eq(mock.calls, ["read"])
  assert_eq(observed.length(), 1)
  let event = observed[0]
  assert_eq(event.parent_call, "call_1")
  assert_eq(event.name, "read")
  assert_true(event.outcome is { "kind": "success", .. })
}

///|
async test "PTC real MoonBit guest calls trusted bridge and filters result" {
  let mock = BunrakuMockInvoker::{ calls: [], }
  let ptc = @posoco-ext-bunraku.BunrakuExtension(
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
  let ptc = @posoco-ext-bunraku.BunrakuExtension(exposed=test_ptc_tools())
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
  let mock = BunrakuMockInvoker::{ calls: [], }
  let ptc = @posoco-ext-bunraku.BunrakuExtension(
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
  let ptc = @posoco-ext-bunraku.BunrakuExtension()
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
  let ptc = @posoco-ext-bunraku.BunrakuExtension()
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
  let ptc = @posoco-ext-bunraku.BunrakuExtension()
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
async test "run_code rejects a code argument that includes a function signature" {
  let ptc = @posoco-ext-bunraku.BunrakuExtension()
  let result = ptc.execute(
    @posoco.tk_tool_call_ctx(name="run_code", arguments={
      "description": "Wrapped probe",
      "code": "async fn ptc_run(ctx : PtcContext, input : Json) -> Json {\n  input\n}",
    }),
  )
  match result {
    @posoco.ToolOutcome::ToolReportedError(content~, structured=None) =>
      assert_true(content.contains("must be the handler body"))
    _ => fail("wrapped code was not rejected before building")
  }
}

///|
async test "run_code rejects a complete program pasted as code" {
  let ptc = @posoco-ext-bunraku.BunrakuExtension()
  let result = ptc.execute(
    @posoco.tk_tool_call_ctx(name="run_code", arguments={
      "description": "Full program probe",
      "code": "import { \"moonbitlang/async\" }\n\nasync fn main { println(1) }",
    }),
  )
  match result {
    @posoco.ToolOutcome::ToolReportedError(content~, structured=None) => {
      assert_true(content.contains("must be the handler body"))
      assert_true(content.contains("`source`"))
    }
    _ => fail("full program was not rejected before building")
  }
}

///|
async test "run_code build failure carries compiler diagnostics" {
  let ptc = @posoco-ext-bunraku.BunrakuExtension()
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
