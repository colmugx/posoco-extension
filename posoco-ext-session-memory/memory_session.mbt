///|
/// InMemorySessionStore — stores sessions in a mutable Map
pub(all) struct InMemorySessionStore {
  mut store : Map[String, @posoco.Session]
}

///|
/// Create a new empty store
pub fn InMemorySessionStore::new() -> InMemorySessionStore {
  { store: Map::from_array([]) }
}

///|
/// Create a store pre-populated with sessions
pub fn InMemorySessionStore::with_sessions(
  sessions : Map[String, @posoco.Session],
) -> InMemorySessionStore {
  { store: sessions }
}

///|
pub impl @posoco.SessionStore for InMemorySessionStore with load(
  self,
  id : String,
) -> Result[@posoco.Session, @posoco.SessionError] {
  if self.store.contains(id) {
    Ok(self.store[id])
  } else {
    Ok(@posoco.Session::{ messages: [], metadata: Map::from_array([]) })
  }
}

///|
pub impl @posoco.SessionStore for InMemorySessionStore with save(
  self,
  id : String,
  session : @posoco.Session,
) -> Result[Unit, @posoco.SessionError] {
  self.store[id] = session
  Ok(())
}

///|
/// Dump all session IDs (for debugging/inspection)
pub fn InMemorySessionStore::session_ids(self : InMemorySessionStore) -> Array[String] {
  self.store.keys().to_array()
}
