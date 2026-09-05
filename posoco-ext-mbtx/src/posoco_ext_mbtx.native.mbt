///|
/// Native/wasm execution edges for the shared pipeline
/// (`pipeline.mbt`): the `@process`-backed Runner and the
/// `@fs`-backed file seams. The business logic never touches these packages
/// directly, so js swaps in Bun equivalents with the same signatures.

///|
/// The production Runner on native and wasm: one merged-output subprocess
/// via `@process`. The stage budget is not read here — timing is owned by
/// the `@async.with_timeout` layer, whose cancellation tears the collection
/// task down (its cancel handler SIGTERMs the child). Spawn failures and
/// cancellation propagate raw (generic `Error`); the timing layer
/// classifies them — a blanket catch here would swallow the budget-expiry
/// cancellation into a bogus "failed to run".
priv struct ProcessRunner {}

///|
impl Runner for ProcessRunner with fn run(
  _self : ProcessRunner,
  cmd : String,
  args : Array[String],
  cwd : String?,
  _budget_ms : Int,
) -> (Int, String, Bool) {
  let (exit_code, output) = match cwd {
    Some(dir) => @process.collect_output_merged(cmd, args, cwd=dir)
    None => @process.collect_output_merged(cmd, args)
  }
  // Decode failure must not masquerade as empty successful output; it is
  // reported through the decoded_ok channel instead.
  let mut decoded = true
  let text = output.text() catch {
    _ => {
      decoded = false
      ""
    }
  }
  (exit_code, text, decoded)
}

///|
fn mbtx_default_runner() -> &Runner {
  ProcessRunner::{ }
}

///|
/// The call's one-shot temp directory (a fresh mkdtemp-style dir under the
/// system temp location). Failures are infrastructure (unusable temp
/// location) and surface as RuntimeError, not as a model-visible error.
async fn mbtx_call_tmpdir() -> String raise @posoco.RuntimeError {
  @fs.tmpdir(prefix="posoco-mbtx-") catch {
    err =>
      raise @posoco.RuntimeError::InvocationFailed(
        "mbtx: could not create the call temp dir: \{err.to_string()}",
      )
  }
}

///|
/// One call-file write; failures are infrastructure (unusable temp dir) and
/// surface as RuntimeError, not as a model-visible business error.
async fn mbtx_write_file(
  path : String,
  content : String,
) -> Unit raise @posoco.RuntimeError {
  @fs.write_file(path, content) catch {
    err =>
      raise @posoco.RuntimeError::InvocationFailed(
        "mbtx: could not write '\{path}': \{err.to_string()}",
      )
  }
}

///|
/// Best-effort recursive cleanup; a failed cleanup is never fatal (the dir
/// lives under the system temp location either way). (Explicit error type:
/// async fns default to the generic `Error`, which the RuntimeError-raising
/// caller rejects; the body itself swallows the rmdir failure.)
#warnings("-unused_error_type")
async fn mbtx_cleanup_tmpdir(
  tmpdir : String,
) -> Unit raise @posoco.RuntimeError {
  @fs.rmdir(tmpdir, recursive=true) catch {
    _ => ()
  }
}

///|
/// Best-effort realpath for BUILD-diagnostic hygiene; callers swallow the
/// failure and keep the raw path. (Generic raise: mirrors `@fs.realpath`;
/// the RuntimeError-typed caller catches it.)
async fn mbtx_realpath(path : String) -> String {
  @fs.realpath(path)
}

///|
/// Host-environment toolchain edge: the override / this host's PATH / the
/// host home's `~/.moon/bin`, probed in that order (see `toolchain.mbt`).
async fn MbtxTools::ensure_toolchain(
  self : MbtxTools,
) -> ResolvedToolchain raise @posoco.RuntimeError {
  self.ensure_toolchain_from(
    path_env=@env.get_env_var("PATH"),
    home_dir=@env.get_env_var("HOME"),
  )
}

///|
/// A candidate is usable only when BOTH `moon` and `moonrun` are executable
/// (`@fs.can_execute`: false for missing or non-executable entries).
/// Accepted gap: a directory named `moon` with the execute bit set would
/// pass this probe — not a real-world shape for PATH entries. (Explicit
/// error type: async fns default to the generic `Error`, which the
/// RuntimeError-raising caller rejects; the body itself swallows probe
/// failures into `false`.)
#warnings("-unused_error_type")
async fn toolchain_dir_usable(
  bin_dir : String,
) -> Bool raise @posoco.RuntimeError {
  let moon_ok = @fs.can_execute("\{bin_dir}/moon") catch { _ => false }
  let moonrun_ok = @fs.can_execute("\{bin_dir}/moonrun") catch { _ => false }
  moon_ok && moonrun_ok
}
