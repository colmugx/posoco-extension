///|
#module("node:fs")
extern "js" fn node_read_file(path : String, encoding : String) -> String = "readFileSync"

///|
#module("node:fs")
extern "js" fn node_write_file(path : String, text : String) -> Unit = "writeFileSync"

///|
#module("node:fs")
extern "js" fn node_list(path : String) -> FixedArray[String] = "readdirSync"

///|
#external
priv type FsOptions

///|
#module("node:fs")
extern "js" fn node_mkdir(path : String, options : FsOptions) -> Unit = "mkdirSync"

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
#external
priv type FsStat

///|
#module("node:fs")
extern "js" fn node_stat(path : String) -> FsStat = "lstatSync"

///|
extern "js" fn stat_kind(stat : FsStat) -> String =
  #| s => s.isFile() ? 'file' : s.isDirectory() ? 'directory' : 'unsupported'

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
fn read_text(path : String) -> String raise {
  fs_value(() => node_read_file(path, "utf8"))
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
fn make_directory(path : String) -> Unit raise {
  ignore(
    fs_value(() => {
      node_mkdir(path, recursive_options())
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
fn list_directory(path : String) -> Array[String] raise {
  let encoded = fs_value(() => Json(node_list(path)).stringify())
  match @json.parse(encoded) {
    Array(values) =>
      values.map(value => {
        match value {
          String(name) => name
          _ => raise Failure::Failure("invalid directory entry")
        }
      })
    _ => raise Failure::Failure("invalid directory envelope")
  }
}

///|
fn path_kind(path : String) -> String raise {
  let kind = fs_value(() => stat_kind(node_stat(path)))
  if kind == "unsupported" {
    raise Failure::Failure("unsupported build resource kind: " + path)
  }
  kind
}
