///|
struct SharedExecutionFactory {
  normal : ScriptFactory
  shared : &@posoco.Extension
}

///|
impl @service.WorkflowAgentFactory for SharedExecutionFactory with fn prepare(
  self,
  context,
) {
  if context.purpose == @service.WorkflowAgentPurpose::Planning {
    return @service.WorkflowAgentFactory::prepare(self.normal, context)
  }
  @async.sleep(5)
  {
    extensions: [self.shared],
    config: @posoco.agent_config(max_tool_rounds=Some(0)),
  }
}

///|
async test "yielding factories cannot lease the same extension capability to parallel slots" {
  let directory = @fixtures.temporary_directory()
  defer @fixtures.cleanup(directory)
  @async.with_task_group(group => {
    let state = ScriptState::{
      invalid: false,
      fail: false,
      delay: 100,
      chain: false,
      active: 0,
      peak: 0,
      contexts: [],
    }
    let ui = ScriptedUi::{ grant: true, prompts: [], before_answer: None, }
    let model = ScriptModel::{
      directory,
      state,
      context: {
        purpose: @service.WorkflowAgentPurpose::Execution,
        workflow_id: "shared",
        task_id: "shared",
        attempt_id: "shared",
        session_id: "shared",
        slot: 0,
      },
    }
    let board = @service.BoardWorkflows(
      directory~,
      group~,
      agents=SharedExecutionFactory::{
        normal: ScriptFactory::{ directory, state, },
        shared: model,
      },
      policy=@service.BoardWorkflowPolicy(
        enabled=true,
        max_concurrency=2,
        execution_timeout_ms=2000,
        max_elapsed_ms=10000,
      ),
      now_ms=() => 100L,
    )
    let parent = @posoco.Agent(
      exts=[model, ui, board],
      config=@posoco.agent_config(),
    )
    defer ignore(board.shutdown())
    let h = Harness::{ board, ui, state, parent, }
    let committed = proposed(h)
    let record = committed.snapshot.expansions[0]
    ignore(
      board
      .scope_decision(expansion_id=record.expansion_id.value, grant=true)
      .checked(),
    )
    for mapping in record.mapping {
      ignore(
        board
        .prepare(task_id=mapping.task_id.value, input="Trusted input")
        .checked(),
      )
    }
    ignore(board.run_wave().checked())
    let settled = board.wait_boundary().checked()
    assert_eq(state.peak, 1)
    let executions = settled.executions.filter(b => {
      record.mapping.any(m => m.task_id.value == b.task_id)
    })
    assert_eq(executions.length(), 2)
    assert_eq(
      executions
      .filter(b => {
        b.phase == @execution.Unresolved && b.outcome == Some(@execution.Failed)
      })
      .length(),
      1,
    )
    assert_true(settled.unresolved)
    assert_false(board.shutdown())
  })
}
