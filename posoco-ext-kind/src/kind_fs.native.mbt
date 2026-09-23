///|
priv struct NativeKindFs {}

///|
/// `@fs.exists` is false for a missing directory; readdir lists plain names,
/// sorted on request. Only `*.md` files participate in discovery. `@fs`
/// raises the universal `Error`, caught here and re-raised as RuntimeError.
impl KindFs for NativeKindFs with fn list_kind_files(_self, dir : String) -> Array[
  String,
] {
  let present = @fs.exists(dir) catch {
    _ => raise kind_io_failure("list", dir)
  }
  if !present {
    return []
  }
  let names = @fs.readdir(dir, sort=true) catch {
    _ => raise kind_io_failure("list", dir)
  }
  let out : Array[String] = []
  for name in names {
    if name.has_suffix(".md") {
      out.push(kind_dir(dir, name))
    }
  }
  out
}

///|
impl KindFs for NativeKindFs with fn read_text(_self, path : String) -> String {
  let data = @fs.read_file(path) catch {
    _ => raise kind_io_failure("read", path)
  }
  data.text() catch {
    _ => raise kind_io_failure("read", path)
  }
}

///|
/// Native entry: load via `@fs`.
pub async fn KindCatalog::load(home~ : String, cwd~ : String) -> KindCatalog {
  load_with_io(NativeKindFs::{ }, home~, cwd~)
}
