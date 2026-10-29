///|
/// One Board work item owns role-scoped child runs. The runtime reads the
/// authoritative snapshot, parks questions, and commits results only after the
/// Board accepts the corresponding stage/report command.
pub(all) struct TicketQuestion {
  id : String
  task_id : String
  origin_call : String
  req : @posoco.UiRequest
  asked_by : String
  mut audience : String
  asked_at_ms : Int64
  cond : @async.CondVar
  mut outcome : @posoco.UiResponse?
  mut status : String
  mut answer : String?
  mut answered_by : String?
  mut answered_at_ms : Int64?
  mut forwarded_by : String?
}

///|
pub(all) struct TicketQuestions {
  mut counter : Int32
  questions : Map[String, TicketQuestion]
}

///|
pub fn TicketQuestions::TicketQuestions() -> TicketQuestions {
  { counter: 0, questions: Map([]), }
}

///|
pub fn TicketQuestions::open(
  self : TicketQuestions,
  task_id : String,
  origin_call : String,
  asked_by : String,
  audience : String,
  req : @posoco.UiRequest,
) -> String {
  self.counter = self.counter + 1
  let id = "ticket-question-" + self.counter.to_string()
  let question : TicketQuestion = {
    id,
    task_id,
    origin_call,
    req,
    asked_by,
    audience,
    asked_at_ms: @async.now(),
    cond: @async.CondVar::Cond(),
    outcome: None,
    status: "open",
    answer: None,
    answered_by: None,
    answered_at_ms: None,
    forwarded_by: None,
  }
  self.questions[id] = question
  id
}

///|
pub async fn TicketQuestions::wait(
  self : TicketQuestions,
  id : String,
) -> @posoco.UiResponse raise @askquestion.QuestionError {
  let question = match self.questions.get(id) {
    Some(question) => question
    None => raise @askquestion.QuestionError::Cancelled
  }
  let waited : Unit? = @async.with_timeout_opt(1_800_000, async fn() {
    while question.outcome is None {
      question.cond.wait()
    }
  }) catch {
    _ => None
  }
  if waited is None && question.outcome is None {
    question.status = "timed_out"
    self.questions.remove(id)
    raise @askquestion.QuestionError::TimedOut
  }
  match question.outcome {
    Some(response) => response
    None => {
      question.status = "cancelled"
      raise @askquestion.QuestionError::Cancelled
    }
  }
}

///|
#warnings("-unused_value")
pub async fn TicketQuestions::ask(
  self : TicketQuestions,
  task_id : String,
  origin_call : String,
  asked_by : String,
  audience : String,
  req : @posoco.UiRequest,
) -> @posoco.UiResponse raise @askquestion.QuestionError {
  let id = self.open(task_id, origin_call, asked_by, audience, req)
  self.wait(id)
}

///|
pub fn TicketQuestions::forward(
  self : TicketQuestions,
  id : String,
  forwarded_by : String,
) -> Result[Unit, String] {
  match self.questions.get(id) {
    Some(question) if question.status == "open" => {
      question.audience = "po"
      question.forwarded_by = Some(forwarded_by)
      Ok(())
    }
    _ => Err("question is no longer open")
  }
}

///|
pub fn TicketQuestions::cancel(self : TicketQuestions, id : String) -> Unit {
  match self.questions.get(id) {
    Some(question) if question.status == "open" => {
      question.status = "cancelled"
      question.cond.broadcast()
    }
    _ => ()
  }
}


///|
fn answer_text(
  response : @posoco.UiResponse,
  req : @posoco.UiRequest,
) -> String {
  match response {
    @posoco.UiResponse::Text(value) => value
    @posoco.UiResponse::Yes => "Yes"
    @posoco.UiResponse::No => "No"
    @posoco.UiResponse::Selected(index) =>
      match req {
        @posoco.UiRequest::Select(options~, ..) =>
          match options.get(index) {
            Some(option) => option
            None => "Selected option \{index}"
          }
        _ => "Selected option \{index}"
      }
    @posoco.UiResponse::Cancelled => "Cancelled"
  }
}

///|
pub fn TicketQuestions::answer(
  self : TicketQuestions,
  question_id : String,
  response : @posoco.UiResponse,
  answered_by : String,
) -> Result[(String, String, String), String] {
  match self.questions.get(question_id) {
    Some(question) => {
      question.outcome = Some(response)
      question.status = "answered"
      question.answer = Some(answer_text(response, question.req))
      question.answered_by = Some(answered_by)
      question.answered_at_ms = Some(@async.now())
      question.cond.broadcast()
      let result = (
        question.task_id,
        question.asked_by,
        answer_text(response, question.req),
      )
      self.questions.remove(question_id)
      Ok(result)
    }
    None => Err("question is no longer open")
  }
}

///|
pub fn TicketQuestions::get(self : TicketQuestions, id : String) -> TicketQuestion? {
  self.questions.get(id)
}

///|
pub fn TicketQuestions::json(self : TicketQuestions) -> Json {
  let items : Array[Json] = []
  for question in self.questions.values() {
    if question.status != "open" {
      continue
    }
    let (kind, prompt, options) = match question.req {
      @posoco.UiRequest::Input(prompt~, ..) =>
        ("input", prompt, Json::array([]))
      @posoco.UiRequest::Confirm(prompt~) =>
        ("confirm", prompt, Json::array([]))
      @posoco.UiRequest::Select(prompt~, options~, ..) =>
        ("select", prompt, Json::array(options.map(Json::string)))
    }
    items.push(
      Json::object({
        "id": Json::string(question.id),
        "task_id": Json::string(question.task_id),
        "question": Json::string(prompt),
        "kind": Json::string(kind),
        "options": options,
        "asked_at": Json::number(question.asked_at_ms.to_double()),
        "origin_call": Json::string(question.origin_call),
        "asked_by": Json::string(question.asked_by),
        "audience": Json::string(question.audience),
        "status": Json::string(question.status),
        "answer": match question.answer {
          Some(value) => Json::string(value)
          None => Json::null()
        },
        "answered_by": match question.answered_by {
          Some(value) => Json::string(value)
          None => Json::null()
        },
        "forwarded_by": match question.forwarded_by {
          Some(value) => Json::string(value)
          None => Json::null()
        },
        "answered_at": match question.answered_at_ms {
          Some(value) => Json::number(value.to_double())
          None => Json::null()
        },
      }),
    )
  }
  Json::array(items)
}

