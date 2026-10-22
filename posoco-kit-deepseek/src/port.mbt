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
  /// Optional request-local user guidance, never persisted in the session.
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
/// canonical tool order, then one request-local tail user guidance message when the current
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
      @posoco.Message::UserMessage(content=[
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
  let strip_temporary_guidance = fn(result : @posoco.ModelCallResult) {
    if wire_messages.length() == messages.length() {
      result
    } else {
      // The injected user hint is request-local, never canonical session data.
      // Both OpenCode chat wires return the request transcript unchanged.
      // Return the canonical caller-owned history, never the wire-only hint.
      @posoco.ModelCallResult::{
        completion: result.completion,
        processed_messages: messages.to_owned(),
      }
    }
  }
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
            strip_temporary_guidance(retry().chat(
              scope,
              wire_messages[:],
              wire_tools,
              options,
              @posoco.StreamMode::NoStream,
            ))
          } else {
            strip_temporary_guidance(first)
          }
        None => strip_temporary_guidance(first)
      }
    }
    mode => strip_temporary_guidance(self.inner.chat(scope, wire_messages[:], wire_tools, options, mode))
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
