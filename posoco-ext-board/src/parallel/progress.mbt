///|
fn block_counts(
  rows : Array[@orchestration.BlockedExecution],
) -> Array[ParallelBlockCount] {
  let counts : Array[ParallelBlockCount] = []
  for row in rows {
    let seen : Array[@orchestration.ExecutionBlockReason] = []
    for reason in row.reasons {
      if seen.contains(reason) {
        continue
      }
      seen.push(reason)
      match counts.search_by(count => count.reason == reason) {
        Some(index) =>
          counts[index] = { reason, count: counts[index].count + 1, }
        None => counts.push({ reason, count: 1, })
      }
    }
  }
  counts
}
