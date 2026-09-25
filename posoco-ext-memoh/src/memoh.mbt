///|
/// Memoh host adapter state.
///
/// One value owns all Memoh-specific Posoco projections for one live host
/// session. Conversation durability remains outside this object: Memoh is the
/// durable authority, while this adapter holds only current-turn host context.
pub struct Memoh {
  mut turn_context : MemohContext?
}

///|
/// Construct a Memoh host adapter with no current-turn context installed.
pub fn Memoh::Memoh() -> Memoh {
  { turn_context: None, }
}

///|
/// Install the decoded current-turn context and return the real user message
/// that should be passed to Posoco.
///
/// The context is deliberately not concatenated into the user message. The
/// PipelineHook view injects it as a separate host-context SystemMessage at
/// the model boundary.
pub fn Memoh::prepare_turn(
  self : Memoh,
  prompt : MemohPrompt,
) -> @posoco.Message {
  self.turn_context = Some(prompt.context)
  prompt.user_message()
}

///|
/// Clear current-turn host context. Hosts may call this on failures that occur
/// before Posoco reaches its normal on_turn_end cleanup.
pub fn Memoh::clear_turn_context(self : Memoh) -> Unit {
  self.turn_context = None
}
