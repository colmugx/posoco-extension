///|
test "work presence counts only runtime state" {
  let runs = WorkRunStore::WorkRunStore()
  ignore(runs.add("t1", "rd", "work", "rd"))
  let questions = TicketQuestions::TicketQuestions()
  ignore(
    questions.open(
      "t1",
      "call",
      "rd",
      "customer",
      @posoco.UiRequest::Confirm(prompt="ok?"),
    ),
  )
  let progress = WorkProgressLog::WorkProgressLog()
  progress.record("t2", "attention", "blocked")
  let presence = work_presence(runs~, questions~, progress~)
  assert_eq(presence.state, @board_presence.Blocked)
  assert_eq(presence.running, 1)
  assert_eq(presence.waiting_input, 1)
}
