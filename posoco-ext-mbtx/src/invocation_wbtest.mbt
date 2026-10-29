///|
struct ClosedOutputProcess {}

///|
impl GuestProcess for ClosedOutputProcess with fn write(_self, _bytes) {
  ()
}

///|
impl GuestProcess for ClosedOutputProcess with fn stdout(_self) {
  None
}

///|
impl GuestProcess for ClosedOutputProcess with fn stderr(_self) {
  None
}

///|
impl GuestProcess for ClosedOutputProcess with fn wait(_self) {
  @async.sleep(60000)
  0
}

///|
async test "stdout EOF cannot bypass the initial hello deadline while process stays alive" {
  @async.with_timeout(1000, () => {
    try
      communicate(
        ClosedOutputProcess::{ },
        {},
        [],
        None,
        65536,
        8,
        128,
        1048576,
        20,
      )
    catch {
      RuntimeError::TimedOut("handshake") => ()
      error => raise error
    } noraise {
      _ => fail("EOF without hello was accepted")
    }
  })
}

///|
/// Core 0.10.18 keeps both spellings of gzip, so standalone-file compilation
/// cannot resolve its synthetic package. That is a toolchain defect and must
/// not be reported as a defect in the submitted script.
test "core alias collision is classified as a toolchain defect" {
  let observed =
    #|Error: Failed to solve package relationship
    #|    Error 1: Conflicting import alias: Both moonbitlang/core/async/gzip@0.10.18+6c83a7f62 (Source) and moonbitlang/core/compress/gzip@0.10.18+6c83a7f62 (Source) are imported into moon/test/single@0.0.1 with the same alias 'gzip'.
  assert_true(core_alias_collision(observed))
  assert_true(
    core_alias_collision_error(RuntimeError::GuestFailure(observed)) is Some(_),
  )
  // An unpublished import is the author's problem, not the toolchain's: it
  // must keep its original classification.
  let unresolved =
    #|Error: Failed to solve package relationship
    #|    package `moonbitlang/nowhere@9.9.9` not found
  assert_false(core_alias_collision(unresolved))
  assert_true(
    core_alias_collision_error(RuntimeError::BuildFailed(unresolved)) is None,
  )
}
