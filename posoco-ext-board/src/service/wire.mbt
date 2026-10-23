///|
/// Attach and prepare the backend before a wire client asks for a snapshot.
/// The workflow composition owns the same authoritative BoardBackend as the
/// planner and execution owner, so the browser sees exactly that state.
pub async fn BoardWorkflows::wire_ready(
  self : BoardWorkflows,
) -> Result[Unit, BoardWorkflowError] {
  self.initialize() catch {
    error => return Err(safe_error(error))
  }
  Ok(())
}

///|
/// One encoded authoritative Board snapshot for a wire client. This is the
/// same protocol frame the native Board host serves; the workflow dashboard
/// is a transport adapter, not a second projection.
pub async fn BoardWorkflows::wire_snapshot(
  self : BoardWorkflows,
) -> Result[String, BoardWorkflowError] {
  self.initialize() catch {
    error => return Err(safe_error(error))
  }
  match self.board.bootstrap_snapshot() {
    Ok(snapshot) =>
      Ok(@protocol.encode_server_frame(@protocol.Snapshot(snapshot)))
    Err(_) => Err(StoreUnavailable)
  }
}

///|
/// Decode one wire command, commit it through the shared backend and return
/// the encoded correlated result. Invalid frames get a protocol error frame
/// instead of escaping as a host exception.
pub async fn BoardWorkflows::wire_command(
  self : BoardWorkflows,
  raw : String,
) -> Result[String, BoardWorkflowError] {
  self.initialize() catch {
    error => return Err(safe_error(error))
  }
  let frame = match @protocol.decode_client_frame(raw) {
    Ok(@protocol.Command(command)) => {
      let result = self.board.handle_command(command)
      @protocol.encode_server_frame(@protocol.CommandResult(result))
    }
    Ok(_) =>
      @protocol.encode_server_frame(
        @protocol.Error(code="invalid_frame", message="Expected Command"),
      )
    Err(_) =>
      @protocol.encode_server_frame(
        @protocol.Error(code="invalid_json", message="Invalid frame"),
      )
  }
  Ok(frame)
}
