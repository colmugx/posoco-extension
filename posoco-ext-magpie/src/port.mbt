///|
/// port.mbt — the Magpie ModelPort.
///
/// `MagpieModelPort` turns the manager's active selection plus a validated
/// `MagpieProtocolPlan` into Posoco model execution. Every call re-plans
/// from the current catalog, so a plan is always validated against the
/// catalog it will run against; a selection that is pending, absent, or
/// unplannable raises before any request is sent. There is no fallback
/// between models or protocols, and no automatic retries: one call is one
/// plan, one endpoint, one attempt.

///|
/// Execution-time strictness dials. Each one becomes a hard requirement in
/// the execution plan; an unguaranteed requirement under `NativeOnly`
/// yields an explicit error instead of a silent lossy call.
pub struct MagpieModelPort {
  priv manager : MagpieManager
  priv transport : &MagpieTransport
  priv policy : MagpieTranslationPolicy
  priv preference : MagpiePreference
  priv require_signed_thinking_replay : Bool
  priv require_native_prompt_caching : Bool
  priv require_reasoning_output : Bool
  /// Observability sink invoked once per completed execution with the
  /// execution report. Failures and planning rejections produce no report.
  priv report_sink : (MagpieExecutionReport) -> Unit
}

///|
pub fn MagpieModelPort::MagpieModelPort(
  manager~ : MagpieManager,
  transport~ : &MagpieTransport = HttpMagpieTransport::HttpMagpieTransport(),
  policy~ : MagpieTranslationPolicy = NativeOnly,
  preference~ : MagpiePreference = Any,
  require_signed_thinking_replay~ : Bool = false,
  require_native_prompt_caching~ : Bool = false,
  require_reasoning_output~ : Bool = false,
  report_sink~ : (MagpieExecutionReport) -> Unit = fn(_report) { () },
) -> MagpieModelPort {
  {
    manager,
    transport,
    policy,
    preference,
    require_signed_thinking_replay,
    require_native_prompt_caching,
    require_reasoning_output,
    report_sink,
  }
}

///|
/// Manual-compact parity default: keep the most recent tokens verbatim and
/// summarize the head. Unknown windows are never guessed; auto-compact only
/// arms itself on a declared catalog window.
const COMPACT_KEEP_RECENT_TOKENS : Int32 = 20000

///|
/// Resolves the active selection into an executable call context, planning
/// fresh against the current catalog. Raises before any request when the
/// selection is pending/absent or no protocol satisfies the requirements.
fn MagpieModelPort::prepare_execution(
  self : MagpieModelPort,
  scope : @posoco.InvocationScope,
  entry_requirements~ : MagpieRequirements,
) -> ExecCall raise @posoco.ModelError {
  let selection = self.manager.active_selection()
  if selection.pending {
    raise @posoco.ModelError::RequestBuild(
      "magpie request build failure (stage=selection): model \"\{selection.model_id}\" is pending or absent from the current catalog",
    )
  }
  let entry = match self.manager.catalog_entry(selection.model_id) {
    Some(entry) => entry
    None =>
      raise @posoco.ModelError::RequestBuild(
        "magpie request build failure (stage=selection): model \"\{selection.model_id}\" vanished from the catalog",
      )
  }
  let outcome = plan_protocol(
    entry,
    requirements=entry_requirements,
    preference=self.preference,
    policy=self.policy,
  )
  let plan = match outcome {
    Planned(plan) => plan
    Incompatible(blocked) => {
      let reasons = blocked.blockers
        .map(fn(blocker) {
          "\{blocker.protocol}: \{blocker.reasons.join("; ")}"
        })
        .join(" | ")
      raise @posoco.ModelError::RequestBuild(
        "magpie request build failure (stage=planning): no protocol satisfies the requirements for \"\{blocked.model_id}\" under \{blocked.policy} (\{reasons})",
      )
    }
  }
  {
    config: self.manager.config,
    transport: self.transport,
    plan,
    model_id: selection.model_id,
    effort: selection.effort,
    session: session_identity(scope),
    lossy: plan.lossy_opt_in,
    supports_images: model_supports_images(entry),
  }
}

///|
/// One chat call over the selected plan.
pub impl @posoco.ModelPort for MagpieModelPort with fn chat(
  self : MagpieModelPort,
  scope : @posoco.InvocationScope,
  messages : ArrayView[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  let messages_owned = messages.to_owned()
  let requirements = MagpieRequirements::MagpieRequirements(
    tools=tools.length() > 0,
    streaming=stream is Stream(_),
    images=transcript_has_images(messages_owned),
    reasoning_output=self.require_reasoning_output,
    signed_thinking_replay=self.require_signed_thinking_replay,
    reasoning_effort=self.manager.active_selection().effort,
    native_prompt_caching=self.require_native_prompt_caching,
    token_usage_integrity=false,
    cancellation=true,
  )
  let call = self.prepare_execution(scope, entry_requirements=requirements)
  let (result, report) = execute_planned(
    call, messages_owned, tools, options, stream,
  )
  (self.report_sink)(report)
  result
}

///|
/// Compaction rides the selected protocol as a plain non-streaming
/// summarization call: keep the recent tail verbatim, summarize the head
/// with the structured template, replace in place.
pub impl @posoco.ModelPort for MagpieModelPort with fn compact(
  self : MagpieModelPort,
  scope : @posoco.InvocationScope,
  messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  let all = messages.to_owned()
  let cut = @summary.select_cut(all, COMPACT_KEEP_RECENT_TOKENS)
  if cut.head_end == 0 {
    raise @posoco.ModelError::ResponseParse(
      "magpie compact parse failure (stage=compact, category=nothing_to_summarize)",
    )
  }
  let head : Array[@posoco.Message] = []
  for index in 0..<cut.head_end {
    head.push(all[index])
  }
  let tail : Array[@posoco.Message] = []
  for index in cut.kept_from..<all.length() {
    tail.push(all[index])
  }
  let prompt = @summary.build_summary_prompt(
    @summary.SummaryTemplate::StructuredMd,
    @summary.serialize_for_summary(head),
  )
  let requirements = MagpieRequirements::MagpieRequirements(
    reasoning_effort=self.manager.active_selection().effort,
    cancellation=true,
  )
  let call = self.prepare_execution(scope, entry_requirements=requirements)
  let (call_result, report) = execute_planned(
    call,
    prompt,
    [],
    options,
    NoStream,
  )
  (self.report_sink)(report)
  let summary_text = call_result.completion.message.content
    .filter_map(fn(block) {
      match block {
        @posoco.Content::Text(text) => Some(text)
        _ => None
      }
    })
    .join("")
  if summary_text.length() == 0 {
    raise @posoco.ModelError::ResponseParse(
      "magpie compact parse failure (stage=compact, category=empty_summary)",
    )
  }
  @summary.build_replace_result(summary_text, tail)
}

///|
/// Self-description from the current catalog: the active model's advertised
/// effort ladder and declared context window. Unknown windows stay unknown;
/// auto-compact stays disabled rather than guessing.
pub impl @posoco.ModelPort for MagpieModelPort with fn provider_config(
  self : MagpieModelPort,
) -> @posoco.ProviderConfig {
  let selection = self.manager.active_selection()
  match self.manager.catalog_entry(selection.model_id) {
    Some(entry) =>
      @posoco.ProviderConfig::ProviderConfig(
        reasoning_effort_values=match entry.meta.reasoning_levels {
          Some(levels) => levels
          None => []
        },
        context_window=entry.meta.context_window,
        compact_threshold=None,
      )
    None => @posoco.ProviderConfig::empty()
  }
}

///|
pub extend MagpieModelPort with @posoco.ModelPort::{
  provider_config,
  chat,
  compact,
}
