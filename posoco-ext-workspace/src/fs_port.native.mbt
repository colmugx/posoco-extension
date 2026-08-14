///|
// NativeWorkspaceFs — production implementation backed by moonbitlang/async/fs.
//
// `kind()` pattern-matches `@fs.FileKind` directly. The previous string
// reflection (`@debug.to_string` + `contains`) was fragile and violated the
// functional style; matching the typed enum is correct.

// ──────────────────────────────────────────────────────────────────────────
// NativeWorkspaceFs
// ──────────────────────────────────────────────────────────────────────────

///|
/// Native-only `WorkspaceFs` backed by `@fs`.
pub struct NativeWorkspaceFs {}

///|
pub fn NativeWorkspaceFs::new() -> NativeWorkspaceFs {
  NativeWorkspaceFs::{  }
}

///|
pub impl WorkspaceFs for NativeWorkspaceFs with fn exists(_self, path) {
  @fs.exists(path) catch {
    _ => raise fs_err("exists")
  }
}

///|
/// Match `@fs.FileKind` directly — no string reflection. `follow_symlink`
/// selects between stat (follow) and lstat (no follow) inside `@fs.kind`.
pub impl WorkspaceFs for NativeWorkspaceFs with fn kind(
  _self,
  path,
  follow_symlink~,
) {
  let fk = @fs.kind(path, follow_symlink~) catch { _ => raise fs_err("kind") }
  match fk {
    @fs.FileKind::Regular => File
    @fs.FileKind::Directory => Dir
    @fs.FileKind::SymLink => Symlink
    @fs.FileKind::Unknown => Other
    @fs.FileKind::Socket => Other
    @fs.FileKind::Pipe => Other
    @fs.FileKind::BlockDevice => Other
    @fs.FileKind::CharDevice => Other
  }
}

///|
pub impl WorkspaceFs for NativeWorkspaceFs with fn read_file(_self, path) {
  let data = @fs.read_file(path) catch { _ => raise fs_err("read_file") }
  data.text() catch {
    _ => raise fs_err("decode")
  }
}

///|
pub impl WorkspaceFs for NativeWorkspaceFs with fn write_file(
  _self,
  path,
  content,
) {
  // `create_mode=CreateOrTruncate` is required: without it, @fs.write_file
  // opens in TruncateExisting mode and fails on a missing file. We want
  // CreateOrTruncate so write creates the file when absent (0o644 permission).
  @fs.write_file(
    path,
    content,
    create_mode=@fs.CreateMode::CreateOrTruncate,
    permission=0o644,
  ) catch {
    _ => raise fs_err("write_file")
  }
}

///|
/// In-process counter giving each atomic-write temp file a unique sibling
/// name; credentials are low-concurrency, so a process-local suffix suffices.
let atomic_write_counter : Ref[Int] = { val: 0 }

///|
pub impl WorkspaceFs for NativeWorkspaceFs with fn write_file_atomic(
  _self,
  path,
  content,
) {
  atomic_write_counter.val += 1
  let tmp = "\{path}.tmp-\{atomic_write_counter.val}"
  // Owner-only create: the primary consumer is credential persistence.
  @fs.write_file(tmp, content, create_mode=OpenOrCreate, permission=0o600) catch {
    _ => raise fs_err("write_file_atomic")
  }
  @fs.rename(tmp, path, replace=true) catch {
    _ => {
      @fs.remove(tmp) catch {
        _ => ()
      }
      raise fs_err("write_file_atomic")
    }
  }
}

///|
pub impl WorkspaceFs for NativeWorkspaceFs with fn remove(_self, path) {
  @fs.remove(path) catch {
    _ => raise fs_err("remove")
  }
}

///|
pub impl WorkspaceFs for NativeWorkspaceFs with fn rename(
  _self,
  from,
  to_,
  replace~,
) {
  @fs.rename(from, to_, replace~) catch {
    _ => raise fs_err("rename")
  }
}

///|
pub impl WorkspaceFs for NativeWorkspaceFs with fn realpath(_self, path) {
  @fs.realpath(path) catch {
    _ => raise fs_err("realpath")
  }
}

///|
pub impl WorkspaceFs for NativeWorkspaceFs with fn readdir(
  _self,
  path,
  include_hidden~,
) {
  @fs.readdir(path, include_hidden~) catch {
    _ => raise fs_err("readdir")
  }
}

///|
pub impl WorkspaceFs for NativeWorkspaceFs with fn walk(_self, root, callback) {
  @fs.walk(root, callback, max_concurrency=1) catch {
    _ => raise fs_err("walk")
  }
}

///|
pub impl WorkspaceFs for NativeWorkspaceFs with fn mkdir(
  _self,
  path,
  recursive~,
) {
  @fs.mkdir(path, recursive~) catch {
    _ => raise fs_err("mkdir")
  }
}
