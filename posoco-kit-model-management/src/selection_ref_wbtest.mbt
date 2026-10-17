///|
test "selection refs preserve opaque manager and model ids" {
  let manager = fake_manager()
  let ref = selection_ref(manager, revision=7L)
  assert_eq(ref.owner, "fake")
  assert_eq(ref.model_id, "plain")
  assert_eq(ref.effort, None)
  assert_eq(ref.revision, 7L)
  assert_true(ref.valid())
}

///|
test "invalid unqualified selection refs fail closed" {
  let ref : SelectionRef = {
    owner: "",
    model_id: "same-name",
    effort: None,
    pending: false,
    revision: 0L,
  }
  assert_false(ref.valid())
  assert_false({ ..ref, owner: "router", revision: -1L }.valid())
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
  assert_true(known is Known(..))
  assert_true(stale is Stale(..))
  assert_true(unknown is Unknown(..))
  assert_true(unsupported is Unsupported)
}
