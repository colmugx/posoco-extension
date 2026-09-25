///|
/// Memoh host adapter state.
///
/// V1 starts intentionally small: the same value is the Posoco SessionStore
/// view used by a Memoh-hosted agent. Conversation durability belongs to
/// Memoh, so this extension never becomes a second transcript authority.
pub struct Memoh {}

///|
/// Construct a Memoh host adapter.
pub fn Memoh::Memoh() -> Memoh {
  Memoh::{ }
}
