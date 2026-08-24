///|
// wasm/wasm-gc: no subprocess API exists. Detection finds nothing, so the
// constructor returns None and the shared reporter never registers — the
// extension compiles everywhere but stays inert off native/js.

///|
#cfg(not(any(target="native", target="js")))
pub fn HerdrReporter::detect() -> HerdrReporter? {
  None
}

///|
#cfg(not(any(target="native", target="js")))
fn herdr_spawn_report(_bin : String, _args : Array[String]) -> Unit {
  ()
}
