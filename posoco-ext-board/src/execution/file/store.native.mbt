///|
/// POSIX native identity journal in an existing private host directory. A lock
/// sentinel prevents concurrent writers; a stale lock is NEVER auto-removed.
/// After a crash an operator must first prove the old owner is dead. This is
/// conservative duplicate prevention, not a cross-system exactly-once protocol.
pub struct FileBoardExecutionStore {
  priv directory : String
  priv fail_at : JournalFailure?
  priv mut locked : Bool
  priv mut failed : Bool
}

///|
/// Ordinary Board snapshots remain unchanged. The caller owns this journal's
/// lifetime and must close it only after execution owner shutdown confirms join.
///
/// ```mbt check
/// test {
///   let _store = @file.FileBoardExecutionStore(directory="private-board-data")
/// }
/// ```
pub fn FileBoardExecutionStore::FileBoardExecutionStore(
  directory~ : String,
  fail_at? : JournalFailure,
) -> FileBoardExecutionStore {
  { directory, fail_at, locked: false, failed: false, }
}

///|
pub extend FileBoardExecutionStore with @execution.BoardExecutionStore::{
  load,
  persist,
}

///|
priv suberror JournalIo {
  Unsafe
}

///|
pub impl @execution.BoardExecutionStore for FileBoardExecutionStore with fn load(
  self,
) {
  if self.failed {
    return Err(@execution.StoreUnavailable)
  }
  @async.protect_from_cancel(() => {
    if @fs.kind(self.directory, follow_symlink=false) != Directory {
      raise Unsafe
    }
    if !self.locked {
      let lock = @fs.create(
        self.directory + "/" + @node_fs.execution_lock_name,
        allow_existing=false,
        permission=0o600,
      )
      self.locked = true
      defer lock.close()
      lock.write("board-execution-journal-v1\n")
      lock.sync()
      // Lock ownership protects against duplicate external execution.
      // Persist the new directory entry before admitting any work; syncing
      // only the lock inode cannot guarantee its name survives power loss.
      let directory = @fs.open(self.directory, mode=ReadOnly)
      defer directory.close()
      directory.sync()
    }
    let path = self.directory + "/" + @node_fs.execution_journal_name
    let names = @fs.readdir(
      self.directory,
      include_hidden=true,
      include_special=true,
    )
    if !names.contains(@node_fs.execution_journal_name) {
      return Ok([])
    }
    if @fs.kind(path, follow_symlink=false) != Regular {
      raise Unsafe
    }
    let decoded = @execution.decode_execution_journal(
      @fs.read_file(path).text(),
    )
    if decoded is Err(_) {
      self.failed = true
    }
    decoded
  }) catch {
    _ => {
      self.failed = true
      Err(@execution.StoreUnavailable)
    }
  }
}

///|
pub impl @execution.BoardExecutionStore for FileBoardExecutionStore with fn persist(
  self,
  records,
) {
  if !self.locked || self.failed {
    return Err(@execution.StoreUnavailable)
  }
  let data = match @execution.encode_execution_journal(records) {
    Ok(data) => data
    Err(error) => return Err(error)
  }
  let tmp = self.directory + "/" + @node_fs.execution_journal_name + ".tmp"
  let created = Ref(false)
  try {
    @async.protect_from_cancel(() => {
      let file = @fs.create(tmp, allow_existing=false, permission=0o600)
      created.val = true
      defer file.close()
      file.write(data)
      file.sync()
      if self.fail_at == Some(BeforeRename) {
        raise Unsafe
      }
      @fs.rename(
        tmp,
        self.directory + "/" + @node_fs.execution_journal_name,
        replace=true,
      )
      if self.fail_at == Some(AfterRename) {
        raise Unsafe
      }
      let directory = @fs.open(self.directory, mode=ReadOnly)
      defer directory.close()
      directory.sync()
    })
    Ok(())
  } catch {
    _ => {
      self.failed = true
      @async.protect_from_cancel(() => {
        if created.val {
          @fs.remove(tmp) catch {
            _ => ()
          }
        }
      })
      // Both visibility boundaries fail closed; never try another journal write.
      Err(@execution.StoreUnavailable)
    }
  }
}

///|
/// Only the host that owns this store may release its lock, after confirmed
/// execution shutdown. Never release a lock on behalf of another instance.
pub async fn FileBoardExecutionStore::close(
  self : FileBoardExecutionStore,
) -> Unit {
  @async.protect_from_cancel(() => {
    if self.locked {
      @fs.remove(self.directory + "/" + @node_fs.execution_lock_name)
      self.locked = false
    }
  })
}
