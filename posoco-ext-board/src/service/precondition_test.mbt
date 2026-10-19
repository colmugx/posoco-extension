///|
/// Opt-in, trusted-UI and bounded-budget preconditions are checked before any
/// prompt, directory preparation, journal lock or model call. Every denial
/// leaves the private directory exactly as it was.
async test "disabled, missing-UI and invalid-budget denials perform no IO" {
  let disabled_directory = @fixtures.temporary_directory()
  defer @fixtures.cleanup(disabled_directory)
  @async.with_task_group(group => {
    let h = harness(disabled_directory, group, enabled=false)
    defer ignore(h.board.shutdown())
    assert_eq(h.board.start(title="Disabled workflow"), Err(@service.Disabled))
    assert_eq(h.board.view().checked().snapshot.tasks.length(), 0)
    assert_true(h.state.contexts.is_empty())
    assert_true(h.ui.prompts.is_empty())
    assert_no_storage_io(disabled_directory)
  })
  let bare_directory = @fixtures.temporary_directory()
  defer @fixtures.cleanup(bare_directory)
  @async.with_task_group(group => {
    let state = ScriptState::{
      invalid: false,
      fail: false,
      delay: 1,
      chain: true,
      active: 0,
      peak: 0,
      contexts: [],
    }
    let ui = ScriptedUi::{ grant: true, prompts: [], before_answer: None, }
    // Deliberately never composed into an Agent, so no trusted UI port binds.
    let board = @service.BoardWorkflows(
      directory=bare_directory,
      group~,
      agents=ScriptFactory::{ directory: bare_directory, state, },
      policy=@service.BoardWorkflowPolicy(
        enabled=true,
        max_executions=8,
        continue_on_confirmed_failure=false,
        execution_timeout_ms=1000,
        max_elapsed_ms=10000,
      ),
      now_ms=() => 100L,
    )
    defer ignore(board.shutdown())
    assert_eq(board.start(title="Uncomposed workflow"), Err(@service.MissingUi))
    assert_eq(board.view().checked().snapshot.tasks.length(), 0)
    assert_true(ui.prompts.is_empty())
    assert_true(state.contexts.is_empty())
    assert_no_storage_io(bare_directory)
  })
  let invalid_directory = @fixtures.temporary_directory()
  defer @fixtures.cleanup(invalid_directory)
  @async.with_task_group(group => {
    let state = ScriptState::{
      invalid: false,
      fail: false,
      delay: 1,
      chain: true,
      active: 0,
      peak: 0,
      contexts: [],
    }
    let ui = ScriptedUi::{ grant: true, prompts: [], before_answer: None, }
    let board = @service.BoardWorkflows(
      directory=invalid_directory,
      group~,
      agents=ScriptFactory::{ directory: invalid_directory, state, },
      policy=@service.BoardWorkflowPolicy(
        enabled=true,
        max_executions=8,
        execution_timeout_ms=2000,
        max_elapsed_ms=1000,
      ),
      now_ms=() => 100L,
    )
    let parent_model = ScriptModel::{
      directory: invalid_directory,
      state,
      context: {
        purpose: @service.WorkflowAgentPurpose::Execution,
        workflow_id: "parent",
        task_id: "parent",
        attempt_id: "parent",
        session_id: "parent",
        slot: 0,
      },
    }
    // An unbounded policy fails composition closed: no capability binds, so
    // no start path can ever bypass the budget validation.
    let refused = try {
      ignore(
        @posoco.Agent(
          exts=[parent_model, ui, board],
          config=@posoco.agent_config(),
        ),
      )
      ""
    } catch {
      @posoco.CompositionError::ManifestSchemaError(manifest_id~, detail~) =>
        manifest_id + ":" + detail
      _ => "unexpected composition outcome"
    }
    assert_eq(
      refused, "posoco_ext_board:invalid Board workflow directory or bounded policy",
    )
    assert_eq(board.view().checked().snapshot.tasks.length(), 0)
    assert_true(ui.prompts.is_empty())
    assert_true(state.contexts.is_empty())
    assert_no_storage_io(invalid_directory)
  })
}
