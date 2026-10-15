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
  self : Runtime,
  program : String,
  directory : String,
) -> String {
  if program.has_suffix(".wasm") {
    return program
  }
  let (code, diagnostics) = collect_process(
    self.moon,
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
  )
  if code != 0 {
    raise RuntimeError::BuildFailed(diagnostics)
  }
  artifact_path(diagnostics)
}
