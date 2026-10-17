///|
test "selection refs preserve opaque manager and model ids" {
  let manager = fake_manager()
  let selection = selection_ref(manager, revision=7L)
  assert_eq(selection.owner, "fake")
  assert_eq(selection.model_id, "plain")
  assert_eq(selection.effort, None)
  assert_eq(selection.revision, 7L)
  assert_true(selection.valid())
}

///|
test "invalid unqualified selection refs fail closed" {
  let selection : SelectionRef = {
    owner: "",
    model_id: "same-name",
    effort: None,
    pending: false,
    revision: 0L,
  }
  assert_false(selection.valid())
  assert_false({ ..selection, owner: "router", revision: -1L }.valid())
}

///|
test "optional observations distinguish unknown stale and unsupported" {
  let known : ModelObservation[Int] = Known(
    5,
    observed_at_ms=2L,
    provenance="adapter",
  )
  let stale : ModelObservation[Int] = Stale(
    5,
    observed_at_ms=1L,
    provenance="adapter",
  )
  let unknown : ModelObservation[Int] = Unknown("not observed")
  let unsupported : ModelObservation[Int] = Unsupported
  assert_true(known is Known(_))
  assert_true(stale is Stale(_))
  assert_true(unknown is Unknown(_))
  assert_true(unsupported is Unsupported)
}
