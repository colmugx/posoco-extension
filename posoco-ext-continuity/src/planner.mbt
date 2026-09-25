///|
pub(all) struct CheckpointCandidate {
  start_index : Int
  end_index : Int
  estimated_tokens : Int
} derive(Eq, Debug)

///|
pub(all) struct ContinuityPlan {
  budget : BudgetReport
  candidate : CheckpointCandidate?
} derive(Eq, Debug)

fn estimate_content_tokens(content : Array[@posoco.Content]) -> Int {
  let mut total = 0
  for item in content {
    match item {
      @posoco.Content::Text(text) => total = total + estimate_text_tokens(text)
      @posoco.Content::Image(..) => total = total + 1024
    }
  }
  total
}

///|
pub fn estimate_message_tokens(message : @posoco.Message) -> Int {
  match message {
    @posoco.Message::SystemMessage(content~) => estimate_content_tokens(content) + 8
    @posoco.Message::UserMessage(content~) => estimate_content_tokens(content) + 8
    @posoco.Message::AssistantMessage(content~, tool_calls~, reasoning~, ..) => {
      let mut total = estimate_content_tokens(content) + 8 + tool_calls.length() * 64
      match reasoning {
        Some(r) => total = total + estimate_text_tokens(r.content)
        None => ()
      }
      total
    }
    @posoco.Message::ToolMessage(outcome~, ..) => match outcome {
      @posoco.ToolOutcome::Success(content~, ..) => estimate_text_tokens(content) + 16
      @posoco.ToolOutcome::ToolReportedError(content~, ..) => estimate_text_tokens(content) + 16
      @posoco.ToolOutcome::RuntimeFailure(error_category~, message~) =>
        estimate_text_tokens(error_category) + estimate_text_tokens(message) + 16
      @posoco.ToolOutcome::NotExecuted(..) => 32
    }
  }
}

///|
pub fn estimate_messages_tokens(messages : Array[@posoco.Message]) -> Int {
  let mut total = 0
  for message in messages {
    total = total + estimate_message_tokens(message)
  }
  total
}

///|
pub fn working_set_start(
  messages : Array[@posoco.Message],
  config : ContinuityConfig,
) -> Int {
  if messages.length() == 0 { return 0 }
  let by_messages = if messages.length() > config.min_recent_messages {
    messages.length() - config.min_recent_messages
  } else { 0 }
  let mut by_tokens = messages.length()
  let mut tokens = 0
  let mut i = messages.length()
  while i > 0 && tokens < config.min_recent_tokens {
    i = i - 1
    tokens = tokens + estimate_message_tokens(messages[i])
    by_tokens = i
  }
  if by_messages < by_tokens { by_messages } else { by_tokens }
}

fn is_system(message : @posoco.Message) -> Bool {
  match message {
    @posoco.Message::SystemMessage(..) => true
    _ => false
  }
}

///|
pub fn plan_continuity(
  messages : Array[@posoco.Message],
  context_window : Int,
  config : ContinuityConfig,
) -> ContinuityPlan {
  let budget = classify_budget(
    estimate_messages_tokens(messages),
    context_window,
    config,
  )
  if budget.state == Normal || messages.length() == 0 {
    return { budget, candidate: None }
  }
  let mut start = 0
  let working_start = working_set_start(messages, config)
  while start < working_start && is_system(messages[start]) {
    start = start + 1
  }
  let mut end = working_start
  if end > start {
    match messages[end - 1] {
      @posoco.Message::AssistantMessage(tool_calls~, ..) if tool_calls.length() > 0 =>
        end = end - 1
      _ => ()
    }
  }
  if end < messages.length() && end > start {
    match messages[end] {
      @posoco.Message::ToolMessage(..) => end = end - 1
      _ => ()
    }
  }
  if end <= start { return { budget, candidate: None } }
  let mut candidate_tokens = 0
  let mut i = start
  while i < end {
    candidate_tokens = candidate_tokens + estimate_message_tokens(messages[i])
    i = i + 1
  }
  if candidate_tokens < config.min_checkpoint_tokens {
    { budget, candidate: None }
  } else {
    {
      budget,
      candidate: Some({
        start_index: start,
        end_index: end,
        estimated_tokens: candidate_tokens,
      }),
    }
  }
}
