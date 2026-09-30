// js (bun/node) target: kind discovery through node:fs sync APIs. Throwing
// node calls cross the FFI as JSON
// string envelopes decoded on the MoonBit side.

///|
#module("node:fs")
extern "js" fn node_fs_exists_sync(path : String) -> Bool = "existsSync"

///|
/// Opaque node Stats-free readdir/read envelopes: node:fs members are bound
/// with `#module` and injected into the inline-JS envelopes as values
/// (pattern follows posoco-ext-workspace fs_port.js.mbt /
/// moonbitlang/x/fs/fs_js.mbt); throwing node calls cross the FFI as JSON
/// string envelopes decoded on the MoonBit side.
#module("node:fs")
extern "js" fn fs_readdir_sync(path : String) -> FixedArray[String] = "readdirSync"

///|
#module("node:fs")
extern "js" fn fs_read_text_sync(path : String, encoding : String) -> String = "readFileSync"

///|
extern "js" fn js_kind_readdir_envelope(
  readdir : (String) -> FixedArray[String],
  path : String,
) -> String =
  #| (readdir, path) => {
  #|   try {
  #|     const names = readdir(path)
  #|       .filter((n) => n.endsWith(".md"))
  #|       .sort();
  #|     return JSON.stringify({ ok: true, names });
  #|   } catch { return JSON.stringify({ ok: false }); }
  #| }

///|
extern "js" fn js_kind_read_envelope(
  read_text : (String, String) -> String,
  path : String,
) -> String =
  #| (readText, path) => {
  #|   try {
  #|     return JSON.stringify({ ok: true, data: readText(path, "utf8") });
  #|   } catch { return JSON.stringify({ ok: false }); }
  #| }

///|
priv struct KindJsList {
  ok : Bool
  names : Array[String]
}

///|
fn js_kind_list(path : String) -> KindJsList {
  let fallback : KindJsList = { ok: false, names: [], }
  let json : Json = @json.parse(js_kind_readdir_envelope(fs_readdir_sync, path)) catch {
    _ => return fallback
  }
  let fields = match json {
    Json::Object(fields) => fields
    _ => return fallback
  }
  let ok = match fields.get("ok") {
    Some(Json::True) => true
    _ => false
  }
  if !ok {
    return fallback
  }
  let names : Array[String] = []
  match fields.get("names") {
    Some(Json::Array(items)) =>
      for item in items {
        match item {
          Json::String(name) => names.push(name)
          _ => ()
        }
      }
    _ => ()
  }
  { ok: true, names, }
}

///|
fn js_kind_text(path : String) -> String? {
  let json : Json = @json.parse(js_kind_read_envelope(fs_read_text_sync, path)) catch {
    _ => return None
  }
  match json {
    Json::Object(fields) =>
      match fields.get("ok") {
        Some(Json::True) =>
          match fields.get("data") {
            Some(Json::String(data)) => Some(data)
            _ => None
          }
        _ => None
      }
    _ => None
  }
}

///|
priv struct JsKindFs {}

///|
impl KindFs for JsKindFs with fn list_kind_files(_self, dir : String) -> Array[
  String,
] {
  if !node_fs_exists_sync(dir) {
    return []
  }
  let listing = js_kind_list(dir)
  if !listing.ok {
    raise kind_io_failure("list", dir)
  }
  let out : Array[String] = []
  for name in listing.names {
    out.push(kind_dir(dir, name))
  }
  out
}

///|
impl KindFs for JsKindFs with fn read_text(_self, path : String) -> String {
  match js_kind_text(path) {
    Some(text) => text
    None => raise kind_io_failure("read", path)
  }
}

///|
/// js entry: load via node:fs. `extra` entries register between the
/// builtin table and the on-disk overlays (same-name overlays win).
pub async fn KindCatalog::load(
  home~ : String,
  cwd~ : String,
  extra? : Array[KindSpec] = [],
) -> KindCatalog {
  load_with_io(JsKindFs::{ }, home~, cwd~, extra~)
}
