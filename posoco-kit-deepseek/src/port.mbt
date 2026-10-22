///|
/// The DeepSeek contract as a ModelPort decorator.
///
/// Transport-level rules cannot live here: a stream callback cannot raise, so
/// only the wire that reads the connection can stop it. This port therefore
/// carries the two request-side obligations and the one non-streaming
/// recovery, and a wire that supports an observer seam enforces the stream
/// bounds itself (see the host adapter for the inspector wiring).

///|
struct DeepSeekPolicyPort {
  inner : &@posoco.ModelPort
  policy : DeepSeekPolicy
  /// The same endpoint rebuilt at low effort, used for the single bounded
  /// recovery attempt. `None` when the model declares no `low` level.
  retry_at_low : (() -> &@posoco.ModelPort)?
  /// Appending a system message is a Chat Completions affordance only; the
  /// Messages wire rejects a system message inside the transcript.
  inject_convergence : Bool
  ctx : @devkit.ExtContext
  source : String
}

///|
/// Wrap a DeepSeek-speaking port with the contract. `inner` must be the wire
/// port that enforces the stream bounds, not another policy port.
pub fn deepseek_policy_port(
  inner~ : &@posoco.ModelPort,
  policy~ : DeepSeekPolicy,
  retry_at_low~ : (() -> &@posoco.ModelPort)? = None,
  inject_convergence~ : Bool = true,
  ctx~ : @devkit.ExtContext = @devkit.ExtContext::default(),
  source~ : String = "posoco-kit-deepseek",
) -> &@posoco.ModelPort {
  DeepSeekPolicyPort::{
    inner,
    policy,
    retry_at_low,
    inject_convergence,
    ctx,
    source,
  }
}

///|
/// Request-side obligations, applied to a private copy of the transcript:
/// canonical tool order, then one tail convergence message when the current
/// user turn has been repeating a single tool call. The caller's arrays are
/// never mutated.
fn DeepSeekPolicyPort::apply_request(
  self : DeepSeekPolicyPort,
  messages : Array[@posoco.Message],
  tools : Array[@posoco.ToolDef],
) -> (Array[@posoco.Message], Array[@posoco.ToolDef]) {
  let ordered = canonical_tool_order(tools)
  let wire_messages = messages.copy()
  if self.inject_convergence &&
    ordered.length() > 0 &&
    repeated_tool_calls(messages) {
    wire_messages.push(
      @posoco.Message::SystemMessage(content=[
        @posoco.Content::Text(convergence_instruction()),
      ]),
    )
  }
  (wire_messages, ordered)
}

///|
pub impl @posoco.ModelPort for DeepSeekPolicyPort with fn chat(
  self : DeepSeekPolicyPort,
  scope : @posoco.InvocationScope,
  messages : ArrayView[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  let (wire_messages, wire_tools) = self.apply_request(
    messages.to_owned(),
    tools,
  )
  match stream {
    @posoco.StreamMode::NoStream => {
      let first = self.inner.chat(
        scope,
        wire_messages[:],
        wire_tools,
        options,
        @posoco.StreamMode::NoStream,
      )
      match self.retry_at_low {
        Some(retry) =>
          if self.policy.recover_on_reasoning_exhaustion &&
            can_retry_reasoning_exhaustion(first.completion) {
            self.ctx.warn(
              source=self.source,
              code="deepseek.reasoning_exhaustion_recovery",
              message="Retrying nonstream reasoning-only length cutoff once at low effort",
            )
            retry().chat(
              scope,
              wire_messages[:],
              wire_tools,
              options,
              @posoco.StreamMode::NoStream,
            )
          } else {
            first
          }
        None => first
      }
    }
    mode => self.inner.chat(scope, wire_messages[:], wire_tools, options, mode)
  }
}

///|
pub impl @posoco.ModelPort for DeepSeekPolicyPort with fn compact(
  self : DeepSeekPolicyPort,
  scope : @posoco.InvocationScope,
  messages : ArrayView[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  self.inner.compact(scope, messages, tools, options, trigger)
}

///|
pub impl @posoco.ModelPort for DeepSeekPolicyPort with fn provider_config(
  self : DeepSeekPolicyPort,
) -> @posoco.ProviderConfig {
  self.inner.provider_config()
}

///|
pub extend DeepSeekPolicyPort with @posoco.ModelPort::{
  provider_config,
  chat,
  compact,
}
