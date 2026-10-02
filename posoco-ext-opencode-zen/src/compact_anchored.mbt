///|
/// Anchored-summary compact wrapper (OpenCode-style): keep-recent budget from
/// the model window, previous summary folded into the update prompt, the
/// summary request run through `inner.chat` with an empty toolset. Chat and
/// provider_config forward unchanged, and this wrapper retries nothing —
/// transient-failure retrying lives in the router-level decorator
/// (`posoco-ext-llm` `transient_retry_port`) that `from_catalogs` applies.
struct ZenAnchoredCompactPort {
  inner : &@posoco.ModelPort
}

///|
fn zen_anchored_compact_port(inner : &@posoco.ModelPort) -> &@posoco.ModelPort {
  ZenAnchoredCompactPort::{ inner, }
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
/// One anchored compaction attempt.
async fn ZenAnchoredCompactPort::zen_compact_once(
  self : ZenAnchoredCompactPort,
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
pub impl @posoco.ModelPort for ZenAnchoredCompactPort with fn compact(
  self : ZenAnchoredCompactPort,
  scope : @posoco.InvocationScope,
  messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  self.zen_compact_once(scope, messages, options)
}

///|
pub impl @posoco.ModelPort for ZenAnchoredCompactPort with fn chat(
  self : ZenAnchoredCompactPort,
  scope : @posoco.InvocationScope,
  messages : ArrayView[@posoco.Message],
  tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  stream : @posoco.StreamMode,
) -> @posoco.ModelCallResult raise @posoco.ModelError {
  self.inner.chat(scope, messages, tools, options, stream)
}

///|
pub impl @posoco.ModelPort for ZenAnchoredCompactPort with fn provider_config(
  self : ZenAnchoredCompactPort,
) -> @posoco.ProviderConfig {
  self.inner.provider_config()
}

///|
pub extend ZenAnchoredCompactPort with @posoco.ModelPort::{
  provider_config,
  chat,
  compact,
}
