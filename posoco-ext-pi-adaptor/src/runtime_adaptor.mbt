///|
let pi_owner_id : String = "posoco_ext_pi_adaptor"

///|
/// A runtime decorator that handles Pi-owned tool effects and delegates model,
/// non-Pi tool, cancellation fallback, and compaction work to another runtime.
pub(all) struct PiRuntime {
  adaptor : PiAdaptor
  fallback : &@runtime.Runtime
  mut control : @runtime.RuntimeControl?
}

///|
pub fn PiRuntime::PiRuntime(
  adaptor~ : PiAdaptor,
  fallback~ : &@runtime.Runtime,
) -> PiRuntime {
  { adaptor, fallback, control: None, }
}

///|
/// Attach the Agent-owned control handle after Agent::with_runtime returns.
/// Existing queued follow-ups are flushed first; subsequent Pi triggerTurn
/// messages are forwarded immediately by the JS host callback.
pub fn PiRuntime::attach_control(
  self : PiRuntime,
  control : @runtime.RuntimeControl,
) -> Unit {
  self.control = Some(control)
  for envelope in take_followup_envelopes(self.adaptor) {
    self.enqueue_followup_envelope(envelope) |> ignore
  }
  js_host_set_followup_callback(self.adaptor.host, fn(envelope_json) {
    self.enqueue_followup_envelope(envelope_json) |> ignore
  })
}

///|
fn take_followup_envelopes(adaptor : PiAdaptor) -> Array[String] {
  let raw = @json.parse(js_take_followups_json(adaptor.host)) catch {
    _ => return []
  }
  guard raw is Json::Array(items) else { return [] }
  items.map(fn(item) { item.stringify() })
}

///|
fn followup_message_from_json(envelope_json : String) -> @kernel.Message? {
  let raw = @json.parse(envelope_json) catch { _ => return None }
  guard raw is Json::Object(envelope) else { return None }
  guard envelope.get("message") is Some(Json::Object(message)) else {
    return None
  }
  let text = match message.get("content") {
    Some(Json::String(value)) => value
    Some(value) => value.stringify()
    None => ""
  }
  if text == "" {
    None
  } else {
    Some(@kernel.UserMessage(content=[@kernel.Text(text)]))
  }
}

///|
fn PiRuntime::enqueue_followup_envelope(
  self : PiRuntime,
  envelope_json : String,
) -> @runtime.EnqueueOutcome? {
  guard self.control is Some(control) else { return None }
  guard followup_message_from_json(envelope_json) is Some(message) else {
    return None
  }
  Some(control.enqueue_follow_up(message))
}

///|
/// Versioned catalog source combining static Posoco tools with dynamic Pi tools.
pub(all) struct PiCatalogSource {
  adaptor : PiAdaptor
  base_tools : Array[@kernel.ToolDef]
}

///|
pub fn PiCatalogSource::PiCatalogSource(
  adaptor~ : PiAdaptor,
  base_tools? : Array[@kernel.ToolDef] = [],
) -> PiCatalogSource {
  { adaptor, base_tools, }
}

///|
fn normalized_result_to_outcome(text : String) -> @kernel.ToolOutcome {
  let json = @json.parse(text) catch {
    _ =>
      return @kernel.RuntimeFailure(
        error_category="PiResultParse",
        message="Pi tool returned invalid normalized JSON",
      )
  }
  guard json is Json::Object(fields) else {
    return @kernel.RuntimeFailure(
      error_category="PiResultParse",
      message="Pi tool normalized result must be an object",
    )
  }
  let ok = match fields.get("ok") {
    Some(Json::True) => true
    Some(Json::False) => false
    _ => false
  }
  let content = match fields.get("content") {
    Some(Json::String(value)) => value
    _ => ""
  }
  let structured = match fields.get("details") {
    Some(Json::Null) | None => None
    Some(value) => Some(value)
  }
  if ok {
    @kernel.Success(content~, structured~)
  } else {
    @kernel.ToolReportedError(content~, structured~)
  }
}

///|
async fn execute_pi_effect(
  adaptor : PiAdaptor,
  context : @runtime.EffectContext,
) -> @kernel.ToolOutcome noraise {
  let promise = js_execute_effect_async(
    adaptor.host,
    context.effect_id.to_int(),
    context.tool_name.to_string(),
    context.call_id.to_string(),
    context.arguments.stringify(),
  )
  let result_text = wait_js_string(promise) catch {
    Rejected(reason) =>
      return @kernel.RuntimeFailure(
        error_category="PiPromiseRejected",
        message=reason,
      )
  }
  normalized_result_to_outcome(result_text)
}

///|
fn cancel_reason_json(reason : @kernel.CancelReason) -> String {
  match reason {
    HostRequested(detail~) => {
      let fields : Map[String, Json] = Map::from_array([
        ("kind", Json::string("HostRequested")),
      ])
      fields["detail"] = match detail {
        Some(value) => Json::string(value)
        None => Json::null()
      }
      Json::object(fields).stringify()
    }
    DeadlineReached =>
      Json::object(Map::from_array([("kind", Json::string("DeadlineReached"))])).stringify()
  }
}

///|
fn pi_cancel_disposition(
  adaptor : PiAdaptor,
  effect_id : @kernel.EffectId,
  reason_json : String,
) -> @kernel.CancelDisposition {
  match js_cancel_effect_code(adaptor.host, effect_id.to_int(), reason_json) {
    0 => @kernel.Propagated
    2 => @kernel.AlreadySettled
    _ => @kernel.NotPropagated
  }
}

///|
pub impl @runtime.Runtime for PiRuntime with fn call_model(
  self,
  scope : @kernel.InvocationScope,
  messages : ArrayView[@kernel.Message],
  tool_definitions : Array[@kernel.ToolDef],
  call_options : Json,
  on_chunk : ((@posoco.StreamChunk) -> Unit)?,
) -> Result[@kernel.ModelCallResult, @kernel.ModelFailure] {
  self.fallback.call_model(
    scope, messages, tool_definitions, call_options, on_chunk,
  )
}

///|
pub impl @runtime.Runtime for PiRuntime with fn execute_tool(
  self,
  context : @runtime.EffectContext,
) -> @kernel.ToolOutcome {
  if context.owner.to_string() == pi_owner_id {
    execute_pi_effect(self.adaptor, context)
  } else {
    self.fallback.execute_tool(context)
  }
}

///|
pub impl @runtime.Runtime for PiRuntime with fn cancel_effects(
  self,
  effect_ids : Array[@kernel.EffectId],
  reason : @kernel.CancelReason,
) -> Array[(@kernel.EffectId, @kernel.CancelDisposition)] {
  let reason_json = cancel_reason_json(reason)
  let local_results : Map[Int, @kernel.CancelDisposition] = Map::from_array([])
  let needs_fallback : Array[@kernel.EffectId] = []
  for effect_id in effect_ids {
    let disposition = pi_cancel_disposition(
      self.adaptor,
      effect_id,
      reason_json,
    )
    local_results[effect_id.to_int()] = disposition
    if disposition is @kernel.NotPropagated {
      needs_fallback.push(effect_id)
    }
  }
  let delegated : Map[Int, @kernel.CancelDisposition] = Map::from_array([])
  if !needs_fallback.is_empty() {
    for pair in self.fallback.cancel_effects(needs_fallback, reason) {
      let (effect_id, disposition) = pair
      delegated[effect_id.to_int()] = disposition
    }
  }
  effect_ids.map(fn(effect_id) {
    let key = effect_id.to_int()
    let disposition = match local_results.get(key) {
      Some(@kernel.NotPropagated) =>
        match delegated.get(key) {
          Some(value) => value
          None => @kernel.NotPropagated
        }
      Some(value) => value
      None => @kernel.NotPropagated
    }
    (effect_id, disposition)
  })
}

///|
pub impl @runtime.Runtime for PiRuntime with fn compact(
  self,
  scope : @kernel.InvocationScope,
  messages : ArrayView[@kernel.Message],
  call_options : Json,
  trigger : @kernel.CompactTrigger,
) -> Result[@kernel.CompactResult, @kernel.ModelFailure] {
  self.fallback.compact(scope, messages, call_options, trigger)
}

///|
pub impl @runtime.CatalogSource for PiCatalogSource with fn revision(self) -> Int {
  js_catalog_revision(self.adaptor.host)
}

///|
pub impl @runtime.CatalogSource for PiCatalogSource with fn tools(self) -> Array[
  @kernel.ToolDef,
] {
  let snapshot : Array[@kernel.ToolDef] = []
  for tool in self.base_tools {
    snapshot.push(tool)
  }
  for tool in self.adaptor.list_tools() {
    snapshot.push(tool)
  }
  snapshot
}

///|
pub extend PiRuntime with @runtime.Runtime::{
  call_model,
  execute_tool,
  cancel_effects,
  compact,
}

///|
pub extend PiCatalogSource with @runtime.CatalogSource::{revision, tools}

///|
/// Execute through the same MoonBit Promise bridge used by PiRuntime.
/// Node/Bun tests use this export to prove the coroutine resumes after a real
/// Pi Promise resolves.
pub fn pi_adaptor_execute_effect_via_runtime(
  adaptor : PiAdaptor,
  effect_id : Int,
  name : String,
  call_id : String,
  arguments_json : String,
  callback : (String) -> Unit,
) -> Unit {
  let task : async () -> Unit noraise = async fn() noraise {
    let arguments = @json.parse(arguments_json) catch { _ => Json::null() }
    let context : @runtime.EffectContext = {
      effect_id: @kernel.EffectId::{ value: effect_id, },
      owner: @kernel.OwnerId::unchecked(pi_owner_id),
      call_id: @kernel.CallId::unchecked(call_id),
      tool_name: @kernel.ToolName::unchecked(name),
      arguments,
    }
    let outcome = execute_pi_effect(adaptor, context)
    let output = match outcome {
      @kernel.Success(content~, structured~) =>
        Json::object(
          Map::from_array([
            ("kind", Json::string("Success")),
            ("content", Json::string(content)),
            (
              "structured",
              match structured {
                Some(value) => value
                None => Json::null()
              },
            ),
          ]),
        ).stringify()
      @kernel.ToolReportedError(content~, structured~) =>
        Json::object(
          Map::from_array([
            ("kind", Json::string("ToolReportedError")),
            ("content", Json::string(content)),
            (
              "structured",
              match structured {
                Some(value) => value
                None => Json::null()
              },
            ),
          ]),
        ).stringify()
      @kernel.RuntimeFailure(error_category~, message~) =>
        Json::object(
          Map::from_array([
            ("kind", Json::string("RuntimeFailure")),
            ("errorCategory", Json::string(error_category)),
            ("message", Json::string(message)),
          ]),
        ).stringify()
      @kernel.NotExecuted(reason~, original_call_id~) => {
        ignore(reason)
        ignore(original_call_id)
        Json::object(Map::from_array([("kind", Json::string("NotExecuted"))])).stringify()
      }
    }
    callback(output)
  }
  // Schedule through the async runtime's coroutine registry (like the real
  // turn path), not the bare %async.run root: the root has no current
  // coroutine, so Promise-based waits cannot park there.
  ignore(@js_async.Promise::from_async(async fn() { task() }))
}
