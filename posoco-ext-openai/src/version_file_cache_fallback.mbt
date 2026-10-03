///|
/// Backends without a filesystem (wasm/wasm-gc/llvm) degrade the version
/// cache to always-unavailable: reads yield nothing, writes are dropped, and
/// resolution falls back to the in-process last success or the built-in
/// constant. Native and node:fs implementations live in the backend files.

///|
priv suberror VersionCacheIo {
  Unavailable
}

///|
fn openai_version_read_file(_path : String) -> String raise VersionCacheIo {
  raise Unavailable
}

///|
fn openai_version_write_atomic(
  _directory : String,
  _target : String,
  _nonce : String,
  _payload : String,
) -> Unit raise VersionCacheIo {
  raise Unavailable
}
