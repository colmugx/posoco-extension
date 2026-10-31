///|
/// Non-blocking ask: model-facing tool face plus the two hook tails that
/// make the answer reach the model.
///
/// Flow: `notify_user` parks the question and returns immediately (the turn
/// keeps running). The question is announced on the subscription channel as
/// `QuestionEvent::Asked`; the host shows it and later hands the human's
/// answer back through `AsyncQuestionRegistry::answer`. The answer waits
/// until the next model call, where `before_model` appends one
/// `[question-reply …]` envelope — exactly once. When a turn ends with an
/// undelivered answer the registry asks the Agent for one ordinary turn so
/// the answer is not stranded until the user happens to type something.
///
/// The extension never emits observer events itself (core owns that
/// channel); the host subscribes through `AskQuestionTools::subscribe`,
/// exactly like the subagent extension's event callbacks.

///|
/// One question lifecycle fact for host display. Not model input.
///
/// Every terminal fact is per-question: answering or settling one question
/// never withdraws another. Hosts decide what a plain human message means;
/// the extension never infers that a message answers the outstanding set.
pub(all) enum QuestionEvent {
  Asked(question~ : AsyncQuestion)
  Answered(question_id~ : String)
} derive(@debug.Debug)

///|
pub extend QuestionEvent with @debug.Debug::{to_repr}

///|
/// Wakeup coalescing key: one pending ticket covers every undelivered
/// answer of a session.
const ANSWER_WAKEUP_TAG : String = "askquestion-answer"

///|
const ANSWER_WAKEUP_NOTE : String = "a non-blocking question was answered; its [question-reply] envelope is delivered to your next turn's model input"

///|
/// Subscribe to question lifecycle events. Callbacks run synchronously
/// inside the tool body / host answer call and must not raise. The subagent
/// wakeup policy needs the answering host to also set the parent session
/// (`set_session`); without it, turn-end wakeup admission fails closed and
/// the answer is delivered lazily.
pub fn AskQuestionTools::subscribe(
  self : AskQuestionTools,
  cb : (QuestionEvent) -> Unit,
) -> Unit {
  self.events.push(cb)
}

///|
pub fn AskQuestionTools::set_session(
  self : AskQuestionTools,
  session~ : String,
) -> Unit {
  self.session = Some(session)
}

///|
fn AskQuestionTools::fire(
  self : AskQuestionTools,
  event : QuestionEvent,
) -> Unit {
  for cb in self.events {
    cb(event)
  }
}

///|
/// Submit one non-blocking question and return its receipt. Nothing here
/// waits: the question is parked, announced, and forgotten until an answer
/// arrives or the model-call drain classifies it as expired.
fn AskQuestionTools::submit_async(
  self : AskQuestionTools,
  origin_call : String,
  arguments : Json,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let spec = parse_ask_spec(arguments, tool=NOTIFY_USER_TOOL)
  let question = self.registry.submit(
    req=spec.request(),
    origin_call~,
    now=self.now(),
  )
  self.fire(Asked(question~))
  let type_word = match question.req {
    @posoco.UiRequest::Input(..) => "input"
    @posoco.UiRequest::Confirm(..) => "confirm"
    @posoco.UiRequest::Select(..) => "select"
  }
  @posoco.ToolOutcome::Success(
    content="question submitted; the turn continues and the answer arrives later as user input — do not wait for it\nquestion_id: \{question.id}\nshort_id: @q\{question.short_id()}",
    structured=Some(
      Json::object({
        "status": Json::string("submitted"),
        "question_id": Json::string(question.id),
        "short_id": Json::string("@q" + question.short_id()),
        "type": Json::string(type_word),
      }),
    ),
  )
}

///|
/// Resolve one parked question from the host. Accepted answers are delivered
/// by the next `before_model`; an answer that misses the deadline or names
/// the wrong answer kind is refused with an explicit reason.
pub fn AskQuestionTools::answer_async(
  self : AskQuestionTools,
  question_id~ : String,
  response~ : @posoco.UiResponse,
) -> Result[Unit, AsyncAskError] {
  let id = canonical_question_id(question_id)
  let result = self.registry.answer(id~, response~, now=self.now())
  match result {
    Ok(_) => self.fire(Answered(question_id=id))
    Err(_) => ()
  }
  result
}

///|
/// Open questions, in submission order, for the host's answer picker.
pub fn AskQuestionTools::open_questions(
  self : AskQuestionTools,
) -> Array[AsyncQuestion] {
  self.registry.open()
}

///|
/// Drain undelivered outcomes against an explicit clock. Only tests need
/// this: production drains at the model call with the runtime clock.
pub fn AskQuestionTools::drain_answers_for_test(
  self : AskQuestionTools,
  now~ : Int64,
) -> Array[AsyncOutcome] {
  self.registry.drain(now~)
}

///|
/// True while an answer (or an expiry) is still undelivered.
pub fn AskQuestionTools::has_undelivered(self : AskQuestionTools) -> Bool {
  self.registry.has_undelivered()
}

///|
fn AskQuestionTools::now(self : AskQuestionTools) -> Int64 {
  ignore(self)
  // Runtime clock; the answer deadline is the only consumer.
  @async.now()
}

///|
/// Accept `question-3`, `3`, and `@q3`.
fn canonical_question_id(raw : String) -> String {
  let trimmed = raw.trim().to_owned()
  if trimmed.has_prefix("question-") {
    return trimmed
  }
  let bare = if trimmed.has_prefix("@q") {
    trimmed[2:].to_owned()
  } else {
    trimmed
  }
  let mut all_digits = bare != ""
  for ch in bare {
    if ch < '0' || ch > '9' {
      all_digits = false
      break
    }
  }
  if all_digits {
    "question-" + bare
  } else {
    trimmed
  }
}

///|
/// Model-call boundary: deliver every undelivered outcome exactly once.
/// Parent-agent faces never touch the registry.
impl @posoco.PipelineHook for AskQuestionTools with fn before_model(
  self : AskQuestionTools,
  messages : Array[@posoco.Message],
) -> Array[@posoco.Message] {
  if self.audience is ParentAgent {
    return messages
  }
  let outcomes = self.registry.drain(now=self.now())
  match async_env_lines(outcomes) {
    None => messages
    Some(text) => {
      messages.push(
        @posoco.Message::UserMessage(content=[@posoco.Content::Text(text)]),
      )
      messages
    }
  }
}

///|
/// Turn end: an answer that landed after the model's last call is still
/// undelivered — ask for one ordinary turn so it is not stranded until the
/// user types something. A missing wakeup capability or unknown session
/// degrades to lazy delivery on the next ordinary input.
impl @posoco.PipelineHook for AskQuestionTools with fn on_turn_end(
  self : AskQuestionTools,
) -> Unit {
  if self.audience is ParentAgent {
    return
  }
  if !self.registry.has_undelivered() {
    return
  }
  let wakeup = match self.wakeup {
    Some(wakeup) => wakeup
    None => return
  }
  let session = match self.session {
    Some(session) => session
    None => return
  }
  ignore(
    wakeup.request(session~, tag=ANSWER_WAKEUP_TAG, note=ANSWER_WAKEUP_NOTE),
  )
}

///|
/// Shutdown: no answer outlives the agent.
pub fn AskQuestionTools::shutdown_answers(self : AskQuestionTools) -> Unit {
  self.registry.reject_all()
}
