///|
/// Human-facing endpoint for a ticket child. The task binding lives here, so
/// the child never gets to choose which ticket its question belongs to.
pub(all) struct BoardQuestionEndpoint {
  questions : TicketQuestions
  task_id : String
  asked_by : String
  audience : String
  on_open : ((String, String, String, String, String) -> Unit)?
  auto_po : ((String) -> Unit)?
}

///|
pub impl @askquestion.QuestionEndpoint for BoardQuestionEndpoint with fn request(
  self,
  origin_call~ : String,
  req~ : @posoco.UiRequest,
) -> @posoco.UiResponse raise @askquestion.QuestionError {
  self.ask_with(origin_call, self.audience, req)
}

///|
pub impl @askquestion.QuestionEndpoint for BoardQuestionEndpoint with fn request_with_audience(
  self,
  origin_call~,
  audience~,
  req~,
) -> @posoco.UiResponse raise @askquestion.QuestionError {
  let audience = if audience == "po" ||
    audience == "customer" ||
    audience == "sm" {
    audience
  } else {
    self.audience
  }
  self.ask_with(origin_call, audience, req)
}

///|
pub async fn BoardQuestionEndpoint::ask_with(
  self : BoardQuestionEndpoint,
  origin_call : String,
  audience : String,
  req : @posoco.UiRequest,
) -> @posoco.UiResponse raise @askquestion.QuestionError {
  let id = self.questions.open(
    self.task_id,
    origin_call,
    self.asked_by,
    audience,
    req,
  )
  if audience != "customer" {
    match self.on_open {
      Some(callback) =>
        callback(
          id,
          self.task_id,
          self.asked_by,
          audience,
          question_prompt(req),
        )
      None => ()
    }
  }
  if audience == "po" {
    match self.auto_po {
      Some(callback) => callback(id)
      None => ()
    }
  }
  self.questions.wait(id)
}

///|
pub fn question_prompt(req : @posoco.UiRequest) -> String {
  match req {
    @posoco.UiRequest::Input(prompt~, ..) => prompt
    @posoco.UiRequest::Confirm(prompt~) => prompt
    @posoco.UiRequest::Select(prompt~, ..) => prompt
  }
}

///|
pub extend BoardQuestionEndpoint with @askquestion.QuestionEndpoint::{
  request,
  request_with_audience,
}
