///|
// js backend: node:child_process via #module injection. Only a plain String crosses
// the FFI ("" = no rewrite), and the JS-side catch keeps spawn failures inside the
// never-fail contract.

///|
#external
priv type NodeSpawnOptions

///|
#external
priv type NodeProc

///|
#module("node:child_process")
extern "js" fn cp_spawn(
  file : String,
  args : FixedArray[String],
  options : NodeSpawnOptions,
) -> NodeProc = "spawn"

///|
extern "js" fn node_rtk_rewrite(
  spawn : (String, FixedArray[String], NodeSpawnOptions) -> NodeProc,
  rtk_path : String,
  cmd : String,
) -> @js_async.Promise[String] =
  #| async (spawn, rtk_path, cmd) => {
  #|   try {
  #|     const proc = spawn(rtk_path, ["rewrite", cmd], { stdio: ["ignore", "pipe", "pipe"] })
  #|     const drain = (stream) => stream
  #|       ? new Promise((resolve) => {
  #|           let text = ""
  #|           const finish = () => resolve(text)
  #|           stream.setEncoding("utf8")
  #|           stream.on("data", (chunk) => { text += chunk })
  #|           stream.on("end", finish)
  #|           stream.on("close", finish)
  #|           stream.on("error", finish)
  #|         })
  #|       : Promise.resolve("")
  #|     const [, stdout] = await Promise.all([
  #|       new Promise((resolve) => {
  #|         proc.on("close", (code) => resolve(code ?? -1))
  #|         proc.on("error", () => resolve(-1))
  #|       }),
  #|       drain(proc.stdout),
  #|     ])
  #|     return stdout.trim()
  #|   } catch (_) { return "" }
  #| }

///|
async fn rtk_rewrite(rtk_path : String, cmd : String) -> String? noraise {
  let text = node_rtk_rewrite(cp_spawn, rtk_path, cmd).wait() catch {
    _ => return None
  }
  if text == "" {
    None
  } else {
    Some(text)
  }
}

///|
priv struct JsRtkRewrite {}

///|
impl RTKRewrite for JsRtkRewrite with fn rewrite(
  _self : JsRtkRewrite,
  rtk_path : String,
  cmd : String,
) -> String? {
  rtk_rewrite(rtk_path, cmd)
}

///|
fn rtk_default_rewriter() -> &RTKRewrite {
  JsRtkRewrite::{ }
}
