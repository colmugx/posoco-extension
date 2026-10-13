///|
test "blocked reason counts count rows once and never alias plan arrays" {
  let rows : Array[@orchestration.BlockedExecution] = [
    {
      task_id: "a",
      attempt_id: None,
      reasons: [@orchestration.ExecutionActive, @orchestration.ExecutionActive],
    },
    {
      task_id: "b",
      attempt_id: None,
      reasons: [
        @orchestration.ExecutionActive,
        @orchestration.DependencyNotDone("a"),
      ],
    },
  ]
  let counts = block_counts(rows)
  assert_eq(counts, [
    { reason: @orchestration.ExecutionActive, count: 2, },
    { reason: @orchestration.DependencyNotDone("a"), count: 1, },
  ])
  counts.clear()
  assert_eq(rows[0].reasons.length(), 2)
  assert_eq(block_counts(rows).length(), 2)
}
