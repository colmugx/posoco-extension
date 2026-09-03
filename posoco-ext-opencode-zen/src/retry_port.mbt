///|
/// ModelPort decorator that retries Zen's transient failures.
///
/// Retried classes, all leaving the request half-processed on a stateless
/// completion POST (streamed chunks are a host/UI concern, not transcript
/// fact, so repeating the request from scratch is safe):
///
/// - marker-less EOF truncation (`ResponseParse("... SSE truncated ...")`) —
///   some Zen models close the stream without finish_reason / [DONE];
/// - mid-stream connection resets (`Transport("... stage=read_stream ...")`);
/// - gateway 503s (`Transport("... status=503 ...")`) — the Zen gateway
///   occasionally answers 503 under load, the same transient class pi retries.
///
/// Backoff mirrors OpenCode's session retry: 2s initial, doubling per retry.
struct ZenRetryModelPort {
  inner : &@posoco.ModelPort
  max_retries : Int
  initial_delay_ms : Int
}

///|
/// Retries granted after the first failure (total attempts = 1 + this).
let zen_max_retries : Int = 3

///|
/// OpenCode RETRY_INITIAL_DELAY.
let zen_retry_initial_delay_ms : Int = 2000

///|
fn zen_retry_port(inner : &@posoco.ModelPort) -> &@posoco.ModelPort {
  ZenRetryModelPort::{
    inner,
    max_retries: zen_max_retries,
    initial_delay_ms: zen_retry_initial_delay_ms,
  }
}

///|
fn zen_retryable_error(error : @posoco.ModelError) -> Bool {
  match error {
    @posoco.ModelError::ResponseParse(msg) => msg.contains("SSE truncated")
    @posoco.ModelError::Transport(msg) =>
      msg.contains("stage=read_stream") || msg.contains("status=503")
    _ => false
  }
}

///|
pub impl @posoco.ModelPort for ZenRetryModelPort with fn chat(
  self : ZenRetryModelPort,
  scope : @posoco.InvocationScope,
  messages : ArrayView[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  let mut retries_left = self.max_retries
  let mut delay_ms = self.initial_delay_ms
  while true {
    let result = Ok(self.inner.chat(scope, messages, tools, options, stream)) catch {
      error => Err(error)
    }
    match result {
      Ok(value) => return value
      Err(error) =>
        if retries_left > 0 && zen_retryable_error(error) {
          @async.sleep(delay_ms) catch {
            _ => ()
          }
          retries_left -= 1
          delay_ms *= 2
        } else {
          raise error
        }
    }
  }
  abort("zen retry loop exits via return or raise")
}

///|
/// OpenCode's preserve-recent budget: `clamp(2000..=15000, 25% of usable)`
/// where usable is the model window minus a 20k compaction reserve. Without
/// a known window the budget falls back to the 15k ceiling (a window is
/// never guessed).
fn zen_keep_recent_tokens(context_window : Int?) -> Int {
  let usable = match context_window {
    Some(w) if w > 20_000 => w - 20_000
    _ => return 15_000
  }
  let quarter = usable / 4
  if quarter < 2_000 {
    2_000
  } else if quarter > 15_000 {
    15_000
  } else {
    quarter
  }
}

///|
/// The previous anchored summary inside the head range, if any: the latest
/// message recognized by `is_summary_message`, with the anchor prefix
/// stripped so the update prompt sees the bare summary.
fn zen_previous_summary(head : Array[@posoco.Message]) -> String? {
  let mut latest : String? = None
  for message in head {
    if @compact_summary.is_summary_message(message) {
      match message {
        @posoco.Message::UserMessage(content~) =>
          for block in content {
            match block {
              @posoco.Content::Text(text) =>
                if text.has_prefix(@compact_summary.SUMMARY_PREFIX) {
                  latest = Some(
                    text[@compact_summary.SUMMARY_PREFIX.length():].to_owned(),
                  )
                }
              _ => ()
            }
          }
        _ => ()
      }
    }
  }
  latest
}

///|
/// One anchored compaction attempt: OpenCode-style keep-recent budget from
/// the model window, previous summary folded into the update prompt, the
/// summary request itself run through `inner.chat` with an empty toolset.
async fn ZenRetryModelPort::zen_compact_once(
  self : ZenRetryModelPort,
  scope : @posoco.InvocationScope,
  messages : ArrayView[@posoco.Message],
  options : @posoco.ChatOptions,
) -> @posoco.CompactResult raise @posoco.ModelError {
  let all = messages.to_owned()
  let window = self.inner.provider_config().context_window
  let keep_recent = zen_keep_recent_tokens(window)
  let cut = @compact_summary.select_cut(all, keep_recent)
  if cut.head_end == 0 {
    raise @posoco.ModelError::ResponseParse(
      "zen compact has nothing to summarize",
    )
  }
  let head : Array[@posoco.Message] = []
  let tail : Array[@posoco.Message] = []
  for i in 0..<cut.head_end {
    head.push(all[i])
  }
  for i in cut.kept_from..<all.length() {
    tail.push(all[i])
  }
  let prompt = @compact_summary.build_summary_prompt(
    @compact_summary.SummaryTemplate::StructuredMd,
    @compact_summary.serialize_for_summary(head),
    previous_summary=zen_previous_summary(head),
  )
  let result = self.inner.chat(scope, prompt[:], [], options, NoStream)
  let summary = result.completion.message.content
    .filter_map(fn(block) {
      match block {
        Text(text) => Some(text)
        Image(..) => None
      }
    })
    .join(" ")
    .trim()
    .to_owned()
  if summary.length() == 0 {
    raise @posoco.ModelError::ResponseParse(
      "zen compact produced an empty summary",
    )
  }
  @compact_summary.build_replace_result(summary, tail)
}

///|
/// ModelPort implementation — compact. Zen compacts locally (OpenCode-style
/// anchored summary) instead of forwarding to the inner openai-compatible
/// port; the retry wrapper stays so transient failures while summarizing
/// retry like any other completion POST.
pub impl @posoco.ModelPort for ZenRetryModelPort with fn compact(
  self : ZenRetryModelPort,
  scope : @posoco.InvocationScope,
  messages : ArrayView[@posoco.Message],
  options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  let mut retries_left = self.max_retries
  let mut delay_ms = self.initial_delay_ms
  while true {
    let result = Ok(self.zen_compact_once(scope, messages, options)) catch {
      error => Err(error)
    }
    match result {
      Ok(value) => return value
      Err(error) =>
        if retries_left > 0 && zen_retryable_error(error) {
          @async.sleep(delay_ms) catch {
            _ => ()
          }
          retries_left -= 1
          delay_ms *= 2
        } else {
          raise error
        }
    }
  }
  abort("zen retry loop exits via return or raise")
}

///|
pub impl @posoco.ModelPort for ZenRetryModelPort with fn provider_config(
  self : ZenRetryModelPort,
) -> @posoco.ProviderConfig {
  self.inner.provider_config()
}
