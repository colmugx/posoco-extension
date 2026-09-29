///|
/// Stable v1 wire protocol version. The browser and server negotiate this in
/// the initial hello frame before commands are accepted.
pub fn protocol_version() -> Int {
  1
}
