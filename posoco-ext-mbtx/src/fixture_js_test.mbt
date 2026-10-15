///|
#module("node:fs")
extern "js" fn fixture_realpath(path : String) -> String = "realpathSync"

///|
#module("node:fs")
extern "js" fn fixture_write(path : String, text : String) -> Unit = "writeFileSync"

///|
#module("node:fs")
extern "js" fn fixture_tmp(prefix : String) -> String = "mkdtempSync"

///|
#module("node:os")
extern "js" fn fixture_tmp_root() -> String = "tmpdir"

///|
fn fixture_directory() -> String {
  fixture_realpath(fixture_tmp(fixture_tmp_root() + "/mbtx-sdk-test-"))
}

///|
#external
priv type FixtureOptions

///|
extern "js" fn fixture_options() -> FixtureOptions =
  #| () => ({recursive: true})

///|
#module("node:fs")
extern "js" fn fixture_make(path : String, options : FixtureOptions) -> Unit = "mkdirSync"

///|
#module("node:fs")
extern "js" fn fixture_rm(path : String, options : FixtureOptions) -> Unit = "rmSync"

///|
fn fixture_mkdir(path : String) -> Unit {
  fixture_make(path, fixture_options())
}

///|
fn fixture_remove(path : String) -> Unit {
  fixture_rm(path, fixture_options())
}

///|
extern "js" fn fixture_compile_js(
  path : String,
  signal : @js_async.AbortSignal,
) -> @js_async.Promise[String] =
  #| async (path, signal) => {
  #|   const {execFile} = await import('node:child_process');
  #|   return new Promise((resolve, reject) => {
  #|     execFile('moon', ['run', '--build-only', '--target', 'wasm', '--output-json', path], {signal, maxBuffer: 1048576}, (error, stdout, stderr) => {
  #|       if (error) reject(new Error(stdout + stderr + String(error))); else resolve(stdout);
  #|     });
  #|   });
  #| }

///|
async fn fixture_compile(path : String) -> String {
  @js_async.run_promise(signal => fixture_compile_js(path, signal))
}
