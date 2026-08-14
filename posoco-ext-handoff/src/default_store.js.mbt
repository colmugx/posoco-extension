///|
#external
priv type HandoffJsResult

///|
extern "js" fn HandoffJsResult::is_ok(self : Self) -> Bool =
  #| (result) => result.ok

///|
extern "js" fn HandoffJsResult::content(self : Self) -> String =
  #| (result) => result.content

///|
extern "js" fn handoff_store_exists_ffi(path : String) -> Bool =
  #| (path) => require("node:fs").existsSync(path)

///|
extern "js" fn handoff_store_read_ffi(path : String) -> HandoffJsResult =
  #| (path) => {
  #|   try {
  #|     return { ok: true, content: require("node:fs").readFileSync(path, "utf8") };
  #|   } catch (error) {
  #|     return { ok: false, content: String(error?.message ?? error) };
  #|   }
  #| }

///|
extern "js" fn handoff_store_mkdir_ffi(path : String) -> HandoffJsResult =
  #| (path) => {
  #|   try {
  #|     require("node:fs").mkdirSync(path, { recursive: true });
  #|     return { ok: true, content: "" };
  #|   } catch (error) {
  #|     return { ok: false, content: String(error?.message ?? error) };
  #|   }
  #| }

///|
extern "js" fn handoff_store_write_atomic_ffi(
  path : String,
  content : String,
) -> HandoffJsResult =
  #| (path, content) => {
  #|   const fs = require("node:fs");
  #|   const suffix = `${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`;
  #|   const tmp = `${path}.tmp-${suffix}`;
  #|   try {
  #|     fs.writeFileSync(tmp, content, { encoding: "utf8", mode: 0o644 });
  #|     fs.renameSync(tmp, path);
  #|     return { ok: true, content: "" };
  #|   } catch (error) {
  #|     try { fs.unlinkSync(tmp); } catch {}
  #|     return { ok: false, content: String(error?.message ?? error) };
  #|   }
  #| }

///|
pub impl HandoffStore for DefaultHandoffStore with fn exists(_self, path) {
  Ok(handoff_store_exists_ffi(path))
}

///|
pub impl HandoffStore for DefaultHandoffStore with fn read(_self, path) {
  let result = handoff_store_read_ffi(path)
  if result.is_ok() {
    Ok(result.content())
  } else {
    Err("handoff store read failed: " + result.content())
  }
}

///|
pub impl HandoffStore for DefaultHandoffStore with fn ensure_dir(_self, path) {
  let result = handoff_store_mkdir_ffi(path)
  if result.is_ok() {
    Ok(())
  } else {
    Err("handoff store mkdir failed: " + result.content())
  }
}

///|
pub impl HandoffStore for DefaultHandoffStore with fn write_atomic(
  _self,
  path,
  content,
) {
  let result = handoff_store_write_atomic_ffi(path, content)
  if result.is_ok() {
    Ok(())
  } else {
    Err("handoff store write failed: " + result.content())
  }
}
