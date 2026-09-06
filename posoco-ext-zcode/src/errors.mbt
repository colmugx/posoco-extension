///|
/// Errors raised by the posoco-ext-zcode extension. `detail` payloads carry
/// paths, statuses, and server messages — never credential values; the
/// provider registry that does carry api keys stays plain Json with no
/// derives at all (see registry.mbt).
pub(all) suberror ZcodeError {
  /// config.bin, ZCODE_BIN, PATH lookup, and platform bundle candidates all
  /// missed.
  ZcodeBinNotFound
  /// Spawning the resolved command failed.
  ZcodeSpawnFailed(detail~ : String)
  /// The v2 credentials file is missing or unparsable.
  ZcodeCredsUnreadable(detail~ : String)
  /// Wire decode failure or missing required protocol field.
  ZcodeProtocol(detail~ : String)
  /// The app-server answered a request with an error response.
  ZcodeRpc(code~ : Int, message~ : String)
  /// Server message contains "Model config is missing" — the pushed provider
  /// registry was rejected; check ~/.zcode/v2 credentials.
  ZcodeModelConfig(detail~ : String)
  /// The delegation exceeded ZcodeConfig.timeout_ms.
  ZcodeTimeout
  /// The app-server process exited before the turn reached a terminal event.
  ZcodeProcessDied(detail~ : String)
} derive(Debug)

///|
pub impl Show for ZcodeError with fn to_string(self) -> String {
  match self {
    ZcodeBinNotFound => "ZcodeError::ZcodeBinNotFound"
    ZcodeSpawnFailed(detail~) => "ZcodeError::ZcodeSpawnFailed(\{detail})"
    ZcodeCredsUnreadable(detail~) =>
      "ZcodeError::ZcodeCredsUnreadable(\{detail})"
    ZcodeProtocol(detail~) => "ZcodeError::ZcodeProtocol(\{detail})"
    ZcodeRpc(code~, message~) =>
      "ZcodeError::ZcodeRpc(code=\{code}, message=\{message})"
    ZcodeModelConfig(detail~) => "ZcodeError::ZcodeModelConfig(\{detail})"
    ZcodeTimeout => "ZcodeError::ZcodeTimeout"
    ZcodeProcessDied(detail~) => "ZcodeError::ZcodeProcessDied(\{detail})"
  }
}
