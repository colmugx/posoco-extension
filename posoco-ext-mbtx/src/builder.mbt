///|
let sdk_files : Array[String] = [
  "protocol/framing.mbt", "protocol/messages.mbt", "protocol/session.mbt", "protocol/moon.pkg",
  "sdk/context.mbt", "sdk/moon.pkg", "sdk/stdio/serve.mbt", "sdk/stdio/moon.pkg",
]

///|
async fn dependency_snapshot(
  root : String,
  prefix : String,
  files : Array[(String, String)],
) -> Unit {
  for name in list_directory(root) {
    if name.has_prefix(".") || name == "_build" || name == "target" {
      continue
    }
    let path = root + "/" + name
    let relative = prefix + name
    if path_kind(path) == "directory" {
      dependency_snapshot(path, relative + "/", files)
    } else if name == "moon.mod" ||
      name == "moon.pkg" ||
      name.has_suffix(".mbt") ||
      name.has_suffix(".c") ||
      name.has_suffix(".h") ||
      name.has_suffix(".json") {
      if name.has_suffix("_test.mbt") || name.has_suffix("_wbtest.mbt") {
        continue
      }
      files.push((relative, read_text(path)))
    }
  }
}

///|
async fn stage_file(root : String, path : String, text : String) -> Unit {
  @async.pause()
  let components = path.split("/").to_array()
  if components.length() > 1 {
    let directory = components[:components.length() - 1]
      .map(part => part.to_owned())
      .join("/")
    make_directory(root + "/" + directory)
  }
  write_text(root + "/" + path, text)
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
pub async fn Runtime::build(
  self : Runtime,
  source : String,
  timeout_ms~ : Int32 = 30000,
) -> Artifact {
  if source == "" || @utf8.encode(source).length() > 1048576 || timeout_ms <= 0 {
    raise RuntimeError::Invalid(
      "source must be 1..1048576 bytes and build timeout must be positive",
    )
  }
  self.build_lock.acquire()
  defer self.build_lock.release()
  if self.closed {
    raise RuntimeError::Closed
  }
  @async.with_timeout(timeout_ms, () => {
    let (moon_code, toolchain) = collect_process(
      self.moon,
      ["version", "--all"],
      None,
    )
    let (run_code, runner) = collect_process(self.moonrun, ["--version"], None)
    if moon_code != 0 || run_code != 0 {
      raise RuntimeError::BuildFailed("toolchain identity probe failed")
    }
    let files : Array[(String, String)] = []
    for path in sdk_files {
      files.push(
        ("guest/src/" + path, read_text(self.sdk_source_root + "/" + path)),
      )
    }
    dependency_snapshot(self.async_source_root, "async/", files)
    let main = source + "\n///|\nasync fn main { @mbtx.serve(run) }\n"
    let mod = "name = \"colmugx/posoco-ext-mbtx\"\nversion = \"0.0.0\"\nsource = \"src\"\nimport { \"moonbitlang/async@0.22.4\" }\n"
    let pkg = "import { \"colmugx/posoco-ext-mbtx/sdk/stdio\" @mbtx, \"colmugx/posoco-ext-mbtx/sdk\", \"colmugx/posoco-ext-mbtx/protocol\", \"moonbitlang/async\", \"moonbitlang/core/json\" }\nsupported_targets = \"wasm\"\noptions(\"is-main\": true)\n"
    files.push(("guest/moon.mod", mod))
    files.push(("guest/src/cmd/main/moon.pkg", pkg))
    files.push(("guest/src/cmd/main/main.mbt", main))
    files.push(("moon.work", "members = [\"./guest\", \"./async\"]\n"))
    // Exact content keys deliberately avoid hash collisions, including dependency inputs.
    let descriptor : Json = {
      "files": Json(files),
      "toolchain": toolchain,
      "runner": runner,
      "target": "wasm",
      "release": false,
      "protocol": @protocol.version,
    }
    let key = descriptor.stringify()
    match self.cache.get(key) {
      Some(artifact) => return artifact
      None => ()
    }
    if self.cache.length() >= 16 {
      raise RuntimeError::Invalid(
        "artifact cache full; clear idle cache explicitly",
      )
    }
    let workspace = temporary_directory("posoco-mbtx-artifact-")
    let artifact = @async.with_task_group(group => {
      let mut published = false
      group.add_defer(() => if !published { remove_directory(workspace) })
      for file in files {
        let (path, text) = file
        stage_file(workspace, path, text)
      }
      let (code, diagnostics) = collect_process(
        self.moon,
        [
          "run", "src/cmd/main", "--build-only", "--target", "wasm", "--output-json",
          "--frozen",
        ],
        Some(workspace + "/guest"),
      )
      if code != 0 {
        raise RuntimeError::BuildFailed(
          diagnostics
          .replace_all(
            old=workspace + "/guest/src/cmd/main/main.mbt",
            new="program.mbtx",
          )
          .replace_all(old=workspace, new="."),
        )
      }
      let path = artifact_path(diagnostics)
      let artifact = Artifact::{ path, workspace, key, }
      self.cache[key] = artifact
      published = true
      artifact
    })
    artifact
  }) catch {
    error =>
      if error is @async.TimeoutError {
        raise RuntimeError::TimedOut("build")
      } else {
        raise error
      }
  }
}
