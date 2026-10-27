///|
/// Bound compiler diagnostics returned to the model. The full build output
/// remains host-side; repeated model retries must not carry 30KB+ diagnostics.
pub fn ptc_bounded_diagnostics(value : String) -> String {
  let limit = 8192
  let chars : Array[Char] = []
  for char in value {
    if chars.length() >= limit {
      return String::from_array(chars) +
        "\\n...[compiler diagnostics truncated at 8192 characters]"
    }
    chars.push(char)
  }
  value
}

///|
/// Model-facing PTC wrapper over the extension-owned MBTX guest runtime.
///
/// IMPORTANT: Posoco 0.22.1 has no governed nested-tool invocation port.
/// \`scoped_invoker\` is an externally injected, trusted integration point.
/// A missing bridge is a hard fail-closed state for nested calls, never
/// permission to invoke wrapped ToolProviders directly.
pub struct BunrakuExtension {
  priv runtime : @mbtx.Runtime
  priv tool_names : Array[String]
  priv scoped_invoker : &ToolInvoker?
  priv call_observers : Array[(NestedCallEvent) -> Unit]
  priv max_output_bytes : Int32
  priv traces : Map[String, Array[@mbtx.ToolCallTrace]]
  priv mut tasks : @posoco.Tasks?
  priv task_session : (() -> String)?
  priv mut next_task_id : Int32
}

///|
/// Only the PTC transport is model-visible. Do NOT also compose the wrapped
/// native ToolProviders into this agent's visible catalog; doing so duplicates
/// model schemas and permits direct calls that bypass the PTC presentation.
///
/// Tool definitions are for SDK discoverability, NOT authority. Only the
/// supplied scoped invoker can execute nested calls under host governance.
/// Without it, ctx.call() is explicitly unavailable; pure code still runs.
pub fn BunrakuExtension::BunrakuExtension(
  exposed~ : Array[@posoco.ToolDef] = [],
  scoped_invoker? : &ToolInvoker,
  call_observers~ : Array[(NestedCallEvent) -> Unit] = [],
  bus? : @devkit.EventBus,
  home? : String,
  max_output_bytes~ : Int32 = 65536,
  build_cache? : String,
  task_session? : () -> String,
) -> BunrakuExtension {
  let tool_names : Array[String] = []
  for def in exposed {
    let name = def.name.to_string()
    if name != "run_code" && !tool_names.contains(name) {
      tool_names.push(name)
    }
  }
  {
    runtime: @mbtx.Runtime(
      bus?,
      home?,
      build_cache=build_cache.unwrap_or_else(() => {
        let path = home.unwrap_or(@devkit.home_dir().unwrap_or(""))
        if path == "" {
          ""
        } else {
          path + "/.cetas/ptc_build_cache"
        }
      }),
    ),
    tool_names,
    scoped_invoker,
    call_observers: call_observers.copy(),
    max_output_bytes,
    traces: Map([]),
    tasks: None,
    task_session,
    next_task_id: 0,
  }
}

///|
pub fn BunrakuExtension::allowed_tools(
  self : BunrakuExtension,
) -> Array[String] {
  self.tool_names.copy()
}

///|
pub fn BunrakuExtension::toolchain_status(self : BunrakuExtension) -> String {
  self.runtime.toolchain_status()
}

///|
/// Snapshot of completed nested tool requests for one enclosing effect.
/// This diagnostic channel is not included in the model-facing final result.
pub fn BunrakuExtension::trace(
  self : BunrakuExtension,
  effect_id : String,
) -> Array[@mbtx.ToolCallTrace] {
  match self.traces.get(effect_id) {
    Some(calls) => calls.copy()
    None => []
  }
}

///|
pub impl @posoco.Extension for BunrakuExtension with fn extension_id(
  _self : BunrakuExtension,
) -> String {
  "posoco_ext_bunraku"
}

///|
pub impl @posoco.Extension for BunrakuExtension with fn manifest(
  self : BunrakuExtension,
) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(
    id="posoco_ext_bunraku",
    tools=[self],
    prompt_contributors=[self],
    lifecycle=[self],
    requires=[@posoco.Capability::Tasks],
    // Nested invocation face, owner-level and default-deny: a guest ctx.call
    // may only reach these owners' tools, through the kernel child pipeline.
    // Same single source as bunraku_tool_call_owners().
    tool_call_owners=bunraku_nested_source_owners(),
  )
}

///|
pub extend BunrakuExtension with @posoco.Extension::{manifest, extension_id}

///|
pub impl @posoco.ToolProvider for BunrakuExtension with fn list_tools(
  _self : BunrakuExtension,
) -> Array[@posoco.ToolDef] {
  [
    @posoco.ToolDef(
      name=@posoco.ToolName::unchecked("run_code"),
      description="Optional MoonBit batching. Select only when several predictable tool calls can run without further model judgment and keeping intermediate results local saves tokens. For single calls, uncertain next steps, or high compilation overhead, use the existing tools instead. Supply code or source, not both; return concise final JSON.",
      input_schema={
        "type": "object",
        "properties": {
          "background": {
            "type": "boolean",
            "description": "Adopt execution as an Agent-owned background task when session attribution is available.",
          },
          "source": {
            "type": "string",
            "description": "Full MoonBit .mbtx source: import posoco/ears@0.1.0 and use @ears.serve(run). Exclusive with code.",
          },
          "code": {
            "type": "string",
            "description": "Body of the run_code guest handler: statements using ctx.call(name, args) and input. Exclusive with source.",
          },
          "input": { "description": "JSON input supplied to the program" },
          "description": {
            "type": "string",
            "description": "Brief summary of what the program will do",
          },
        },
        "required": ["description"],
        "additionalProperties": false,
      },
      owner=@posoco.OwnerId::unchecked("posoco_ext_bunraku"),
      policy=@posoco.ExecutionPolicy::Sequential,
      provenance=Some("posoco_ext_bunraku"),
    ),
  ]
}

///|
pub extend BunrakuExtension with @posoco.ToolProvider::{list_tools, execute}

///|
pub impl @posoco.ToolProvider for BunrakuExtension with fn execute(
  self : BunrakuExtension,
  ctx : @posoco.ToolCallContext,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  if ctx.name.to_string() != "run_code" {
    return @posoco.ToolOutcome::ToolReportedError(
      content="PTC accepts run_code only",
      structured=None,
    )
  }
  let input = match ctx.arguments {
    { "input": value, .. } => value
    _ => Json::null()
  }
  let source = match ctx.arguments {
    { "source": String(_), "code": _, .. } =>
      return @posoco.ToolOutcome::ToolReportedError(
        content="run_code: specify source or code, not both",
        structured=None,
      )
    { "source": String(source), .. } => source
    { "code": String(code), .. } =>
      match reject_wrapped_code(code) {
        Some(message) =>
          return @posoco.ToolOutcome::ToolReportedError(
            content=message,
            structured=None,
          )
        None => inline_guest_source(code)
      }
    _ =>
      return @posoco.ToolOutcome::ToolReportedError(
        content="run_code: expected code or source",
        structured=None,
      )
  }
  if source.trim().is_empty() || source.length() > 100000 {
    return @posoco.ToolOutcome::ToolReportedError(
      content="run_code: source must be 1..100000 bytes",
      structured=None,
    )
  }
  // Background tasks are Agent-owned. They must have a host-supplied
  // session identity and an active composed Tasks capability; model input
  // can request handoff but can never select the owning session.
  if ctx.arguments is { "background": true, .. } {
    let tasks = match self.tasks {
      Some(value) => value
      None =>
        return @posoco.ToolOutcome::ToolReportedError(
          content="PTC background tasks are unavailable outside an Agent scope",
          structured=None,
        )
    }
    let session = match self.task_session {
      Some(get_session) => get_session()
      None => ""
    }
    if session == "" {
      return @posoco.ToolOutcome::ToolReportedError(
        content="PTC background session attribution is missing",
        structured=None,
      )
    }
    self.next_task_id += 1
    let invocation_id = session +
      ":ptc-background-" +
      self.next_task_id.to_string()
    let label = match ctx.arguments {
      { "description": String(description), .. } => description
      _ => "PTC background program"
    }
    let spec : @posoco.TaskSpec = {
      session_id: session,
      mode: @posoco.TaskMode::Background,
      label,
      timeout_ms: Some(300000),
      run: async fn() {
        let outcome = self.execute_source(
          source,
          input,
          invocation_id,
          parent_call=ctx.call_id.to_string(),
          on_call=None,
          face=self.tool_names,
        )
        let content = match outcome {
          @kernel.ToolOutcome::Success(content~, structured=_) => content
          @kernel.ToolOutcome::ToolReportedError(content~, structured=_) =>
            content
          _ => "PTC program failed"
        }
        @kernel.Message::UserMessage(content=[
          @kernel.Content::Text("PTC background result: " + content),
        ])
      },
    }
    return match tasks.submit(spec) {
      Ok(handle) =>
        @posoco.ToolOutcome::Success(
          content="PTC background task accepted: " + handle.receipt().id,
          structured=Some({ "task_id": handle.receipt().id }),
        )
      Err(_) =>
        @posoco.ToolOutcome::ToolReportedError(
          content="PTC background task was not admitted",
          structured=None,
        )
    }
  }
  let invocation_id = ctx.effect_id.to_string()
  (ctx.register_cancel)(self as &@posoco.ToolCancellable)
  // Kernel-wired nested face: when the executor supplied the child-pipeline
  // context, derive both the invoker and the guest-visible tool list from
  // it (ToolCallContext::tools is the kernel-computed face — non-Disabled
  // definitions owned by an allowed owner). An injected scoped_invoker or an
  // empty kernel face keeps the previous behavior: the exposed list plus
  // the injected bridge, or a hard fail-closed ToolInvocationUnavailable.
  let kernel_face = ctx.tools()
  let on_call : (async (String, Json) -> @mbtx.Outcome)? = match
    self.scoped_invoker {
    Some(invoker) => Some((name, args) => invoker.invoke(name, args))
    None =>
      if kernel_face.is_empty() {
        None
      } else {
        let kernel_invoker = KernelScopedInvoker(ctx~) as &ToolInvoker
        Some((name, args) => kernel_invoker.invoke(name, args))
      }
  }
  let guest_face : Array[String] = if kernel_face.is_empty() {
    self.tool_names
  } else {
    kernel_face.map(fn(def) { def.name.to_string() })
  }
  self.execute_source(
    source,
    input,
    invocation_id,
    parent_call=ctx.call_id.to_string(),
    on_call~,
    face=guest_face,
  ) catch {
    error =>
      @posoco.ToolOutcome::ToolReportedError(
        content="run_code failed: " + error.to_string(),
        structured=None,
      )
  }
}

///|
/// This helper is shared by foreground ToolProvider execution and Agent-owned
/// background tasks; each receives a unique invocation ID.
async fn BunrakuExtension::execute_source(
  self : BunrakuExtension,
  source : String,
  input : Json,
  invocation_id : String,
  parent_call~ : String,
  on_call~ : (async (String, Json) -> @mbtx.Outcome)?,
  face~ : Array[String],
) -> @posoco.ToolOutcome {
  // The tool-agnostic runtime forwards the guest's call frames to this
  // handler; governance stays on this side of the seam. `on_call` is either
  // the host-injected bridge or the kernel child pipeline derived from the
  // enclosing ToolCallContext; `face` is the guest-visible tool list.
  let effective_on_call : (async (String, Json) -> @mbtx.Outcome)? = match
    on_call {
    Some(injected) => Some(injected)
    None =>
      match self.scoped_invoker {
        Some(invoker) => Some((name, args) => invoker.invoke(name, args))
        None => None
      }
  }
  let result = self.runtime.run(
    source,
    input,
    invocation_id~,
    tools=face,
    on_call?=effective_on_call,
    max_output_bytes=self.max_output_bytes,
  ) catch {
    // Error payloads (build diagnostics, stderr, reasons) are the model's
    // only self-correction signal, so each variant renders them verbatim;
    // `Error::to_string` renders only the constructor path.
    @mbtx.RuntimeError::BuildFailed(diagnostics) =>
      return @posoco.ToolOutcome::ToolReportedError(
        content="run_code build failed — the program never ran; the output below is the compiler's:\n" +
          ptc_bounded_diagnostics(diagnostics),
        structured=None,
      )
    @mbtx.RuntimeError::TimedOut(phase) =>
      return @posoco.ToolOutcome::ToolReportedError(
        content="run_code timed out during the \{phase} phase — nothing partial is returned",
        structured=None,
      )
    @mbtx.RuntimeError::GuestFailure(message) =>
      return @posoco.ToolOutcome::ToolReportedError(
        content="run_code guest process failed: " + message,
        structured=None,
      )
    @mbtx.RuntimeError::ToolchainUnavailable(message) =>
      return @posoco.ToolOutcome::ToolReportedError(
        content="run_code toolchain unavailable: " + message,
        structured=None,
      )
    @mbtx.RuntimeError::ProtocolFailure(reason) =>
      return @posoco.ToolOutcome::ToolReportedError(
        content="run_code protocol failure: " + reason,
        structured=None,
      )
    @mbtx.RuntimeError::Invalid(reason) =>
      return @posoco.ToolOutcome::ToolReportedError(
        content="run_code invalid invocation: " + reason,
        structured=None,
      )
    @mbtx.RuntimeError::Cancelled =>
      return @posoco.ToolOutcome::ToolReportedError(
        content="run_code was cancelled before completing; no result was produced",
        structured=None,
      )
    @mbtx.RuntimeError::Closed =>
      return @posoco.ToolOutcome::ToolReportedError(
        content="run_code runtime is closed",
        structured=None,
      )
    error =>
      return @posoco.ToolOutcome::ToolReportedError(
        content="run_code failed: " + error.to_string(),
        structured=None,
      )
  }
  self.traces[invocation_id] = result.calls.copy()
  // One append-only terminal fact per nested call: the enclosing run_code
  // call is the visible observer node, and these hang beneath it so flow
  // renderers can draw the guest's fan-out without fabricating states.
  for call in result.calls {
    let event : NestedCallEvent = {
      parent_call,
      request_id: call.request_id,
      name: call.name,
      arguments: call.arguments,
      outcome: call.outcome.to_json(),
    }
    for observer in self.call_observers {
      observer(event)
    }
  }
  match result.outcome {
    @protocol.Success(content~, structured~) =>
      @posoco.ToolOutcome::Success(content~, structured~)
    @protocol.Failure(code~, content~, structured~) =>
      @posoco.ToolOutcome::ToolReportedError(
        content=code + ": " + content,
        structured~,
      )
  }
}

///|
pub impl @posoco.ToolCancellable for BunrakuExtension with fn cancel(
  self : BunrakuExtension,
  run_id~ : @kernel.RunId,
  effect_id : @kernel.EffectId,
  _reason : @kernel.CancelReason,
) -> @kernel.CancelDisposition {
  ignore(run_id)
  if self.runtime.cancel(effect_id.to_string()) {
    @kernel.CancelDisposition::Propagated
  } else {
    @kernel.CancelDisposition::NotPropagated
  }
}

///|
pub extend BunrakuExtension with @posoco.ToolCancellable::{cancel}

///|
pub impl @posoco.Lifecycle for BunrakuExtension with fn on_compose(
  self : BunrakuExtension,
  ctx : @posoco.CompositionView,
) -> Unit {
  self.tasks = ctx.tasks()
}

///|
pub impl @posoco.Lifecycle for BunrakuExtension with fn on_shutdown(
  self : BunrakuExtension,
) -> Unit {
  self.runtime.close()
}

///|
pub extend BunrakuExtension with @posoco.Lifecycle::{
  on_shutdown,
  on_start,
  on_compose,
}
