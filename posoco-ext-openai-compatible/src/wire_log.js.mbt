///|
/// wire_log.js.mbt — JS (bun) wire log: raw SSE payload capture for
/// diagnosing provider streams without disturbing the TUI.
///
/// Activated by the `POSOCO_WIRE_LOG` env var holding the target file path;
/// when unset or empty, every function here is a no-op. The file receives
/// one verbatim SSE data payload per line — full provider traffic, so keep
/// it for debugging only (it may contain streamed content and provider
/// error payloads).

///|
extern "js" fn js_wire_log_path() -> String =
  #| () => {
  #|   try { return process.env.POSOCO_WIRE_LOG || ''; } catch { return ''; }
  #| }

///|
extern "js" fn js_append_line(path : String, line : String) -> Unit =
  #| (path, line) => {
  #|   try { require('node:fs').appendFileSync(path, line + '\n'); } catch {}
  #| }

///|
/// The configured wire-log path, or None when disabled.
fn wire_log_path() -> String? {
  match js_wire_log_path() {
    "" => None
    path => Some(path)
  }
}

///|
/// Append one line to the wire log. IO failures are swallowed inside the
/// FFI: logging must never break a turn.
fn wire_log_append(path : String, line : String) -> Unit {
  js_append_line(path, line)
}
