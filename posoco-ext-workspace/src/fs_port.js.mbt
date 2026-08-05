// JsWorkspaceFs — js-target `WorkspaceFs` backed by node:fs via `#module`.
//
// This file is js-target-only (see moon.pkg `targets`). We bind each node:fs
// member with `#module("node:fs")` + `extern "js" fn ... = "<member>"`, and
// wrap mutating/stat ops in an inline-JS try/catch ffi that returns a typed
// Result so failures convert to WorkspaceFsError. Pattern follows
// moonbitlang/x/fs/fs_js.mbt exactly.
//
// node:fs is synchronous; bun provides a compatible node:fs layer, so no
// `require`/`import` is emitted — `#module` declares the module specifier and
// the compiler generates the import.

// ──────────────────────────────────────────────────────────────────────────
// FFI result/opaque types (inline-JS accessors mirror fs_js.mbt)
// ──────────────────────────────────────────────────────────────────────────

///|
#external
priv type FsStats

///|
/// `fs.lstatSync(path).isFile()` etc.
extern "js" fn FsStats::is_file(self : Self) -> Bool =
  #| (s) => s.isFile()

///|
extern "js" fn FsStats::is_directory(self : Self) -> Bool =
  #| (s) => s.isDirectory()

///|
extern "js" fn FsStats::is_symbolic_link(self : Self) -> Bool =
  #| (s) => s.isSymbolicLink()

///|
#external
priv type FsUnitResult

///|
extern "js" fn FsUnitResult::is_ok(self : Self) -> Bool =
  #| (res) => res.ok

///|
extern "js" fn FsUnitResult::error_message(self : Self) -> String =
  #| (res) => res.content

///|
#external
priv type FsStringResult

///|
extern "js" fn FsStringResult::is_ok(self : Self) -> Bool =
  #| (res) => res.ok

///|
extern "js" fn FsStringResult::content(self : Self) -> String =
  #| (res) => res.content

///|
extern "js" fn FsStringResult::error_message(self : Self) -> String =
  #| (res) => res.content

///|
#external
priv type FsStringArrayResult

///|
extern "js" fn FsStringArrayResult::is_ok(self : Self) -> Bool =
  #| (res) => res.ok

///|
extern "js" fn FsStringArrayResult::content(self : Self) -> Array[String] =
  #| (res) => res.content

///|
extern "js" fn FsStringArrayResult::error_message(self : Self) -> String =
  #| (res) => res.content

///|
#external
priv type FsStatsResult

///|
extern "js" fn FsStatsResult::is_ok(self : Self) -> Bool =
  #| (res) => res.ok

///|
extern "js" fn FsStatsResult::stats(self : Self) -> FsStats =
  #| (res) => res.content

///|
extern "js" fn FsStatsResult::error_message(self : Self) -> String =
  #| (res) => res.content

// ──────────────────────────────────────────────────────────────────────────
// #module bindings — one decl per node:fs member
// ──────────────────────────────────────────────────────────────────────────

///|
#module("node:fs")
extern "js" fn exists_sync(path : String) -> Bool = "existsSync"

///|
#module("node:fs")
extern "js" fn stat_sync(path : String) -> FsStats = "statSync"

///|
#module("node:fs")
extern "js" fn lstat_sync(path : String) -> FsStats = "lstatSync"

///|
/// node:fs `readFileSync`. The two-arg form (path, encoding) returns a String;
/// without an encoding it returns a Buffer. We pass the encoding in the
/// inline-JS wrapper below, so the `#module` binding takes the raw 2-arg form.
#module("node:fs")
extern "js" fn read_file_sync(path : String, encoding : String) -> String = "readFileSync"

///|
#module("node:fs")
extern "js" fn write_file_sync_str(path : String, content : String) -> Unit = "writeFileSync"

///|
#module("node:fs")
extern "js" fn unlink_sync(path : String) -> Unit = "unlinkSync"

///|
#module("node:fs")
extern "js" fn rename_sync(from : String, to_ : String) -> Unit = "renameSync"

///|
#module("node:fs")
extern "js" fn realpath_sync(path : String) -> String = "realpathSync"

///|
#module("node:fs")
extern "js" fn readdir_sync(path : String) -> Array[String] = "readdirSync"

///|
#module("node:fs")
extern "js" fn mkdir_sync(path : String, recursive : Bool) -> Unit = "mkdirSync"

///|
#module("node:fs")
extern "js" fn rm_sync(path : String, recursive : Bool) -> Unit = "rmSync"

// ──────────────────────────────────────────────────────────────────────────
// Inline-JS ffi wrappers — try/catch around #module-bound bare functions
// ──────────────────────────────────────────────────────────────────────────

///|
/// `readFileSync(path, "utf8")` so node returns a String, not a Buffer.
extern "js" fn read_file_ffi(
  read_file : (String, String) -> String,
  path : String,
) -> FsStringResult =
  #| function(readFile, path) {
  #|   try { return { ok: true, content: readFile(path, "utf8") }; }
  #|   catch (error) { return { ok: false, content: error.message }; }
  #| }

///|
/// Hand read_file_sync to read_file_ffi; the ffi supplies the "utf8" arg.
fn read_file_with_utf8(path : String) -> FsStringResult {
  read_file_ffi(read_file_sync, path)
}

///|
extern "js" fn write_file_ffi(
  write_file : (String, String) -> Unit,
  path : String,
  content : String,
) -> FsUnitResult =
  #| function(writeFile, path, content) {
  #|   try { writeFile(path, content); return { ok: true, content: "" }; }
  #|   catch (error) { return { ok: false, content: error.message }; }
  #| }

///|
extern "js" fn unlink_ffi(
  unlink : (String) -> Unit,
  path : String,
) -> FsUnitResult =
  #| function(unlink, path) {
  #|   try { unlink(path); return { ok: true, content: "" }; }
  #|   catch (error) { return { ok: false, content: error.message }; }
  #| }

///|
extern "js" fn rename_ffi(
  rename : (String, String) -> Unit,
  from : String,
  to_ : String,
) -> FsUnitResult =
  #| function(rename, from, to) {
  #|   try { rename(from, to); return { ok: true, content: "" }; }
  #|   catch (error) { return { ok: false, content: error.message }; }
  #| }

///|
extern "js" fn realpath_ffi(
  realpath : (String) -> String,
  path : String,
) -> FsStringResult =
  #| function(realpath, path) {
  #|   try { return { ok: true, content: realpath(path) }; }
  #|   catch (error) { return { ok: false, content: error.message }; }
  #| }

///|
extern "js" fn readdir_ffi(
  readdir : (String) -> Array[String],
  path : String,
) -> FsStringArrayResult =
  #| function(readdir, path) {
  #|   try { return { ok: true, content: readdir(path) }; }
  #|   catch (error) { return { ok: false, content: error.message }; }
  #| }

///|
extern "js" fn stat_ffi(
  stat : (String) -> FsStats,
  path : String,
) -> FsStatsResult =
  #| function(stat, path) {
  #|   try { return { ok: true, content: stat(path) }; }
  #|   catch (error) { return { ok: false, content: error.message }; }
  #| }

///|
extern "js" fn mkdir_ffi(
  mkdir : (String, Bool) -> Unit,
  path : String,
  recursive : Bool,
) -> FsUnitResult =
  #| function(mkdir, path, recursive) {
  #|   try { mkdir(path, { recursive }); return { ok: true, content: "" }; }
  #|   catch (error) { return { ok: false, content: error.message }; }
  #| }

///|
extern "js" fn rm_ffi(
  rm : (String, Bool) -> Unit,
  path : String,
  recursive : Bool,
) -> FsUnitResult =
  #| function(rm, path, recursive) {
  #|   try { rm(path, { recursive, force: false }); return { ok: true, content: "" }; }
  #|   catch (error) { return { ok: false, content: error.message }; }
  #| }

// ──────────────────────────────────────────────────────────────────────────
// JsWorkspaceFs
// ──────────────────────────────────────────────────────────────────────────

///|
/// js-target `WorkspaceFs` backed by node:fs via `#module`.
pub struct JsWorkspaceFs {}

///|
pub fn JsWorkspaceFs::new() -> JsWorkspaceFs {
  JsWorkspaceFs::{  }
}

///|
pub impl WorkspaceFs for JsWorkspaceFs with fn exists(_self, path) {
  // existsSync never throws; returns false on missing path.
  exists_sync(path)
}

///|
/// `follow_symlink` selects stat (follow) vs lstat (no follow). The returned
/// FsStats is then asked for its kind via the typed accessors — no string
/// reflection, unlike the old NativeWorkspaceFs implementation.
pub impl WorkspaceFs for JsWorkspaceFs with fn kind(
  _self,
  path,
  follow_symlink~,
) {
  let stat_fn = if follow_symlink { stat_sync } else { lstat_sync }
  let res = stat_ffi(stat_fn, path)
  if !res.is_ok() {
    raise fs_err("kind")
  }
  let s = res.stats()
  if s.is_file() {
    File
  } else if s.is_directory() {
    Dir
  } else if s.is_symbolic_link() {
    Symlink
  } else {
    Other
  }
}

///|
pub impl WorkspaceFs for JsWorkspaceFs with fn read_file(_self, path) {
  let res = read_file_with_utf8(path)
  if !res.is_ok() {
    raise fs_err("read_file")
  }
  res.content()
}

///|
pub impl WorkspaceFs for JsWorkspaceFs with fn write_file(_self, path, content) {
  let res = write_file_ffi(write_file_sync_str, path, content)
  if !res.is_ok() {
    raise fs_err("write_file")
  }
}

///|
/// Write a sibling temp file (pid+time+random suffix, mode 0o600) then rename
/// over the destination. A failed write removes the temp file; a failed
/// rename leaves the original destination intact.
extern "js" fn write_file_atomic_ffi(path : String, contents : String) -> Bool =
  #| (path, contents) => {
  #|   const fs = require("node:fs");
  #|   const suffix = `${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`;
  #|   const tmp = `${path}.tmp-${suffix}`;
  #|   try {
  #|     fs.writeFileSync(tmp, contents, { encoding: "utf8", mode: 0o600 });
  #|     fs.renameSync(tmp, path);
  #|     return true;
  #|   } catch {
  #|     try { fs.unlinkSync(tmp); } catch {}
  #|     return false;
  #|   }
  #| }

///|
pub impl WorkspaceFs for JsWorkspaceFs with fn write_file_atomic(
  _self,
  path,
  content,
) {
  if !write_file_atomic_ffi(path, content) {
    raise fs_err("write_file_atomic")
  }
}

///|
/// Files use unlinkSync; directories use rmSync(recursive). Distinguish via
/// lstatSync so removing a directory does not throw ENOENT-like errors.
pub impl WorkspaceFs for JsWorkspaceFs with fn remove(_self, path) {
  let stat_res = stat_ffi(lstat_sync, path)
  if stat_res.is_ok() && stat_res.stats().is_directory() {
    let res = rm_ffi(rm_sync, path, true)
    if !res.is_ok() {
      raise fs_err("remove")
    }
  } else {
    let res = unlink_ffi(unlink_sync, path)
    if !res.is_ok() {
      raise fs_err("remove")
    }
  }
}

///|
/// When `replace`, unlink the destination first (swallow ENOENT) so rename
/// does not error on an existing target.
pub impl WorkspaceFs for JsWorkspaceFs with fn rename(
  _self,
  from,
  to_,
  replace~,
) {
  if replace && exists_sync(to_) {
    let _ = unlink_ffi(unlink_sync, to_)
  }
  let res = rename_ffi(rename_sync, from, to_)
  if !res.is_ok() {
    raise fs_err("rename")
  }
}

///|
pub impl WorkspaceFs for JsWorkspaceFs with fn realpath(_self, path) {
  let res = realpath_ffi(realpath_sync, path)
  if !res.is_ok() {
    raise fs_err("realpath")
  }
  res.content()
}

///|
pub impl WorkspaceFs for JsWorkspaceFs with fn readdir(
  _self,
  path,
  include_hidden~,
) {
  let res = readdir_ffi(readdir_sync, path)
  if !res.is_ok() {
    raise fs_err("readdir")
  }
  let entries = res.content()
  if include_hidden {
    entries
  } else {
    let visible : Array[String] = []
    for entry in entries {
      if !entry.has_prefix(".") {
        visible.push(entry)
      }
    }
    visible
  }
}

///|
/// Recursive walk: depth-first, directories first. `max_concurrency` is a
/// native-only knob (puppetry passes 1); under js we walk synchronously and
/// invoke `callback(dir, entries)` once per directory. Symlinks are not
/// followed to avoid cycles.
pub impl WorkspaceFs for JsWorkspaceFs with fn walk(_self, root, callback) {
  walk_dir(root, callback) catch {
    WorkspaceFsError::WorkspaceFsError(_) as e => raise e
    _ => raise fs_err("walk")
  }
}

///|
/// `raise Error` because the async callback's effect type is the generic
/// `Error` on the js backend (the trait signature `-> Unit` carries no
/// `raise`, but js async calls are untyped-effect). The outer `walk` impl
/// wraps this so callers only see WorkspaceFsError.
async fn walk_dir(
  dir : String,
  callback : async (String, Array[String]) -> Unit,
) -> Unit raise Error {
  let res = readdir_ffi(readdir_sync, dir)
  if !res.is_ok() {
    raise fs_err("walk")
  }
  let entries = res.content()
  callback(dir, entries)
  for entry in entries {
    let child = if dir.has_suffix("/") {
      dir + entry
    } else {
      dir + "/" + entry
    }
    let stat_res = stat_ffi(lstat_sync, child)
    if stat_res.is_ok() && stat_res.stats().is_directory() {
      walk_dir(child, callback)
    }
  }
}

///|
pub impl WorkspaceFs for JsWorkspaceFs with fn mkdir(_self, path, recursive~) {
  let res = mkdir_ffi(mkdir_sync, path, recursive)
  if !res.is_ok() {
    raise fs_err("mkdir")
  }
}
