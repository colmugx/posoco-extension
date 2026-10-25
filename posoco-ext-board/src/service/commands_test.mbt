///|
async test "board workflow commands are internal and expose no slash command" {
  let directory = @fixtures.temporary_directory()
  defer @fixtures.cleanup(directory)
  @async.with_task_group(group => {
    let h = harness(directory, group)
    defer ignore(h.board.shutdown())
    let definitions = (h.board as &@posoco.CommandPort).commands()
    assert_true(definitions.length() > 1)
    for definition in definitions {
      // Every definition is a Board id: none is user-discoverable, and none
      // carries a `/workflow` alias.
      assert_true(definition.id.has_prefix("board."))
      assert_false(definition.visible)
      assert_true(definition.aliases.is_empty())
    }
    // `/workflow` has no definition at all, and `/board` is a terminal-local
    // route rather than a registered command.
    assert_true(definitions.all(definition => definition.id != "workflow"))
    assert_true(definitions.all(definition => definition.id != "board"))
    // The internal ids stay registered and callable.
    assert_true(
      definitions.any(definition => definition.id == "board.workflow"),
    )
    assert_true(
      definitions.any(definition => definition.id == "board.workflow.status"),
    )
    let outcome = (h.board as &@posoco.CommandPort).invoke(
      "board.workflow.status",
      Json::object({}),
    )
    assert_true(outcome is @posoco.CommandOutcome::Success(..))
  })
}
