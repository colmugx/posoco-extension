///|
// Bun is a global under bun (posoco-ext-bash precedent) — do not use
// node:child_process. Only a plain String crosses the FFI ("" = no
// rewrite): an Option never crosses the js FFI (docs/questions.md
// 2026-08-19 stable boundaries). The JS-side catch keeps spawn failures
// inside the never-fail contract.

///|
extern "js" fn bun_rtk_rewrite(
  rtk_path : String,
  cmd : String,
) -> @js_async.Promise[String] =
  #| async (rtk_path, cmd) => {
  #|   try {
  #|     const proc = Bun.spawn({ cmd: [rtk_path, "rewrite", cmd], stdout: "pipe", stderr: "pipe" })
  #|     await proc.exited
  #|     const text = await new Response(proc.stdout).text()
  #|     return text.trim()
  #|   } catch (_) { return "" }
  #| }

///|
async fn rtk_rewrite(rtk_path : String, cmd : String) -> String? noraise {
  let text = bun_rtk_rewrite(rtk_path, cmd).wait() catch { _ => return None }
  if text == "" {
    None
  } else {
    Some(text)
  }
}
