///|
/// Host-visible Board presence is derived only from WorkRuntime state. The
/// host adapter receives one projection and never re-counts runs or questions.
pub fn work_presence(
  runs~ : WorkRunStore,
  questions~ : TicketQuestions,
  progress~ : WorkProgressLog,
) -> @board_presence.BoardPresence {
  @board_presence.BoardPresence::project(
    running=runs.count_running(),
    waiting_input=questions.open_count(),
    attention=progress.attention_tasks(),
  )
}
