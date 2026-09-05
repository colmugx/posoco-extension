///|
/// The face for backends without an execution edge (anything beyond native,
/// wasm and js — none of which ship an async process/fs face today):
/// `list_tools` returns [] and `execute` raises immediately. The inert seams
/// below exist so the target-shared pipeline and toolchain logic compile on
/// such backends.

///|
#cfg(not(any(target="native", target="wasm", target="js")))
pub impl @posoco.ToolProvider for MbtxTools with fn list_tools(
  _self : MbtxTools,
) -> Array[@posoco.ToolDef] {
  []
}

///|
#cfg(not(any(target="native", target="wasm", target="js")))
pub impl @posoco.ToolProvider for MbtxTools with fn execute(
  _self : MbtxTools,
  _name : String,
  _call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  raise @posoco.RuntimeError::InvocationFailed(
    "mbtx requires the native, wasm or js target",
  )
}

///|
/// Inert Runner: never reached (the execute impl above raises first); it
/// exists only so the canonical constructor stays target-blind.
#cfg(not(any(target="native", target="wasm", target="js")))
priv struct InertRunner {}

///|
#cfg(not(any(target="native", target="wasm", target="js")))
impl Runner for InertRunner with fn run(
  _self : InertRunner,
  _cmd : String,
  _args : Array[String],
  _cwd : String?,
  _budget_ms : Int,
) -> (Int, String, Bool) {
  raise @posoco.RuntimeError::InvocationFailed(
    "mbtx requires the native, wasm or js target",
  )
}

///|
#cfg(not(any(target="native", target="wasm", target="js")))
fn mbtx_default_runner() -> &Runner {
  InertRunner::{ }
}

///|
#cfg(not(any(target="native", target="wasm", target="js")))
#warnings("-unused_async")
async fn MbtxTools::ensure_toolchain(
  _self : MbtxTools,
) -> ResolvedToolchain raise @posoco.RuntimeError {
  raise @posoco.RuntimeError::InvocationFailed(
    "mbtx requires the native, wasm or js target",
  )
}

///|
#cfg(not(any(target="native", target="wasm", target="js")))
#warnings("-unused_async")
async fn toolchain_dir_usable(
  _bin_dir : String,
) -> Bool raise @posoco.RuntimeError {
  raise @posoco.RuntimeError::InvocationFailed(
    "mbtx requires the native, wasm or js target",
  )
}

///|
#cfg(not(any(target="native", target="wasm", target="js")))
#warnings("-unused_async")
async fn mbtx_call_tmpdir() -> String raise @posoco.RuntimeError {
  raise @posoco.RuntimeError::InvocationFailed(
    "mbtx requires the native, wasm or js target",
  )
}

///|
#cfg(not(any(target="native", target="wasm", target="js")))
#warnings("-unused_async")
async fn mbtx_write_file(
  _path : String,
  _content : String,
) -> Unit raise @posoco.RuntimeError {
  raise @posoco.RuntimeError::InvocationFailed(
    "mbtx requires the native, wasm or js target",
  )
}

///|
#cfg(not(any(target="native", target="wasm", target="js")))
#warnings("-unused_async")
async fn mbtx_cleanup_tmpdir(
  _tmpdir : String,
) -> Unit raise @posoco.RuntimeError {
  raise @posoco.RuntimeError::InvocationFailed(
    "mbtx requires the native, wasm or js target",
  )
}

///|
#cfg(not(any(target="native", target="wasm", target="js")))
#warnings("-unused_async")
async fn mbtx_realpath(_path : String) -> String {
  raise @posoco.RuntimeError::InvocationFailed(
    "mbtx requires the native, wasm or js target",
  )
}
