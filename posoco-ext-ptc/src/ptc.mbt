///|
/// Model-facing PTC wrapper over the extension-owned MBTX guest runtime.
///
/// IMPORTANT: Posoco 0.22.1 has no governed nested-tool invocation port.
/// \`scoped_invoker\` is an externally injected, trusted integration point.
/// A missing bridge is a hard fail-closed state for nested calls, never
/// permission to invoke wrapped ToolProviders directly.
pub struct PtcExtension {
  priv runtime : @mbtx.Runtime
  priv exposed : Array[@posoco.ToolDef]
  priv tool_names : Array[String]
  priv scoped_invoker : &@mbtx.ToolInvoker?
  priv max_output_bytes : Int32
  priv traces : Map[String, Array[@mbtx.ToolCallTrace]]
}

///|
/// Only the PTC transport is model-visible. Do NOT also compose the wrapped
/// native ToolProviders into this agent's visible catalog; doing so duplicates
/// model schemas and permits direct calls that bypass the PTC presentation.
///
/// Tool definitions are for SDK discoverability, NOT authority. Only the
/// supplied scoped invoker can execute nested calls under host governance.
/// Without it, ctx.call() is explicitly unavailable; pure code still runs.
pub fn PtcExtension::PtcExtension(
  exposed~ : Array[@posoco.ToolDef] = [],
  scoped_invoker? : &@mbtx.ToolInvoker,
  bus? : @devkit.EventBus,
  home? : String,
  max_output_bytes~ : Int32 = 65536,
  build_cache? : String,
) -> PtcExtension {
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
        if path == "" { "" } else { path + "/.cetas/ptc_build_cache" }
      }),
    ),
    exposed: exposed.copy(),
    tool_names,
    scoped_invoker,
    max_output_bytes,
    traces: Map([]),
  }
}

///|
pub fn PtcExtension::allowed_tools(self : PtcExtension) -> Array[String] {
  self.tool_names.copy()
}

///|
pub fn PtcExtension::toolchain_status(self : PtcExtension) -> String {
  self.runtime.toolchain_status()
}


///|
/// Snapshot of completed nested tool requests for one enclosing effect.
/// This diagnostic channel is not included in the model-facing final result.
pub fn PtcExtension::trace(
  self : PtcExtension,
  effect_id : String,
) -> Array[@mbtx.ToolCallTrace] {
  match self.traces.get(effect_id) {
    Some(calls) => calls.copy()
    None => []
  }
}

///|
pub impl @posoco.Extension for PtcExtension with fn extension_id(
  _self : PtcExtension,
) -> String {
  "posoco_ext_ptc"
}

///|
pub impl @posoco.Extension for PtcExtension with fn manifest(
  self : PtcExtension,
) -> @posoco.ExtensionManifest {
  @posoco.ExtensionManifest(
    id="posoco_ext_ptc",
    tools=[self],
    prompt_contributors=[self],
    lifecycle=[self],
  )
}

///|
pub extend PtcExtension with @posoco.Extension::{manifest, extension_id}

///|
pub impl @posoco.ToolProvider for PtcExtension with fn list_tools(
  _self : PtcExtension,
) -> Array[@posoco.ToolDef] {
  [{
    name: @posoco.ToolName::unchecked("run_code"),
    description: "Execute a MoonBit program with filtered nested tool calls. Return only the final JSON value. Use for multi-step search, filtering and summarization.",
    input_schema: {
      "type": "object",
      "properties": {
        "source": {
          "type": "string",
          "description": "Full MoonBit .mbtx source; import the MBTX SDK and use @mbtx.serve(run). Exclusive with code."
        },
        "code": {
          "type": "string",
          "description": "Body of async fn ptc_run(ctx: PtcContext, input: Json) -> Json. Call ctx.call(name, args), inspect results, return a JSON value."
        },
        "input": {
          "description": "JSON input supplied to the program"
        },
        "description": {
          "type": "string",
          "description": "Brief summary of what the program will do"
        },
      },
      "required": ["description"],
      "oneOf": [{"required": ["code"]}, {"required": ["source"]}],
      "additionalProperties": false,
    },
    owner: @posoco.OwnerId::unchecked("posoco_ext_ptc"),
    policy: @posoco.ExecutionPolicy::Sequential,
    provenance: Some("posoco_ext_ptc"),
  }]
}

///|
pub extend PtcExtension with @posoco.ToolProvider::{list_tools, execute}

///|
pub impl @posoco.ToolProvider for PtcExtension with fn execute(
  self : PtcExtension,
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
    { "source": String(source), "code": _, .. } =>
      return @posoco.ToolOutcome::ToolReportedError(
        content="run_code: specify source or code, not both",
        structured=None,
      )
    { "source": String(source), .. } => source
    { "code": String(code), .. } => ptc_guest_source(code)
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
  // Effect identity, not a user-controlled invocation id. Cancellation can
  // only address the currently owned guest process.
  let invocation_id = ctx.effect_id.to_string()
  (ctx.register_cancel)(self as &@posoco.ToolCancellable)
  let result = self.runtime.run(
    source,
    input,
    invocation_id~,
    tools=self.tool_names,
    invoker?=self.scoped_invoker,
    max_output_bytes=self.max_output_bytes,
  ) catch {
    error =>
      return @posoco.ToolOutcome::ToolReportedError(
        content="run_code failed: " + error.to_string(),
        structured=None,
      )
  }
  self.traces[invocation_id] = result.calls.copy()
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
pub impl @posoco.ToolCancellable for PtcExtension with fn cancel(
  self : PtcExtension,
  effect_id : @kernel.EffectId,
  _reason : @kernel.CancelReason,
) -> @kernel.CancelDisposition {
  if self.runtime.cancel(effect_id.to_string()) {
    @kernel.CancelDisposition::Propagated
  } else {
    @kernel.CancelDisposition::NotPropagated
  }
}

///|
pub extend PtcExtension with @posoco.ToolCancellable::{cancel}

///|
pub impl @posoco.Lifecycle for PtcExtension with fn on_shutdown(
  self : PtcExtension,
) -> Unit {
  self.runtime.close()
}

///|
pub extend PtcExtension with @posoco.Lifecycle::{on_shutdown, on_start, on_compose}
