///|
// Pi tool execution, effect cancellation and result normalization (JS target).
// Keep foreign-runtime implementation here; the public Pi/Posoco mapping lives
// in adaptor, event_observer, hook_adaptor, and runtime_adaptor.

///|
extern "js" fn js_execute_sync(
  host : JsPiHost,
  name : String,
  call_id : String,
  arguments_json : String,
) -> JsToolResult =
  #| (host, name, callId, argumentsJson) => {
  #|   const tool = host.state.byName.get(name);
  #|   if (!tool) return syncError(`Unknown Pi tool: ${name}`);
  #|   let params;
  #|   try { params = JSON.parse(argumentsJson); }
  #|   catch (error) { return syncError(`Invalid arguments JSON: ${error.message}`); }
  #|
  #|   const controller = new AbortController();
  #|   const onUpdate = (update) => {
  #|     host.state.updates.push({ effectId: null, callId, name, update });
  #|     host.emitFireAndForget("tool_execution_update", {
  #|       toolCallId: callId,
  #|       toolName: name,
  #|       args: params,
  #|       partialResult: update,
  #|     });
  #|   };
  #|   try {
  #|     const raw = tool.execute(callId, params, controller.signal, onUpdate, host.makeContext());
  #|     if (raw && typeof raw.then === "function") {
  #|       return syncError("Pi tool returned a Promise; use PiRuntime with Agent::with_runtime");
  #|     }
  #|     const normalized = host.normalizePiResult(raw);
  #|     return {
  #|       isError: !normalized.ok,
  #|       content: normalized.content,
  #|       detailsJson: JSON.stringify(normalized.details),
  #|     };
  #|   } catch (error) {
  #|     return syncError(error instanceof Error ? error.message : String(error));
  #|   }
  #|
  #|   function syncError(message) {
  #|     return { isError: true, content: message, detailsJson: JSON.stringify({ error: message }) };
  #|   }
  #| }

///|
/// Execute a Pi tool while preserving Promise and AbortSignal semantics.
extern "js" fn js_execute_async(
  host : JsPiHost,
  name : String,
  call_id : String,
  arguments_json : String,
) -> JsPromise =
  #| (host, name, callId, argumentsJson) => host.executeAsync(name, callId, argumentsJson, null)

///|
/// Effect-correlated execution used by the public Posoco Runtime seam.
extern "js" fn js_execute_effect_async(
  host : JsPiHost,
  effect_id : Int32,
  name : String,
  call_id : String,
  arguments_json : String,
) -> JsPromise =
  #| (host, effectId, name, callId, argumentsJson) => host.executeAsync(name, callId, argumentsJson, effectId)

///|
extern "js" fn js_cancel_call(host : JsPiHost, call_id : String) -> Bool =
  #| (host, callId) => {
  #|   const token = host.state.inflight.get(callId);
  #|   if (!token) return false;
  #|   token.controller.abort();
  #|   return true;
  #| }

///|
extern "js" fn js_cancel_effects_json(
  host : JsPiHost,
  effect_ids_json : String,
  reason_json : String,
) -> String =
  #| (host, effectIdsJson, reasonJson) => {
  #|   const effectIds = JSON.parse(effectIdsJson);
  #|   const reason = JSON.parse(reasonJson);
  #|   return JSON.stringify(effectIds.map((effectId) => {
  #|     const key = String(effectId);
  #|     const token = host.state.effects.get(key);
  #|     if (token) {
  #|       token.controller.abort(reason);
  #|       return { effectId, disposition: "Propagated" };
  #|     }
  #|     if (host.state.settledEffects.has(key)) {
  #|       return { effectId, disposition: "AlreadySettled" };
  #|     }
  #|     return { effectId, disposition: "NotPropagated" };
  #|   }));
  #| }

///|
extern "js" fn js_inflight_count(host : JsPiHost) -> Int32 =
  #| (host) => host.state.inflight.size

///|
extern "js" fn JsToolResult::is_error(self : JsToolResult) -> Bool =
  #| (result) => result.isError === true

///|
extern "js" fn JsToolResult::content(self : JsToolResult) -> String =
  #| (result) => result.content ?? ""

///|
extern "js" fn JsToolResult::details_json(self : JsToolResult) -> String =
  #| (result) => result.detailsJson ?? "null"

///|
/// Cancel one effect and encode its canonical disposition as 0/1/2.
extern "js" fn js_cancel_effect_code(
  host : JsPiHost,
  effect_id : Int32,
  reason_json : String,
) -> Int32 =
  #| (host, effectId, reasonJson) => {
  #|   const key = String(effectId);
  #|   const token = host.state.effects.get(key);
  #|   if (token) {
  #|     let reason = null;
  #|     try { reason = JSON.parse(reasonJson); } catch {}
  #|     token.controller.abort(reason);
  #|     return 0;
  #|   }
  #|   if (host.state.settledEffects.has(key)) return 2;
  #|   return 1;
  #| }
