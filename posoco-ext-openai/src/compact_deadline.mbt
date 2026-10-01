///|
/// Codex standalone compact: default stream idle 300_000 ms * multiplier 4.
/// https://github.com/openai/codex/blob/3aae5d885bac39c1262491aa3fd100dfd8b3919f/codex-rs/core/src/client.rs
/// https://github.com/openai/codex/blob/3aae5d885bac39c1262491aa3fd100dfd8b3919f/codex-rs/model-provider-info/src/lib.rs
let openai_compact_deadline_ms : Int = 1_200_000

///|
/// `/responses/compact` POST bounded by the unary compact deadline. A
/// deadline miss raises a typed transport failure. Every model error —
/// including the typed quota verdict — is re-raised unchanged so hosts keep
/// their retry semantics; task cancellation bypasses `catch` entirely and
/// still closes the request client through the inner defer.
async fn openai_compact_post_json(
  config : OpenAIConfig,
  body : Json,
  session_id : String?,
  quota_tracker? : CodexQuotaTracker? = None,
  deadline_ms? : Int = openai_compact_deadline_ms,
) -> Json raise @posoco.ModelError {
  @async.with_timeout(deadline_ms, () => {
    openai_post_json(
      config,
      "/responses/compact",
      body,
      session_id,
      quota_tracker~,
    )
  }) catch {
    @async.TimeoutError =>
      raise @posoco.ModelError::Transport(
        "OpenAI transport failure (stage=compact_deadline, category=timeout, deadline_ms=\{deadline_ms})",
      )
    @posoco.ModelError::RateLimited(info) =>
      raise @posoco.ModelError::RateLimited(info)
    @posoco.ModelError::RequestBuild(reason) =>
      raise @posoco.ModelError::RequestBuild(reason)
    @posoco.ModelError::ResponseParse(message) =>
      raise @posoco.ModelError::ResponseParse(message)
    @posoco.ModelError::Transport(reason) =>
      raise @posoco.ModelError::Transport(reason)
    other =>
      raise @posoco.ModelError::Transport(
        "OpenAI transport failure (stage=compact_unexpected): " +
        other.to_string(),
      )
  }
}
