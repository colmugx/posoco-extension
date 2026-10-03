///|
fn qwen_summary_text(completion : @posoco.Completion) -> String {
  completion.message.content
  .filter_map(fn(block) {
    match block {
      Text(text) => Some(text)
      Image(..) => None
    }
  })
  .join(" ")
  .trim()
  .to_owned()
}

///|
pub impl @posoco.ModelPort for QwenModelPort with fn compact(
  self : QwenModelPort,
  _scope : @posoco.InvocationScope,
  messages : ArrayView[@posoco.Message],
  _tools : Array[@posoco.ToolDef],
  options : @posoco.ChatOptions,
  _trigger : @posoco.CompactTrigger,
) -> @posoco.CompactResult raise @posoco.ModelError {
  let all = messages.to_owned()
  let cut = @compact_summary.select_cut(all, 20000)
  if cut.head_end == 0 {
    raise @posoco.ModelError::ResponseParse(
      "qwen compact has nothing to summarize",
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
  )
  // Compaction intentionally disables preserved reasoning and vendor thinking:
  // the output must be a concise handoff summary, not another reasoning turn.
  let compact_config = {
    ..self.config,
    reasoning_effort: Some("none"),
    enable_thinking: None,
    preserve_thinking: false,
    emit_preserve_thinking: true,
    tool_stream: false,
  }
  let body = build_chat_request(compact_config, prompt, [], options, false)
  let completion = decode_chat_response(self.post_chat_json(body, "compact"))
  let summary = qwen_summary_text(completion)
  if summary.length() == 0 {
    raise @posoco.ModelError::ResponseParse(
      "qwen compact produced an empty summary",
    )
  }
  @compact_summary.build_replace_result(summary, tail)
}
