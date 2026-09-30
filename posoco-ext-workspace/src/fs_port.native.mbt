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
/// Native/wasm `WorkspaceFs` backed by `@fs`.
pub struct NativeWorkspaceFs {}

///|
pub fn NativeWorkspaceFs::NativeWorkspaceFs() -> NativeWorkspaceFs {
  NativeWorkspaceFs::{ }
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
/// Names are candidates only: exclusive creation establishes ownership even
/// across processes and in the presence of stale files or symlinks.
let atomic_write_counter : Ref[Int] = { val: 0, }

///|
fn atomic_write_candidate(path : String) -> String {
  atomic_write_counter.val += 1
  "\{path}.tmp-\{atomic_write_counter.val}"
}

///|
/// Candidate naming and writing are narrow test seams; acquisition, cleanup,
/// and commit always use real file handles and filesystem operations.
async fn native_write_file_atomic(
  path : String,
  content : String,
  next_candidate? : (String) -> String = atomic_write_candidate,
  write? : async (@fs.File, String) -> Unit = async fn(file, text) {
    file.write(text)
  },
) -> Unit raise WorkspaceFsError {
  let owned : Ref[(@fs.File, String)?] = Ref(None)
  let committed = Ref(false)
  // Install cleanup before creation. Acquisition cannot be cancelled between
  // creating a file and recording which handle/path we own.
  defer (match owned.val {
    None => ()
    Some((file, tmp)) => {
      file.close()
      if !committed.val {
        // @fs.remove is nocancel, so task cancellation cannot skip removal.
        @fs.remove(tmp) catch {
          _ => raise fs_err("write_file_atomic: staging cleanup")
        }
      }
    }
  })
  @async.protect_from_cancel(() => {
    for _ in 0..<128 {
      let tmp = next_candidate(path)
      let file = @fs.open(
        tmp,
        mode=WriteOnly,
        create_mode=CreateNew,
        permission=0o600,
      ) catch {
        @os_error.OSError(_) as err if err.is_EEXIST() => continue
        _ => raise fs_err("write_file_atomic: staging create")
      }
      owned.val = Some((file, tmp))
      return
    }
    raise fs_err("write_file_atomic: staging name collisions")
  }) catch {
    WorkspaceFsError(_) as err => raise err
    _ => raise fs_err("write_file_atomic: staging create")
  }
  guard owned.val is Some((file, tmp)) else {
    raise fs_err("write_file_atomic: staging create")
  }
  write(file, content) catch {
    _ => raise fs_err("write_file_atomic: staging write")
  }
  file.close()
  // Honour cancellation before entering the atomic commit region. Once the
  // rename starts, cancellation cannot leave a successful replace ambiguous.
  @async.pause()
  @async.protect_from_cancel(() => {
    @fs.rename(tmp, path, replace=true) catch {
      _ => raise fs_err("write_file_atomic: replace")
    }
    committed.val = true
  }) catch {
    _ => raise fs_err("write_file_atomic: replace")
  }
}

///|
pub impl WorkspaceFs for NativeWorkspaceFs with fn write_file_atomic(
  _self,
  path,
  content,
) {
  native_write_file_atomic(path, content)
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
  @fs.mkdir(path, recursive~, allow_exist=true) catch {
    _ => raise fs_err("mkdir")
  }
}

///|
pub extend NativeWorkspaceFs with WorkspaceFs::{
  exists,
  kind,
  mkdir,
  read_file,
  readdir,
  realpath,
  remove,
  rename,
  walk,
  write_file,
  write_file_atomic,
}
