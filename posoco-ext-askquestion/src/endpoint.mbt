///|
/// Error surface of an injected question endpoint. Distinct from
/// `@posoco.UiError`: it must carry `TimedOut` for parent-agent answers
/// that never arrive inside the configured deadline.
pub(all) suberror QuestionError {
  Unsupported(String)
  Cancelled
  TimedOut
  Io(String)
} derive(Eq, Debug)

///|
pub extend QuestionError with Eq::{not_equal, equal}

///|
pub extend QuestionError with Debug::{to_repr}

///|
/// Injectable answerer behind an ask-question tool face. The default human
/// face stays backed by the composed UiPort; a subagent composition binds a
/// parent endpoint whose `request` parks until the spawning parent agent
/// answers. `origin_call` is the asking tool call id, filled by the runtime —
/// never by the model.
pub(open) trait QuestionEndpoint {
  async fn request(Self, origin_call~ : String, req~ : @posoco.UiRequest) -> @posoco.UiResponse raise QuestionError
}
