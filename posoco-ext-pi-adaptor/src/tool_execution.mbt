///|
// Tool executor bridge and cancellation diagnostics; runtime effects are handled in runtime_adaptor.

///|
pub fn pi_adaptor_execute_json_async(
  adaptor : PiAdaptor,
  name : String,
  call_id : String,
  arguments_json : String,
) -> JsPromise {
  js_execute_async(adaptor.host, name, call_id, arguments_json)
}

///|
/// Execute a Pi tool correlated to a canonical Posoco EffectId.
pub fn pi_adaptor_execute_effect_json_async(
  adaptor : PiAdaptor,
  effect_id : Int32,
  name : String,
  call_id : String,
  arguments_json : String,
) -> JsPromise {
  js_execute_effect_async(
    adaptor.host,
    effect_id,
    name,
    call_id,
    arguments_json,
  )
}

///|
/// Best-effort cancellation for an in-flight Pi tool call.
pub fn pi_adaptor_cancel_call(adaptor : PiAdaptor, call_id : String) -> Bool {
  js_cancel_call(adaptor.host, call_id)
}

///|
/// Cancel runtime effects and return one canonical disposition per EffectId.
pub fn pi_adaptor_cancel_effects_json(
  adaptor : PiAdaptor,
  effect_ids_json : String,
  reason_json : String,
) -> String {
  js_cancel_effects_json(adaptor.host, effect_ids_json, reason_json)
}

///|
pub fn pi_adaptor_inflight_count(adaptor : PiAdaptor) -> Int32 {
  js_inflight_count(adaptor.host)
}

///|
/// The default ToolProvider path supports Pi tools that return AgentToolResult
/// synchronously. Promise-returning tools require PiRuntime through
/// Agent::with_runtime so execution can suspend without blocking JavaScript.
pub impl @posoco.ToolProvider for PiAdaptor with fn execute(
  adaptor : PiAdaptor,
  ctx : @posoco.ToolCallContext,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let name = ctx.name.to_string()
  let result = js_execute_sync(
    adaptor.host,
    name,
    ctx.call_id.to_string(),
    ctx.arguments.stringify(),
  )
  let structured = parse_optional_json(result.details_json())
  if result.is_error() {
    @posoco.ToolOutcome::ToolReportedError(
      content=result.content(),
      structured~,
    )
  } else {
    @posoco.ToolOutcome::Success(content=result.content(), structured~)
  }
}
