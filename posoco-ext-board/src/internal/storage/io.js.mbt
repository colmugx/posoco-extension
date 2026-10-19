///|
#external
priv type FsApi

///|
#external
priv type FsResult

///|
#module("node:fs")
extern "js" fn open_sync(path : String, flags : String, mode : Int32) -> Int32 = "openSync"

///|
#module("node:fs")
extern "js" fn close_sync(fd : Int32) -> Unit = "closeSync"

///|
#module("node:fs")
extern "js" fn sync_fd(fd : Int32) -> Unit = "fsyncSync"

///|
#module("node:fs")
extern "js" fn write_fd(fd : Int32, data : String) -> Unit = "writeFileSync"

///|
#module("node:fs")
extern "js" fn read_sync(path : String) -> FsApi = "readFileSync"

///|
#module("node:fs")
extern "js" fn rename_sync(from : String, to : String) -> Unit = "renameSync"

///|
#module("node:fs")
extern "js" fn unlink_sync(path : String) -> Unit = "unlinkSync"

///|
#module("node:fs")
extern "js" fn lstat_sync(path : String) -> FsApi = "lstatSync"

///|
#module("node:fs")
extern "js" fn mkdir_sync(path : String, options : FsApi) -> Unit = "mkdirSync"

///|
#module("node:fs")
extern "js" fn truncate_sync(fd : Int32, size : Int32) -> Unit = "ftruncateSync"

///|
#module("node:path")
extern "js" fn dirname(path : String) -> String = "dirname"

///|
#module("node:crypto")
extern "js" fn uuid() -> String = "randomUUID"

///|
extern "js" fn api_new(
  open : (String, String, Int32) -> Int32,
  close : (Int32) -> Unit,
  sync : (Int32) -> Unit,
  write : (Int32, String) -> Unit,
  read : (String) -> FsApi,
  rename : (String, String) -> Unit,
  unlink : (String) -> Unit,
  stat : (String) -> FsApi,
  mkdir : (String, FsApi) -> Unit,
  parent : (String) -> String,
  random : () -> String,
  truncate : (Int32, Int32) -> Unit,
  journal_name : String,
  lock_name : String,
) -> FsApi =
  #| (open, close, sync, write, read, rename, unlink, stat, mkdir, parent, random, truncate, journalName, lockName) => {
  #|   const decode = bytes => new TextDecoder('utf-8', { fatal: true }).decode(bytes);
  #|   const regular = path => { if (!stat(path).isFile()) throw new Error('unsafe file'); };
  #|   const directory = path => { if (!stat(path).isDirectory()) throw new Error('unsafe directory'); };
  #|   const syncDir = path => { const fd = open(path, 'r', 0); try { sync(fd); } finally { close(fd); } };
  #|   const prepare = path => { mkdir(path, { recursive: true, mode: 0o700 }); directory(path); };
  #|   const readOptional = path => {
  #|     try {
  #|       regular(path);
  #|       const bytes = read(path);
  #|       if (!path.endsWith('/events.jsonl')) return { code: 0, text: decode(bytes) };
  #|       const end = bytes.lastIndexOf(10) + 1;
  #|       const prefix = decode(bytes.subarray(0, end));
  #|       let tail = ''; try { tail = decode(bytes.subarray(end)); } catch { /* only the torn tail may be discarded */ }
  #|       return { code: 0, text: prefix + tail };
  #|     }
  #|     catch (e) { return { code: e?.code === 'ENOENT' ? 1 : 2, text: '' }; }
  #|   };
  #|   return {
  #|     read: readOptional,
  #|     lock(path) {
  #|       try {
  #|         prepare(path);
  #|         const token = `board-execution-journal-v1:${random()}\n`;
  #|         const fd = open(`${path}/${lockName}`, 'wx', 0o600);
  #|         try { write(fd, token); sync(fd); } finally { close(fd); }
  #|         syncDir(path);
  #|         return { code: 0, text: token };
  #|       } catch { return { code: 2, text: '' }; }
  #|     },
  #|     unlock(path, token) {
  #|       try {
  #|         const current = readOptional(`${path}/${lockName}`);
  #|         if (current.code !== 0 || current.text !== token) throw new Error('wrong lock owner');
  #|         unlink(`${path}/${lockName}`);
  #|         syncDir(path);
  #|         return { code: 0, text: '' };
  #|       } catch { return { code: 2, text: '' }; }
  #|     },
  #|     replace(path, name, text, audit, stage) {
  #|       const tmp = `${path}/${name}.tmp`;
  #|       let visible = false, ownedTemp = false;
  #|       const injected = at => { if (stage === at) throw new Error('injected'); };
  #|       try {
  #|         prepare(path);
  #|         // Reject symlinks for every existing control-plane file. A stale
  #|         // Board temp may be overwritten, never promoted on load.
  #|         for (const file of [name, `${name}.tmp`, ...(name === 'board.json' ? ['events.jsonl'] : [])]) {
  #|           try { regular(`${path}/${file}`); } catch (e) { if (e?.code !== 'ENOENT') throw e; }
  #|         }
  #|         injected(1);
  #|         const fd = open(tmp, name === journalName ? 'wx' : 'w', 0o600);
  #|         ownedTemp = true;
  #|         try { write(fd, text); injected(2); sync(fd); } finally { close(fd); }
  #|         if (name === 'board.json') {
  #|           injected(3);
  #|           const parts = JSON.parse(audit);
  #|           const journal = open(`${path}/events.jsonl`, 'a', 0o600);
  #|           try {
  #|             truncate(journal, new TextEncoder().encode(parts.retained).length);
  #|             write(journal, parts.append);
  #|             injected(4); sync(journal);
  #|           } finally { close(journal); }
  #|         }
  #|         injected(5);
  #|         rename(tmp, `${path}/${name}`);
  #|         visible = true;
  #|         injected(6);
  #|         for (let p = path;;) { syncDir(p); const next = parent(p); if (next === p) break; p = next; }
  #|         return { code: 0, text: '' };
  #|       } catch {
  #|         // No unrelated stale execution temp is deleted. Cleanup failure
  #|         // remains a failed write; authoritative data is never replayed.
  #|         if (ownedTemp && !visible) { try { unlink(tmp); } catch { /* fail closed */ } }
  #|         return { code: visible ? 3 : 2, text: '' };
  #|       }
  #|     }
  #|   };
  #| }

///|
let api : FsApi = api_new(
  open_sync, close_sync, sync_fd, write_fd, read_sync, rename_sync, unlink_sync,
  lstat_sync, mkdir_sync, dirname, uuid, truncate_sync, execution_journal_name, execution_lock_name,
)

///|
extern "js" fn FsResult::code(self : FsResult) -> Int32 =
  #| r => r.code

///|
extern "js" fn FsResult::text(self : FsResult) -> String =
  #| r => r.text

///|
extern "js" fn read_ffi(api : FsApi, path : String) -> FsResult =
  #| (fs, path) => fs.read(path)

///|
extern "js" fn lock_ffi(api : FsApi, path : String) -> FsResult =
  #| (fs, path) => fs.lock(path)

///|
extern "js" fn unlock_ffi(
  api : FsApi,
  path : String,
  token : String,
) -> FsResult =
  #| (fs, path, token) => fs.unlock(path, token)

///|
extern "js" fn replace_ffi(
  api : FsApi,
  path : String,
  name : String,
  text : String,
  audit : String,
  stage : Int32,
) -> FsResult =
  #| (fs, path, name, text, audit, stage) => fs.replace(path, name, text, audit, stage)

///|
pub fn read(path : String) -> Result[String?, Unit] {
  let result = read_ffi(api, path)
  match result.code() {
    0 => Ok(Some(result.text()))
    1 => Ok(None)
    _ => Err(())
  }
}

///|
pub fn acquire(directory : String) -> Result[String, Unit] {
  let result = lock_ffi(api, directory)
  if result.code() == 0 {
    Ok(result.text())
  } else {
    Err(())
  }
}

///|
pub fn release(directory : String, token : String) -> Result[Unit, Unit] {
  if unlock_ffi(api, directory, token).code() == 0 {
    Ok(())
  } else {
    Err(())
  }
}

///|
/// 0=confirmed; 2=before visibility; 3=visible but durability uncertain.
pub fn replace(
  directory : String,
  name : String,
  text : String,
  audit : String,
  stage : Int32,
) -> Int32 {
  replace_ffi(api, directory, name, text, audit, stage).code()
}
