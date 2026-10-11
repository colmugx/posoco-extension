///|
impl @posoco.Extension for ExecutionGate with fn extension_id(_self) {
  "board.execution.gate"
}

///|
impl @posoco.Extension for ExecutionGate with fn manifest(self) {
  @posoco.ExtensionManifest::ExtensionManifest(
    id="board.execution.gate",
    observers=[self],
    hooks=[self],
  )
}
