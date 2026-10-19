///|
async fn executable_failure(command : String) -> String? {
  let (code, output) = collect_process(command, ["--version"], None) catch {
    error => return Some(command + ": " + error.to_string())
  }
  if code == 0 {
    None
  } else {
    Some(command + " --version exited with " + code.to_string() + ": " + output)
  }
}

///|
async fn Runtime::resolve_launcher(self : Runtime) -> Launcher {
  let failures = []
  if self.launcher != Moon {
    match executable_failure(self.moonx) {
      None => return Moonx
      Some(message) => failures.push(message)
    }
  }
  if self.launcher != Moonx {
    match executable_failure(self.moon) {
      None => return Moon
      Some(message) => failures.push(message)
    }
  }
  raise RuntimeError::ToolchainUnavailable(
    "install the MoonBit toolchain or make moonx available on PATH\n" +
    failures.join("\n"),
  )
}

///|
fn artifact_path(output : String) -> String raise RuntimeError {
  for line in output.split("\n") {
    let value = @json.parse(line.to_owned()) catch { _ => continue }
    match value {
      { "artifacts_path": [String(path), ..], .. } => return path
      _ => ()
    }
  }
  raise BuildFailed("compiler did not report an artifact path\n" + output)
}

///|
async fn Runtime::build_program(
  _self : Runtime,
  program : String,
  directory : String,
  toolchain : ResolvedToolchain,
) -> String {
  if program.has_suffix(".wasm") {
    return program
  }
  let (code, diagnostics) = collect_process(
    toolchain.moon,
    [
      "run",
      "--build-only",
      "--target",
      "wasm",
      "--output-json",
      "--target-dir",
      directory + "/build",
      program,
    ],
    None,
    extra_env=mbtx_env(toolchain),
  )
  if code != 0 {
    raise RuntimeError::BuildFailed(diagnostics)
  }
  artifact_path(diagnostics)
}

///|
/// Automatic paths use extension-owned discovery. Custom launcher paths
/// preserve the old explicit override semantics, with no auto download.
async fn Runtime::resolve_toolchain(self : Runtime) -> ResolvedToolchain {
  if self.launcher == Auto &&
    self.moon == "moon" &&
    self.moonx == "moonx" &&
    self.moonrun == "moonrun" {
    return self.toolchain.ensure_ready()
  }
  let launcher = self.resolve_launcher()
  {
    origin: System,
    version: "explicit",
    launcher,
    moon: self.moon,
    moonx: self.moonx,
    moonrun: self.moonrun,
    bin_dir: "",
  }
}

///|
/// Per-Runtime single writer around the shared incremental build directory.
/// The artifact is copied before lock release; a later build cannot replace
/// the binary of an already-running guest.
async fn Runtime::build_cached_source(
  self : Runtime,
  source : String,
  invocation_dir : String,
  tc : ResolvedToolchain,
) -> String {
  guard self.build_cache is Some(root) && root != "" else {
    raise RuntimeError::Invalid("build cache is not configured")
  }
  self.build_lock.acquire()
  defer self.build_lock.release()
  tc_fs_mkdir(root)
  // Include compiler version in the key: a changed toolchain must not
  // reuse an old build graph or Wasm artifact.
  let keyed = root + "/" + cached_source_key(tc.version + ":" + source)
  tc_fs_mkdir(keyed)
  let lock = keyed + "/.build.lock"
  let mut locked = false
  for _ in 0..<600 {
    if tc_fs_try_lock(lock) {
      locked = true
      break
    }
    @async.sleep(100)
  }
  if !locked {
    raise RuntimeError::BuildFailed(
      "timed out waiting for shared compiler cache",
    )
  }
  defer tc_fs_unlock(lock)
  let source_path = keyed + "/snippet.mbtx"
  write_text_if_changed(source_path, source)
  let wasm = self.build_program(source_path, keyed, tc)
  let destination = invocation_dir + "/cached.wasm"
  copy_build_artifact(wasm, destination)
  destination
}

///|
/// Stable content key; the compiler still verifies content in the staged
/// file, so a hash collision alone does not make the cache authoritative.
fn cached_source_key(source : String) -> String {
  let mut hash : UInt64 = 0xcbf29ce484222325
  for char in source {
    hash = (hash ^ char.to_int().to_uint64()) * 0x100000001b3
  }
  hash.to_string()
}
