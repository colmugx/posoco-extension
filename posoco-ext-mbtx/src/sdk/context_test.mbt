///|
struct FakeTools {}

///|
impl @sdk.ToolClient for FakeTools with fn call(_self, name, arguments) {
  @protocol.Success(content=name, structured=Some(arguments))
}

///|
async test "guest receives structured outcomes and cannot call outside its scope" {
  let ctx = @sdk.Context(tools=FakeTools::{ }, allowed=["read"])
  assert_eq(
    ctx.call("read", { "value": 42 }),
    @protocol.Success(content="read", structured=Some({ "value": 42 })),
  )
  assert_true(
    ctx.call("write", {}) is @protocol.Failure(code="CapabilityDenied", ..),
  )
  ctx.close()
  assert_true(ctx.call("read", {}) is @protocol.Failure(code="ScopeClosed", ..))
}
