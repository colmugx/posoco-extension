///|
struct ClosedOutputProcess {}

///|
impl GuestProcess for ClosedOutputProcess with fn write(_self, _bytes) { () }

///|
impl GuestProcess for ClosedOutputProcess with fn stdout(_self) { None }

///|
impl GuestProcess for ClosedOutputProcess with fn stderr(_self) { None }

///|
impl GuestProcess for ClosedOutputProcess with fn wait(_self) {
  @async.sleep(60000)
  0
}

///|
async test "stdout EOF cannot bypass the initial hello deadline while process stays alive" {
  @async.with_timeout(1000, () => {
    try communicate(ClosedOutputProcess::{}, {}, [], None, 65536, 8, 128, 1048576, 20) catch {
      RuntimeError::TimedOut("handshake") => ()
      error => raise error
    } noraise { _ => fail("EOF without hello was accepted") }
  })
}
