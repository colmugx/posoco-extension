///|
test "ledger_default_limit_is_64" {
  let ledger = SpawnLedger::SpawnLedger()
  assert_eq(ledger.remaining(), 64)
  assert_eq(ledger.acquired(), [])
}

///|
test "ledger_explicit_limit" {
  let ledger = SpawnLedger::SpawnLedger(limit=8)
  assert_eq(ledger.remaining(), 8)
}

///|
test "ledger_refuses_at_limit_and_counts_down" {
  let ledger = SpawnLedger::SpawnLedger(limit=2)
  assert_true(ledger.try_acquire("spawn-a"))
  assert_eq(ledger.remaining(), 1)
  assert_true(ledger.try_acquire("spawn-b"))
  assert_eq(ledger.remaining(), 0)
  // Budget exhausted: explicit refusal, nothing queued silently.
  assert_false(ledger.try_acquire("spawn-c"))
  assert_false(ledger.try_acquire("spawn-d"))
  assert_eq(ledger.remaining(), 0)
  assert_eq(ledger.acquired(), ["spawn-a", "spawn-b"])
}

///|
test "ledger_records_duplicate_labels_separately" {
  let ledger = SpawnLedger::SpawnLedger(limit=3)
  assert_true(ledger.try_acquire("review"))
  assert_true(ledger.try_acquire("review"))
  assert_eq(ledger.acquired(), ["review", "review"])
  assert_eq(ledger.remaining(), 1)
}

///|
test "ledger_acquired_returns_a_copy" {
  let ledger = SpawnLedger::SpawnLedger(limit=2)
  let _ = ledger.try_acquire("a")
  let snapshot = ledger.acquired()
  snapshot.push("mutated")
  assert_eq(ledger.acquired(), ["a"])
}
