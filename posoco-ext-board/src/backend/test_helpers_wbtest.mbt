///|
fn backend_create(id : String, rev : Int64) -> @domain.BoardCommand {
  @domain.BoardCommand::CreateTask(
    id=@domain.BoardTaskId::BoardTaskId(id),
    title="task \{id}",
    description="",
    priority=@domain.Normal,
    definition_of_done=[],
    dependencies=[],
    at_ms=1000L,
    expected_revision=rev,
  )
}

///|
fn backend_tick(backend : BoardBackend) -> @protocol.BoardWireEvent {
  backend.publish_telemetry(board_revision=0L, kind="assistant.delta", payload={
    "text": "[redacted]",
  })
}
