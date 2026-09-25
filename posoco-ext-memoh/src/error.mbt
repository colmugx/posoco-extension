///|
/// Failures at the Memoh host-contract boundary.
pub(all) suberror MemohError {
  InvalidClient(reason~ : String)
  MissingContext
  InvalidContext(reason~ : String)
  UnsupportedPromptBlock(kind~ : String)
  MissingToolGateway
  InvalidMcpServer(reason~ : String)
  UnsupportedMcpTransport(transport~ : String)
  MissingAgentCapability(capability~ : String)
}
