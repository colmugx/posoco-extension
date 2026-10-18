///|
/// Non-blocking ask registry: questions the model submits through
/// `notify_user` are parked here instead of on a `UiPort::request` await.
/// The tool returns immediately; the human's answer arrives later through
/// the host (a follow-up message or a new turn) and is delivered exactly
/// once by `PipelineHook::before_model` as a `[question-reply …]` envelope.
///
/// Terminal states are explicit so a late answer cannot revive an expired
/// question and a repeated answer cannot overwrite the first one:
/// `Open` → `Answered` → (drained) or `Open` → `Expired` → (drained).
/// Answers and expiries that were never injected stay in `drains` so the
/// next model call sees every outcome exactly once.

///|
/// Default answer deadline. Independent of the subagent broker's
/// `answer_timeout_ms`: a human may be away, so the bound is generous and
/// expiration is a delivery-time classification, never a timer thread.
pub const DEFAULT_ASYNC_ANSWER_TIMEOUT_MS : Int64 = 600_000L

///|
/// Longest question text carried into one envelope; the model-authored
/// prompt is bounded so a single reply line cannot flood the next model
/// call.
const ENVELOPE_QUESTION_CHARS : Int32 = 512

///|
/// Lifecycle of one parked question.
priv enum PendingState {
  Open
  /// Terminal before injection: the deadline passed and the expiry has not
  /// been drained yet.
  Expired
  /// The user replied in plain conversation (no id binding). No envelope is
  /// queued — the reply is already in the model context — but the expiry
  /// line is suppressed and the host clears its card.
  Closed
}

///|
/// One parked ask plus the identity the runtime filled in.
pub(all) struct AsyncQuestion {
  /// Opaque answer key (`question-N`), minted by the registry.
  id : String
  /// The question in core request vocabulary.
  req : @posoco.UiRequest
  /// The asking tool call id (audit trail; never model-supplied).
  origin_call : String
  /// Tool clock timestamp (milliseconds) of submission.
  asked_at : Int64
  /// Absolute deadline timestamp (milliseconds); `0` disables expiry.
  deadline_at : Int64
} derive(@debug.Debug)

///|
pub extend AsyncQuestion with @debug.Debug::{to_repr}

///|
/// One outcome that has not reached the model yet.
pub enum AsyncOutcome {
  Answered(question~ : AsyncQuestion, response~ : @posoco.UiResponse)
  Expired(question~ : AsyncQuestion)
} derive(@debug.Debug)

///|
pub extend AsyncOutcome with @debug.Debug::{to_repr}

///|
priv struct Parked {
  question : AsyncQuestion
  mut state : PendingState
  mut response : @posoco.UiResponse?
}

///|
pub enum AsyncAskError {
  Unknown(id~ : String)
  AlreadyAnswered(id~ : String)
  Expired(id~ : String)
  /// The answer variant does not match the question type.
  WrongAnswerKind(id~ : String, expected~ : String)
  /// A select answer named an index outside the offered options.
  IndexOutOfRange(id~ : String, index~ : Int32, options~ : Int32)
} derive(Eq, @debug.Debug)

///|
pub extend AsyncAskError with Eq::{not_equal, equal}

///|
pub extend AsyncAskError with @debug.Debug::{to_repr}

///|
pub impl Show for AsyncAskError with fn to_string(self : AsyncAskError) -> String {
  match self {
    Unknown(id~) =>
      "unknown question '\{id}' — never asked, or already reported"
    AlreadyAnswered(id~) => "question '\{id}' is already answered"
    Expired(id~) => "question '\{id}' expired before an answer arrived"
    WrongAnswerKind(id~, expected~) =>
      "question '\{id}' expects a \{expected} answer"
    IndexOutOfRange(id~, index~, options~) =>
      "index \{index} is out of range for question '\{id}' (\{options} options)"
  }
}

///|
pub extend AsyncAskError with Show::{to_string, output}

///|
/// Owner of every non-blocking ask and every undelivered outcome.
/// Standalone so both the tool face and the hook tail share one instance.
pub struct AsyncQuestionRegistry {
  priv timeout_ms : Int64
  priv mut counter : Int32
  priv mut pending : Map[String, Parked]
  priv mut drains : Array[AsyncOutcome]
}

///|
pub fn AsyncQuestionRegistry::AsyncQuestionRegistry(
  timeout_ms~ : Int64 = DEFAULT_ASYNC_ANSWER_TIMEOUT_MS,
) -> AsyncQuestionRegistry {
  { timeout_ms, counter: 0, pending: Map::from_array([]), drains: [], }
}

///|
/// Bind a numeric question id (`question-3` → `3`) for the UI short form.
pub fn AsyncQuestion::short_id(self : AsyncQuestion) -> String {
  if self.id.has_prefix("question-") {
    self.id[9:].to_owned()
  } else {
    self.id
  }
}

///|
/// `input` / `confirm` / `select` word for one request.
pub fn AsyncQuestion::type_word(self : AsyncQuestion) -> String {
  match self.req {
    @posoco.UiRequest::Input(..) => "input"
    @posoco.UiRequest::Confirm(..) => "confirm"
    @posoco.UiRequest::Select(..) => "select"
  }
}

///|
/// Offered options, empty for non-select requests.
pub fn AsyncQuestion::options(self : AsyncQuestion) -> Array[String] {
  match self.req {
    @posoco.UiRequest::Select(options~, ..) => options
    _ => []
  }
}

///|
/// The question text.
pub fn AsyncQuestion::prompt(self : AsyncQuestion) -> String {
  question_prompt(self.req)
}

///|
/// Register one question and return the parked record. Identity comes from
/// the registry; the caller never supplies an id.
pub fn AsyncQuestionRegistry::submit(
  self : AsyncQuestionRegistry,
  req~ : @posoco.UiRequest,
  origin_call~ : String,
  now~ : Int64,
) -> AsyncQuestion {
  self.counter = self.counter + 1
  let deadline_at = if self.timeout_ms > 0L {
    now + self.timeout_ms
  } else {
    0L
  }
  let question : AsyncQuestion = {
    id: "question-\{self.counter}",
    req,
    origin_call,
    asked_at: now,
    deadline_at,
  }
  self.pending[question.id] = { question, state: Open, response: None, }
  question
}

///|
fn AsyncQuestionRegistry::lookup(
  self : AsyncQuestionRegistry,
  id : String,
) -> Parked? {
  self.pending.get(id)
}

///|
/// Resolve one parked ask. Expiry is decided here (the tool face has no
/// timer): an answer that lands after the deadline is refused explicitly
/// instead of silently winning.
pub fn AsyncQuestionRegistry::answer(
  self : AsyncQuestionRegistry,
  id~ : String,
  response~ : @posoco.UiResponse,
  now~ : Int64,
) -> Result[Unit, AsyncAskError] {
  let parked = match self.lookup(id) {
    Some(parked) => parked
    None => return Err(Unknown(id~))
  }
  match parked.state {
    Expired => return Err(Expired(id~))
    Closed => return Err(AlreadyAnswered(id~))
    Open => ()
  }
  if parked.response is Some(_) {
    return Err(AlreadyAnswered(id~))
  }
  let kind_error : AsyncAskError? = match (parked.question.req, response) {
    (@posoco.UiRequest::Input(..), @posoco.UiResponse::Text(_)) => None
    (@posoco.UiRequest::Confirm(..), @posoco.UiResponse::Yes) => None
    (@posoco.UiRequest::Confirm(..), @posoco.UiResponse::No) => None
    (
      @posoco.UiRequest::Select(options~, ..),
      @posoco.UiResponse::Selected(index),
    ) =>
      if index < 0 || index >= options.length() {
        Some(IndexOutOfRange(id~, index~, options=options.length()))
      } else {
        None
      }
    (@posoco.UiRequest::Input(..), _) =>
      Some(WrongAnswerKind(id~, expected="text"))
    (@posoco.UiRequest::Confirm(..), _) =>
      Some(WrongAnswerKind(id~, expected="confirm"))
    (@posoco.UiRequest::Select(..), _) =>
      Some(WrongAnswerKind(id~, expected="select"))
  }
  match kind_error {
    Some(error) => Err(error)
    None =>
      if parked.question.deadline_at > 0L && now > parked.question.deadline_at {
        parked.state = Expired
        self.drains.push(Expired(question=parked.question))
        Err(Expired(id~))
      } else {
        parked.response = Some(response)
        self.drains.push(Answered(question=parked.question, response~))
        Ok(())
      }
  }
}

///|
/// Take every outcome that has not reached the model yet, and mark the
/// open ones expired first when `now` passed their deadline. The drain is
/// the delivery: a returned outcome is never returned twice. Settled
/// records stay in the table on purpose, so a late answer is refused with
/// its real reason (`expired` / `already answered`) instead of a
/// misleading `unknown`.
pub fn AsyncQuestionRegistry::drain(
  self : AsyncQuestionRegistry,
  now~ : Int64,
) -> Array[AsyncOutcome] {
  for parked in self.pending.values() {
    if parked.state is Open &&
      parked.response is None &&
      parked.question.deadline_at > 0L &&
      now > parked.question.deadline_at {
      parked.state = Expired
      self.drains.push(Expired(question=parked.question))
    }
  }
  let out = self.drains
  self.drains = []
  out
}

///|
/// Open questions, in submission order, for the host's answer picker.
pub fn AsyncQuestionRegistry::open(
  self : AsyncQuestionRegistry,
) -> Array[AsyncQuestion] {
  let out : Array[AsyncQuestion] = []
  for parked in self.pending.values() {
    if parked.state is Open && parked.response is None {
      out.push(parked.question)
    }
  }
  out
}

///|
/// The user sent a plain reply (no id binding): close every open question.
/// Closing is not answering — no envelope is queued, because the reply is
/// already in the model context and the model pairs them itself — but the
/// later expiry line is suppressed. Returns the closed questions in
/// submission order.
pub fn AsyncQuestionRegistry::close_open_for_reply(
  self : AsyncQuestionRegistry,
) -> Array[AsyncQuestion] {
  let closed : Array[AsyncQuestion] = []
  for parked in self.pending.values() {
    if parked.state is Open && parked.response is None {
      parked.state = Closed
      closed.push(parked.question)
    }
  }
  closed
}

///|
/// True while some outcome (answer or expiry) is still undelivered — the
/// turn-end wakeup condition.
pub fn AsyncQuestionRegistry::has_undelivered(
  self : AsyncQuestionRegistry,
) -> Bool {
  !self.drains.is_empty()
}

///|
/// Shutdown sweep: every parked ask expires and every undelivered outcome
/// is discarded; no wait can outlive the agent.
pub fn AsyncQuestionRegistry::reject_all(self : AsyncQuestionRegistry) -> Unit {
  self.pending = Map::from_array([])
  self.drains = []
}

///|
/// The queued outcomes as one model-facing envelope block, or `None` when
/// nothing is pending. Shape (one line per outcome):
///   [question-reply id=question-3] answer: node 22
///   [question-expired id=question-4] no answer arrived; decide yourself
pub fn async_env_lines(outcomes : Array[AsyncOutcome]) -> String? {
  if outcomes.is_empty() {
    return None
  }
  let lines : Array[String] = []
  for outcome in outcomes {
    match outcome {
      Answered(question~, response~) =>
        lines.push(
          "[question-reply id=\{question.id}] answer: \{answer_text(question.req, response)}",
        )
      Expired(question~) =>
        lines.push(
          "[question-expired id=\{question.id}] \{truncate_chars(question_prompt(question.req), ENVELOPE_QUESTION_CHARS)} — no answer arrived in time; decide yourself",
        )
    }
  }
  Some(lines.join("\n"))
}

///|
/// Prompt text of one request; every variant carries one.
pub fn question_prompt(req : @posoco.UiRequest) -> String {
  match req {
    @posoco.UiRequest::Input(prompt~, ..) => prompt
    @posoco.UiRequest::Confirm(prompt~) => prompt
    @posoco.UiRequest::Select(prompt~, ..) => prompt
  }
}

///|
/// Readable projection of one submitted answer, bounded for the envelope.
fn answer_text(
  req : @posoco.UiRequest,
  response : @posoco.UiResponse,
) -> String {
  match response {
    @posoco.UiResponse::Text(text) => truncate_chars(flatten_spaces(text), 512)
    @posoco.UiResponse::Yes => "yes"
    @posoco.UiResponse::No => "no"
    @posoco.UiResponse::Selected(index) =>
      match req {
        @posoco.UiRequest::Select(options~, ..) =>
          match options.get(index) {
            Some(option) => option + " (index " + index.to_string() + ")"
            None => "option " + index.to_string()
          }
        _ => index.to_string()
      }
    @posoco.UiResponse::Cancelled => "(cancelled)"
  }
}

///|
/// Collapse whitespace runs to single spaces; one envelope line must stay
/// one line however the human typed.
fn flatten_spaces(text : String) -> String {
  let buf = StringBuilder()
  let mut previous_space = false
  for ch in text {
    if ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' {
      if !previous_space {
        buf.write_char(' ')
        previous_space = true
      }
    } else {
      buf.write_char(ch)
      previous_space = false
    }
  }
  buf.to_string().trim().to_owned()
}

///|
fn truncate_chars(text : String, max : Int32) -> String {
  if text.length() <= max {
    return text
  }
  let out = StringBuilder()
  let mut count = 0
  for ch in text {
    if count >= max {
      out.write_string("…")
      break
    }
    out.write_char(ch)
    count = count + 1
  }
  out.to_string()
}
