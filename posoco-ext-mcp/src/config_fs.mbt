///|
// Target-split file reading for mcp.json discovery.
//
// native reads through moonbitlang/async/fs; js reads through node:fs via
// a dynamically imported Promise bridged with @js_async (the moon js
// backend cannot reference node: members directly in valid ESM, so all
// Node interop lives in an inline `extern "js"` snippet like colmugx/mcp).

///|
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
#cfg(target="js")
extern "js" fn js_read_file_envelope(
  path : String,
) -> @js_async.Promise[String] =
  #| async (path) => {
  #|   const fs = await import('node:fs')
  #|   try {
  #|     return JSON.stringify({ ok: true, value: fs.readFileSync(path, 'utf-8') })
  #|   } catch (error) {
  #|     return JSON.stringify({
  #|       ok: false,
  #|       missing: error?.code === 'ENOENT',
  #|     })
  #|   }
  #| }

///|
#cfg(target="js")
async fn read_file_text(path : String) -> ReadFileOutcome noraise {
  let envelope = js_read_file_envelope(path).wait() catch {
    _ => return IoFailed
  }
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
