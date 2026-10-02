///|
#module("node:fs")
extern "js" fn openai_version_js_read(
  path : String,
  encoding : String,
) -> String = "readFileSync"

///|
#module("node:fs")
extern "js" fn openai_version_js_mkdir(path : String, options : Json) -> Unit = "mkdirSync"

///|
#module("node:fs")
extern "js" fn openai_version_js_write(
  path : String,
  payload : String,
  options : Json,
) -> Unit = "writeFileSync"

///|
#module("node:fs")
extern "js" fn openai_version_js_rename(
  source : String,
  target : String,
) -> Unit = "renameSync"

///|
#module("node:fs")
extern "js" fn openai_version_js_remove(path : String) -> Unit = "unlinkSync"

///|
extern "js" fn openai_version_js_safe_read(
  read : (String, String) -> String,
  path : String,
) -> String =
  #| (read, path) => {
  #|   try { return read(path, 'utf8'); } catch { return ''; }
  #| }

///|
extern "js" fn openai_version_js_safe_write(
  mkdir : (String, Json) -> Unit,
  write : (String, String, Json) -> Unit,
  rename : (String, String) -> Unit,
  remove : (String) -> Unit,
  directory : String,
  target : String,
  temporary : String,
  payload : String,
) -> Bool =
  #| (mkdir, write, rename, remove, directory, target, temporary, payload) => {
  #|   let created = false;
  #|   try {
  #|     mkdir(directory, {recursive:true});
  #|     write(temporary, payload, {flag:'wx', mode:0o600});
  #|     created = true;
  #|     rename(temporary, target);
  #|     return true;
  #|   } catch {
  #|     if (created) { try { remove(temporary); } catch {} }
  #|     return false;
  #|   }
  #| }

///|
priv suberror VersionCacheIo {
  Unavailable
}

///|
fn openai_version_read_file(path : String) -> String raise VersionCacheIo {
  let text = openai_version_js_safe_read(openai_version_js_read, path)
  if text.is_empty() {
    raise Unavailable
  }
  text
}

///|
fn openai_version_write_atomic(
  directory : String,
  target : String,
  nonce : String,
  payload : String,
) -> Unit raise VersionCacheIo {
  if !openai_version_js_safe_write(
      openai_version_js_mkdir,
      openai_version_js_write,
      openai_version_js_rename,
      openai_version_js_remove,
      directory,
      target,
      target + "." + nonce + ".tmp",
      payload,
    ) {
    raise Unavailable
  }
}
