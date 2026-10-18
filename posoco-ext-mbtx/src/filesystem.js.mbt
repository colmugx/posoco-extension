///|
#module("node:fs")
extern "js" fn node_write_file(path : String, text : String) -> Unit = "writeFileSync"

///|
#external
priv type FsOptions

///|
#module("node:fs")
extern "js" fn node_rm(path : String, options : FsOptions) -> Unit = "rmSync"

///|
extern "js" fn recursive_options() -> FsOptions =
  #| () => ({recursive: true})

///|
#module("node:fs")
extern "js" fn node_mkdtemp(prefix : String) -> String = "mkdtempSync"

///|
#module("node:fs")
extern "js" fn node_realpath(path : String) -> String = "realpathSync"

///|
#module("node:os")
extern "js" fn node_tmpdir() -> String = "tmpdir"

///|
extern "js" fn fs_capture(action : () -> String) -> String =
  #| f => { try { return JSON.stringify({ok: true, value: f()}); } catch (e) { return JSON.stringify({ok: false, error: String(e)}); } }

///|
fn fs_value(action : () -> String) -> String raise {
  match @json.parse(fs_capture(action)) {
    { "ok": true, "value": String(value), .. } => value
    { "error": String(error), .. } => raise Failure::Failure(error)
    _ => raise Failure::Failure("invalid filesystem envelope")
  }
}

///|
fn temporary_directory(prefix : String) -> String raise {
  fs_value(() => node_realpath(node_mkdtemp(node_tmpdir() + "/" + prefix)))
}

///|
fn canonical_path(path : String) -> String raise {
  fs_value(() => node_realpath(path))
}

///|
fn write_text(path : String, text : String) -> Unit raise {
  ignore(
    fs_value(() => {
      node_write_file(path, text)
      ""
    }),
  )
}

///|
fn remove_directory(path : String) -> Unit raise {
  ignore(
    fs_value(() => {
      node_rm(path, recursive_options())
      ""
    }),
  )
}

///|
#module("node:fs")
extern "js" fn node_read_utf8(path : String, encoding : String) -> String = "readFileSync"

///|
#module("node:fs")
extern "js" fn node_copy_artifact(from : String, to : String) -> Unit = "copyFileSync"

///|
fn write_text_if_changed(path : String, source : String) -> Unit raise {
  let old = fs_value(() => node_read_utf8(path, "utf8")) catch { _ => "" }
  if old != source || !tc_fs_exists(path) {
    write_text(path, source)
  }
}

///|
fn copy_build_artifact(from : String, to : String) -> Unit raise {
  ignore(fs_value(() => { node_copy_artifact(from, to); "" }))
}
