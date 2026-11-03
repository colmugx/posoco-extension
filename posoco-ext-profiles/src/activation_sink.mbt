///|
/// Host-owned manual activation boundary. A command handler cannot append
/// directly to an external SessionPort: an already initialized Agent reads
/// its own authoritative in-process session snapshot. The host implements
/// this seam by feeding the message through Agent::run_turn after handling
/// the slash command, or through an equivalent host-owned input admission.
/// A successful result means the submission was accepted/committed; rejection
/// must return Err. Do not bypass the Agent's single-operation guard.
pub(open) trait ProfileActivationSink {
  async fn submit(Self, session_id : String, message : @posoco.Message) -> Result[
    Unit,
    String,
  ]
}
