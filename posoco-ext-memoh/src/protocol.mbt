///|
/// Memoh's ACP client identity. The dedicated adapter rejects other clients so
/// host-specific semantics cannot silently run under a generic ACP surface.
pub const MEMOH_CLIENT_NAME : String = "memoh"

///|
/// Canonical URI used by Memoh for the current runtime context document.
pub const MEMOH_CURRENT_TURN_URI : String = "memoh://context/current-turn"

///|
/// Canonical MIME type emitted by Memoh for the current runtime context.
pub const MEMOH_CURRENT_TURN_MIME : String = "text/markdown"

///|
/// Require the ACP connection to identify itself as Memoh.
pub fn require_memoh_client(
  info : @acp.ProtocolNullable[@acp.Implementation],
) -> Unit raise MemohError {
  match info {
    @acp.ProtocolNullable::Value(client) =>
      if client.name == MEMOH_CLIENT_NAME {
        ()
      } else {
        raise InvalidClient(reason="expected clientInfo.name=memoh, got " + client.name)
      }
    @acp.ProtocolNullable::Null =>
      raise InvalidClient(reason="clientInfo is null")
    @acp.ProtocolNullable::Omitted =>
      raise InvalidClient(reason="clientInfo is omitted")
  }
}
