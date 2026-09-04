// native target: direct argv spawn of a probed ast-grep binary.
//
// Candidates: PATH names (`ast-grep`, `sg`) first, then the common Homebrew
// prefixes. Each candidate is validated by spawning `--version` and
// checking the banner, so a look-alike shim on PATH is rejected (rg
// parity). Spawning a missing binary raises and the probe moves on; an
// exhausted ladder raises InvocationFailed with the install hint.

///|
priv struct NativeAstGrepSpawn {
  // Probe winner; resolved lazily on first spawn so argument validation in
  // the shared impl runs before any process is started.
  mut bin : String?
  // Working directory for the child; set only when the tool is anchored, so
  // the child cannot drift from the workspace root (bash parity).
  cwd : String?
}

///|
/// PATH candidate names, in probe order.
fn native_astgrep_candidates() -> Array[String] {
  [
    "ast-grep", "sg", "/opt/homebrew/bin/ast-grep", "/opt/homebrew/bin/sg", "/usr/local/bin/ast-grep",
    "/usr/local/bin/sg",
  ]
}

///|
/// One child process: `(exit_code, stdout, stderr)`. A failed spawn (e.g.
/// the binary is missing) raises so the probe ladder can try the next
/// candidate.
impl AstGrepSpawn for NativeAstGrepSpawn with fn spawn(
  self : NativeAstGrepSpawn,
  argv : Array[String],
) -> (Int, String, String) raise @posoco.RuntimeError {
  let bin = match self.bin {
    Some(bin) => bin
    None => {
      let probed = probe_native_astgrep()
      self.bin = Some(probed)
      probed
    }
  }
  let (exit_code, out, err) = match self.cwd {
    Some(cwd) =>
      @process.collect_output(bin, argv, cwd~) catch {
        _ =>
          raise @posoco.RuntimeError::InvocationFailed(
            "astgrep: failed to spawn '\{bin}'",
          )
      }
    None =>
      @process.collect_output(bin, argv) catch {
        _ =>
          raise @posoco.RuntimeError::InvocationFailed(
            "astgrep: failed to spawn '\{bin}'",
          )
      }
  }
  // Decode failure must not masquerade as empty output (which would read as
  // "no matches" on exit 0), so it raises instead.
  let stdout = out.text() catch {
    _ =>
      raise @posoco.RuntimeError::InvocationFailed(
        "astgrep: '\{bin}' produced non-UTF-8 output",
      )
  }
  let stderr = err.text() catch { _ => "" }
  (exit_code, stdout, stderr)
}

///|
/// First candidate that is a real ast-grep: spawn `--version` and require
/// the banner, so an `ast-grep`-named shim is rejected (rg parity). Raises
/// the install hint when the ladder is exhausted.
async fn probe_native_astgrep() -> String raise @posoco.RuntimeError {
  let candidates = native_astgrep_candidates()
  for candidate in candidates {
    let prober : NativeAstGrepSpawn = { bin: Some(candidate), cwd: None, }
    let result = AstGrepSpawn::spawn(prober, ["--version"]) catch {
      _ => continue
    }
    let (_, stdout, _) = result
    if stdout.contains("ast-grep") {
      return candidate
    }
  }
  raise @posoco.RuntimeError::InvocationFailed(missing_binary_error(candidates))
}

///|
pub impl @posoco.ToolProvider for AstGrepTools with fn list_tools(
  _self : AstGrepTools,
) -> Array[@posoco.ToolDef] {
  shared_list_tools()
}

///|
/// Execute the `astgrep` tool on native. Business logic lives in the shared
/// `execute_astgrep_impl`; this method only supplies the spawn backend. The
/// binary probe is lazy (first spawn), so argument errors surface without
/// the binary installed.
pub impl @posoco.ToolProvider for AstGrepTools with fn execute(
  self : AstGrepTools,
  _name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let cwd = match self.anchor {
    Some(anchor) => Some(anchor.root)
    None => None
  }
  execute_astgrep_impl(
    NativeAstGrepSpawn::{ bin: None, cwd, },
    self.anchor,
    call,
  )
}
