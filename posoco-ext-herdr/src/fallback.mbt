///|
// wasm/wasm-gc reporter: detection finds nothing, so the constructor
// returns None and the shared reporter never registers. The reporter stays
// inert on wasm because its spawn path is a synchronous detached launch
// (libc system() on native, Bun.spawn on js) fired from Observer
// callbacks; wasm has no sync spawn. The delegate below is unaffected: it
// runs the herdr CLI through @process and works on wasm.

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
