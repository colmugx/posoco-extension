///|
// ============================================================================
// posoco_ext_glob_js.mbt — ToolProvider for js target (bun >= 1.2).
//
// Active on: target="js"
// Provides:  JsGlobScanner (Bun.Glob-backed adaptor) and the complete
//            ToolProvider impl (list_tools + execute).
// ============================================================================

// ---------------------------------------------------------------------------
// Bun.Glob FFI bindings.
// ---------------------------------------------------------------------------

///|
#external
priv type BunGlob

///|
/// Construct a Bun.Glob from a pattern string. Synchronous in bun.
extern "js" fn bun_glob_new(pattern : String) -> BunGlob =
  #| (pattern) => new Bun.Glob(pattern)

///|
/// Drain `glob.scan({ cwd })` into a JS array of path strings.
/// Returns Promise<Array<string>>.
extern "js" fn BunGlob::scan_array(
  self : BunGlob,
  cwd : String,
) -> @js_async.Promise[Array[String]] =
  #| async (glob, cwd) => {
  #|   const out = [];
  #|   for await (const p of glob.scan({ cwd, dot: false })) {
  #|     out.push(p);
  #|   }
  #|   return out;
  #| }

// ---------------------------------------------------------------------------
// JsGlobScanner — Bun.Glob-backed adaptor.
// ---------------------------------------------------------------------------

///|
priv struct JsGlobScanner {}

///|
/// Delegate pattern matching to Bun.Glob and collect results.
impl GlobScanner for JsGlobScanner with fn scan(
  _self,
  pattern : String,
  base : String,
) -> Array[String] {
  let glob = bun_glob_new(pattern)
  glob.scan_array(base).wait() catch {
    _ =>
      raise @posoco.RuntimeError::InvocationFailed(
        "glob: scan failed for '\{@devkit.sanitize_path(base)}'",
      )
  }
}

// ---------------------------------------------------------------------------
// ToolProvider — complete impl (list_tools + execute) for js.
// ---------------------------------------------------------------------------

///|
pub impl @posoco.ToolProvider for GlobTools with fn list_tools(
  _self : GlobTools,
) -> Array[@posoco.ToolDef] {
  shared_list_tools()
}

///|
/// Execute the `glob` tool on js. Business logic lives in the shared
/// `execute_glob_impl`; this method only supplies the Bun.Glob scanner.
pub impl @posoco.ToolProvider for GlobTools with fn execute(
  _self : GlobTools,
  _name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  execute_glob_impl(JsGlobScanner::{  }, call)
}
