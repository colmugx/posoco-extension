///|
// Guest module loading and host identity configuration (JS target).
// Keep foreign-runtime implementation here; the public Pi/Posoco mapping lives
// in adaptor, event_observer, hook_adaptor, and runtime_adaptor.

///|
extern "js" fn js_host_load(host : JsPiHost, specifier : String) -> JsPromise =
  #| async (host, specifier) => {
  #|   const imported = await import(specifier);
  #|   const extension = imported.default ?? imported;
  #|   if (typeof extension !== "function") {
  #|     throw new TypeError(`Pi extension '${specifier}' does not export a default function`);
  #|   }
  #|   await extension(host.api);
  #|   return host.state.tools.length;
  #| }

///|
extern "js" fn js_host_set_cwd(host : JsPiHost, cwd : String) -> Unit =
  #| (host, cwd) => { host.state.cwd = cwd }

///|
extern "js" fn js_host_set_project_trusted(
  host : JsPiHost,
  trusted : Bool,
) -> Unit =
  #| (host, trusted) => { host.state.projectTrusted = trusted }

