///|
// Target-split file reading for mcp.json discovery.
//
// native reads through moonbitlang/async/fs; js reads through node:fs bound
// with `#module` (the compiler emits the static import — no per-call dynamic
// import needed), with the bound function injected into the inline
// `extern "js"` envelope.

///|
/// `NotUtf8` is only constructible by the native reader (node's utf-8
/// `readFileSync` replaces instead of failing), so suppress the js-target
/// unused-constructor diagnostic rather than drop the native distinction.
#warnings("-unused_constructor")
priv enum ReadFileOutcome {
  Missing
  Text(String)
  IoFailed
  NotUtf8
}

///|
#cfg(not(target="js"))
async fn read_file_text(path : String) -> ReadFileOutcome noraise {
  let exists = @fs.exists(path) catch { _ => return IoFailed }
  if !exists {
    return Missing
  }
  let data = @fs.read_file(path) catch { _ => return IoFailed }
  let text = data.text() catch { _ => return NotUtf8 }
  Text(text)
}

///|
/// node:fs member bound with `#module` and injected into the envelope below
/// as a value (pattern follows posoco-ext-workspace fs_port.js.mbt /
/// moonbitlang/x/fs/fs_js.mbt).
#cfg(target="js")
#module("node:fs")
extern "js" fn fs_read_text_sync(path : String, encoding : String) -> String = "readFileSync"

///|
#cfg(target="js")
extern "js" fn js_read_file_envelope(
  read_text : (String, String) -> String,
  path : String,
) -> String =
  #| (readFile, path) => {
  #|   try {
  #|     return JSON.stringify({ ok: true, value: readFile(path, 'utf-8') })
  #|   } catch (error) {
  #|     return JSON.stringify({
  #|       ok: false,
  #|       missing: error?.code === 'ENOENT',
  #|     })
  #|   }
  #| }

///|
#cfg(target="js")
fn read_file_text(path : String) -> ReadFileOutcome noraise {
  let envelope = js_read_file_envelope(fs_read_text_sync, path)
  let json = @json.parse(envelope) catch { _ => return IoFailed }
  match json {
    Json::Object(fields) =>
      match (fields.get("ok"), fields.get("missing"), fields.get("value")) {
        (Some(Json::True), _, Some(Json::String(value))) => Text(value)
        (Some(Json::False), Some(Json::True), _) => Missing
        _ => IoFailed
      }
    _ => IoFailed
  }
}
