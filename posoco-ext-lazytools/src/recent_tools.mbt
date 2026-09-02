///|
/// Usage-driven hint injection. The Observer records deferred executions
/// as they stream through the turn events; the before_model hook surfaces
/// them on the next prompt as a replace-in-place user envelope. The hook —
/// not the system prompt — carries this content because it changes as the
/// conversation progresses, and a mutating system prompt would invalidate
/// the whole prompt-cache prefix (same trade as permission's mode
/// reminder).

///|
/// Bounded recency window for the hint.
const RECENT_TOOLS_CAP = 5

///|
/// Envelope prefix for replace-in-place detection (devkit renders
/// `<lazytools-context …>`).
const RECENT_TOOLS_PREFIX = "<lazytools-context"

///|
/// Record one executed deferred tool, most recent last, deduplicated.
fn LazyTools::record_usage(self : LazyTools, tool : String) -> Unit {
  let mut pos = -1
  for i, name in self.recent {
    if name == tool {
      pos = i
      break
    }
  }
  if pos >= 0 {
    let _ = self.recent.remove(pos)
  }
  self.recent.push(tool)
  while self.recent.length() > RECENT_TOOLS_CAP {
    let _ = self.recent.remove(0)
  }
}

///|
/// Most recent first (rendering order for the hint).
fn LazyTools::recent_tools(self : LazyTools) -> Array[String] {
  let out : Array[String] = []
  for i in 0..<self.recent.length() {
    out.push(self.recent[self.recent.length() - 1 - i])
  }
  out
}

///|
/// Watch turn events for deferred executions. Only calls the gateway
/// actually routed (inner name present in the index) count as usage —
/// unknown-tool feedback never pollutes the hint.
pub impl @posoco.Observer for LazyTools with fn on_event(
  self : LazyTools,
  event : @posoco.TurnEvent,
) -> Unit {
  match event {
    @posoco.TurnEvent::ToolCallResult(call~, ..) => {
      let (name, _) = LazyTools::unwrap_call(call)
      if name != "tool_execute" && self.by_name.contains(name) {
        self.record_usage(name)
      }
    }
    _ => ()
  }
}

///|
/// Inject (or refresh in place) the recent-tools hint as a user envelope.
pub impl @posoco.PipelineHook for LazyTools with fn before_model(
  self : LazyTools,
  messages : Array[@posoco.Message],
) -> Array[@posoco.Message] {
  let recent = self.recent_tools()
  if recent.is_empty() {
    return messages
  }
  let content = @devkit.context_envelope(
    ns="lazytools",
    kind="recent-tools",
    trust=true,
    content="Recently used deferred tools: \{recent.join(", ")}. You can skip tool_list and call them with tool_execute directly. If none fits, use tool_list to browse the folded catalog.",
  )
  let mut existing_idx = -1
  let mut existing_text = ""
  for i, msg in messages {
    match msg {
      @posoco.Message::UserMessage(content~) =>
        match content {
          [@posoco.Content::Text(text), ..] =>
            if text.has_prefix(RECENT_TOOLS_PREFIX) {
              existing_idx = i
              existing_text = text
              break
            }
          _ => ()
        }
      _ => ()
    }
  }
  if existing_idx < 0 {
    messages.push(
      @posoco.Message::UserMessage(content=[@posoco.Content::Text(content)]),
    )
  } else if existing_text != content {
    messages[existing_idx] = @posoco.Message::UserMessage(content=[
      @posoco.Content::Text(content),
    ])
  }
  messages
}
