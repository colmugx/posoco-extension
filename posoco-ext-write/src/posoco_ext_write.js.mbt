///|
// ============================================================================
// posoco_ext_write_js.mbt — js target (bun runtime) adaptor + ToolProvider impl.
//
// Active on: target="js"
// Provides:  Bun FFI bindings, JsFsIo adaptor (via Bun.write), and complete
//            ToolProvider impl
//
// Uses Bun's global `Bun.write` (returns Promise<number>) + `Bun.mkdir` to
// ensure the parent directory exists. Bun is a global object under bun, so
// `extern "js" fn ... = #| () => Bun.xxx()` works without require/import.
// ============================================================================

// ---------------------------------------------------------------------------
// Bun FFI bindings.
// ---------------------------------------------------------------------------

///|
/// `Bun.write(path, data)` returns Promise<number> (bytes written).
extern "js" fn bun_write_string(
  path : String,
  data : String,
) -> @js_async.Promise[Int] =
  #| (path, data) => Bun.write(path, data)

///|
/// `Bun.mkdir(path, { recursive })` returns Promise<string>.
/// Used to ensure parent directory exists before write.
extern "js" fn bun_mkdir(
  path : String,
  recursive : Bool,
) -> @js_async.Promise[String] =
  #| (path, recursive) => Bun.mkdir(path, { recursive })

///|
/// Compute the parent directory of a path. Returns "." if no slash.
fn parent_dir(path : String) -> String {
  match path.rev_find("/") {
    Some(pos) => if pos == 0 { "/" } else { path[0:pos].to_owned() }
    None => "."
  }
}

// ---------------------------------------------------------------------------
// JsFsIo — Bun-backed FsIo adaptor.
// ---------------------------------------------------------------------------

///|
priv struct JsFsIo {}

///|
/// Ensure parent dir exists (swallow race with existing dirs), then write.
/// Rejection from Bun.write = IO failure → RuntimeError.
impl FsIo for JsFsIo with fn write_text(_self, path : String, content : String) -> Unit {
  // Ensure parent dir exists (swallow race with existing dirs).
  let parent = parent_dir(path)
  if parent != "." {
    try {
      let _ = bun_mkdir(parent, true).wait()
    } catch {
      _ => ()
    }
  }
  let _bytes = bun_write_string(path, content).wait() catch {
    _ => raise write_failure(path)
  }
}

// ---------------------------------------------------------------------------
// ToolProvider — complete impl (list_tools + execute) for js.
// ---------------------------------------------------------------------------

///|
pub impl @posoco.ToolProvider for WriteTools with fn list_tools(
  _self : WriteTools,
) -> Array[@posoco.ToolDef] {
  shared_list_tools()
}

///|
/// Execute the `write` tool on js. Business logic lives in the shared
/// `execute_write_impl`; this method only supplies the Bun-backed adaptor.
pub impl @posoco.ToolProvider for WriteTools with fn execute(
  _self : WriteTools,
  _name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolResult raise @posoco.RuntimeError {
  execute_write_impl(JsFsIo::{  }, call)
}
