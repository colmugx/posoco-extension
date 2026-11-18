///|
/// posoco-ext-lazytools — operation-time deferral of tool schemas.
///
/// The gateway owns no provider and enumerates no tool at composition time.
/// It declares which extension owners are deferred, narrows those definitions
/// to `ToolExposure::Deferred` at every operation capture, and reaches them
/// through the kernel child pipeline (`ToolCallContext::invoke`). A deferred
/// definition stays in the captured catalog but never enters a model request,
/// so groups published AFTER composition — live MCP connections, runtime
/// toolkits — are deferred exactly like static ones.

///|
/// One deferred owner: the manifest id whose tools leave the model request,
/// plus the one-line hint kept in the resident prompt so keyword discovery
/// works before any schema has been fetched. An empty hint is allowed.
pub(all) struct DeferredGroup {
  owner : String
  hint : String
}

///|
/// Stable manifest hook: removes a `<lazytools-context>` envelope older
/// releases persisted into the transcript. Kept as a one-time migration —
/// a legacy envelope in history invalidates provider prefix caching from its
/// position onward.
priv struct StableLazyToolsHook {}

///|
fn is_legacy_lazytools_context(message : @posoco.Message) -> Bool {
  match message {
    @posoco.Message::UserMessage(content~) =>
      content
      .iter()
      .any(fn(block) {
        match block {
          @posoco.Content::Text(text) => text.has_prefix("<lazytools-context")
          _ => false
        }
      })
    _ => false
  }
}

///|
/// Migration-only rewrite: old releases persisted a usage-driven
/// `<lazytools-context>` message. Remove it once so stale guidance does not
/// remain in long-lived sessions. When no legacy envelope exists, return the
/// exact input array and generate no TranscriptRewrite.
impl @posoco.PipelineHook for StableLazyToolsHook with fn before_model(
  _self,
  messages : Array[@posoco.Message],
) -> Array[@posoco.Message] {
  let kept : Array[@posoco.Message] = []
  let mut changed = false
  for message in messages {
    if is_legacy_lazytools_context(message) {
      changed = true
    } else {
      kept.push(message)
    }
  }
  if changed {
    kept
  } else {
    messages
  }
}

///|
/// The deferral gateway. Opaque: compose via `LazyTools::new`.
pub struct LazyTools {
  priv groups : Array[DeferredGroup]
  priv owners : Array[String]
  priv deferred : Map[String, Bool]
  priv stable_hook : StableLazyToolsHook
  /// Optional semantic judgement capability used only after lexical discovery misses.
  priv mut decision : &@posoco.DecisionPort?
}

///|
/// Declare the deferred owner set. Every tool whose aggregated owner is one of
/// these manifest ids is narrowed to `Deferred` at each operation capture and
/// becomes reachable only through `tool_execute`.
///
/// Fails with `Err` for an empty owner (a group that can never match) and for
/// a duplicate owner (two hints for one face).
///
/// # Example
/// ```mbt check
/// test "lazytools exposes exactly the two meta tools" {
///   let ext = match
///     @posoco-ext-lazytools.LazyTools::new(groups=[
///       @posoco-ext-lazytools.DeferredGroup::{
///         owner: "posoco_ext_webfetch",
///         hint: "fetch URLs",
///       },
///     ]) {
///     Ok(ext) => ext
///     Err(msg) => fail("unexpected defer error: \{msg}")
///   }
///   let names = ext.list_tools().map(fn(def) { def.name.to_string() })
///   assert_eq(names.length(), 2)
///   assert_true(names.contains("tool_list"))
///   assert_true(names.contains("tool_execute"))
///   assert_eq(ext.deferred_owners(), ["posoco_ext_webfetch"])
/// }
/// ```
pub fn LazyTools::new(
  groups~ : Array[DeferredGroup],
) -> Result[LazyTools, String] {
  let owners : Array[String] = []
  let deferred : Map[String, Bool] = Map::from_array([])
  for group in groups {
    let owner = group.owner
    if owner == "" {
      return Err("lazytools: a deferred group declares an empty owner")
    }
    if deferred.contains(owner) {
      return Err("lazytools: duplicate deferred owner '\{owner}'")
    }
    deferred[owner] = true
    owners.push(owner)
  }
  Ok({
    groups,
    owners,
    deferred,
    stable_hook: StableLazyToolsHook::{ },
    decision: None,
  })
}

///|
/// The declared deferred owner ids, in declaration order.
pub fn LazyTools::deferred_owners(self : LazyTools) -> Array[String] {
  self.owners.copy()
}

///|
/// Is `owner` one of the declared deferred owners?
pub fn LazyTools::is_deferred_owner(self : LazyTools, owner : String) -> Bool {
  self.deferred.contains(owner)
}

///|
/// Port contribution: exactly the two meta tools. Deferred definitions never
/// pass through here — they stay in the kernel catalog under their own owner
/// and are hidden from the model by `tool_exposure`.
pub impl @posoco.ToolProvider for LazyTools with fn list_tools(
  _self : LazyTools,
) -> Array[@posoco.ToolDef] {
  meta_tool_defs()
}

///|
/// Route a meta-tool call. `tool_list` answers from the operation's captured
/// catalog; `tool_execute` re-enters the kernel child pipeline, so the child
/// keeps schema validation, the owner gate, the composed hook chain,
/// budget/depth accounting and cancellation — exactly as if the model had
/// called it directly.
pub impl @posoco.ToolProvider for LazyTools with fn execute(
  self : LazyTools,
  ctx : @posoco.ToolCallContext,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let name = ctx.name.to_string()
  let call : @posoco.ToolCall = {
    call_id: ctx.call_id,
    name: ctx.name,
    arguments: ctx.arguments,
  }
  match name {
    "tool_list" => self.execute_list(ctx, call)
    "tool_execute" => self.execute_deferred(ctx, call)
    _ =>
      raise @posoco.RuntimeError::UnknownTool(
        "lazytools: no tool named '\{name}'",
      )
  }
}

///|
/// Operation-boundary projection: declared owners leave the model request.
/// Hooks may only narrow, so `Direct` stays `Direct` for every other owner and
/// the gateway's own meta tools can never defer themselves.
pub impl @posoco.PipelineHook for LazyTools with fn tool_exposure(
  self : LazyTools,
  definition : @posoco.ToolDef,
) -> @posoco.ToolExposure {
  let name = definition.name.to_string()
  if name == "tool_list" || name == "tool_execute" {
    return @posoco.ToolExposure::Direct
  }
  if self.is_deferred_owner(definition.owner.to_string()) {
    @posoco.ToolExposure::Deferred
  } else {
    @posoco.ToolExposure::Direct
  }
}
