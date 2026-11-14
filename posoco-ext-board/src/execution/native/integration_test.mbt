///|
struct JournalModel {
  journal : @native.FileBoardExecutionStore
  mut calls : Int32
}

///|
impl @posoco.Extension for JournalModel with fn extension_id(_self) {
  "journal-integration-model"
}

///|
impl @posoco.Extension for JournalModel with fn manifest(self) {
  @posoco.ExtensionManifest::ExtensionManifest(id="journal-integration-model", models=[
    self,
  ])
}

///|
impl @posoco.ModelPort for JournalModel with fn provider_config(_self) {
  @posoco.ProviderConfig::empty()
}

///|
impl @posoco.ModelPort for JournalModel with fn chat(
  self,
  scope,
  messages,
  _tools,
  _options,
  _stream,
) {
  let recorded = self.journal.load() catch {
    _ => raise @posoco.ModelError::Transport("journal")
  }
  guard recorded is Ok([binding]) &&
    binding.phase == @execution.Running &&
    binding.run is Some(run) &&
    run.session_id == scope.session_id.to_string() &&
    run.run_id == scope.run_id.to_string() else {
    raise @posoco.ModelError::Transport("identity not durable before effect")
  }
  self.calls += 1
  {
    completion: @kernel.Completion::Completion(
      content=[@kernel.Text("done")],
      tool_calls=[],
      reasoning=None,
      finish_reason=Stop,
      usage=None,
    ),
    processed_messages: messages.to_owned(),
  }
}

///|
impl @posoco.ModelPort for JournalModel with fn compact(
  _self,
  _scope,
  _messages,
  _tools,
  _options,
  _trigger,
) {
  raise @posoco.ModelError::Transport("not used")
}

///|
async test "real scoped Agent with native identity journal preserves S3 snapshots and rejects execution after restart" {
  let root = @fs.tmpdir(prefix="board-real-execution-")
  defer @fs.rmdir(root, recursive=true)
  let board_store = @store.FileBoardStore(root~)
  let journal = @native.FileBoardExecutionStore(directory=root)
  let request : @execution.BoardExecutionRequest = {
    task_id: "task",
    attempt_id: "attempt",
    execution_id: "exec",
    session_id: "session",
    input: "explicit input",
    timeout_ms: None,
  }
  @async.with_task_group(group => {
    let backend = @backend.BoardBackend(store=board_store, now_ms=() => 100L)
    backend.attach(group)
    assert_true(backend.bootstrap_snapshot() is Ok(_))
    assert_true(
      backend.handle_command({
        command_id: "create",
        name: "board.task.create",
        expected_revision: 0L,
        args: {
          "id": "task",
          "title": "t",
          "description": "",
          "priority": "normal",
          "definition_of_done": [],
          "dependencies": [],
        },
      }).accepted,
    )
    assert_true(
      backend.handle_command({
        command_id: "queue",
        name: "board.attempt.queue",
        expected_revision: 1L,
        args: { "id": "attempt", "task_id": "task", "kind": "execute" },
      }).accepted,
    )
    // A valid S3 store remains readable without any execution journal fields.
    assert_eq(board_store.load().unwrap().snapshot.revision, 2L)
    let model : JournalModel = { journal, calls: 0, }
    let driver = @execution.PosocoBoardExecutionAdapter(extensions=() => [model])
    let owner = @execution.BoardExecutionOwner(
      backend~,
      adapter=driver,
      store=journal,
    )
    assert_true(owner.attach(group) is Ok(_))
    assert_eq(owner.execute(request).unwrap().wait().phase, @execution.Settled)
    assert_eq(model.calls, 1)
    assert_true(owner.shutdown())
    backend.shutdown()
    journal.close()
  })
  let restarted_journal = @native.FileBoardExecutionStore(directory=root)
  @async.with_task_group(group => {
    let backend = @backend.BoardBackend(store=@store.FileBoardStore(root~))
    backend.attach(group)
    assert_true(backend.bootstrap_snapshot() is Ok(_))
    let state = backend.state().unwrap()
    assert_eq(state.revision, 4L)
    assert_true(state.attempts[0].status is Succeeded)
    assert_true(state.tasks[0].stage is Created)
    let model : JournalModel = { journal: restarted_journal, calls: 0, }
    let owner = @execution.BoardExecutionOwner(
      backend~,
      adapter=@execution.PosocoBoardExecutionAdapter(extensions=() => [model]),
      store=restarted_journal,
    )
    assert_true(owner.attach(group) is Ok(_))
    assert_true(owner.execute(request) is Err(@execution.DuplicateIdentity))
    assert_eq(model.calls, 0)
    assert_true(owner.shutdown())
    backend.shutdown()
    restarted_journal.close()
  })
}
