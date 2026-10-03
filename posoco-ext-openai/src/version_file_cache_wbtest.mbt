///|
/// White-box tests for the extension-owned version file cache. These run the
/// real backend against isolated host temp directories; the node:fs twin in
/// version_file_cache_js_wbtest.mbt mirrors the same scenarios for js.
/// Every fixture directory is removed again on success and on failure.

///|
/// Fresh isolated cache directory for one scenario.
async fn version_cache_fixture_dir() -> String {
  @fs.tmpdir(prefix="posoco-ext-openai-version-cache-")
}

///|
/// Remove the whole fixture tree; cleanup failures never shadow the
/// scenario's own result.
async fn version_cache_fixture_cleanup(directory : String) -> Unit {
  @fs.rmdir(directory, recursive=true) catch {
    _ => ()
  }
}

///|
async fn version_cache_fixture_write_file(
  directory : String,
  name : String,
  payload : String,
) -> Unit {
  @fs.write_file(openai_cache_join(directory, name), payload)
}

///|
async fn version_cache_fixture_remove_file(
  directory : String,
  name : String,
) -> Unit {
  @fs.remove(openai_cache_join(directory, name))
}

///|
/// Host payload of a cache record; `None` when the file is absent.
async fn version_cache_fixture_read_file(
  directory : String,
  name : String,
) -> String? {
  let text = @fs.read_file(openai_cache_join(directory, name)).text() catch {
    _ => ""
  }
  if text.is_empty() {
    None
  } else {
    Some(text)
  }
}

///|
async fn version_cache_fixture_list(directory : String) -> Array[String] {
  @fs.readdir(directory)
}

///|
fn version_cache_fixture_cache(directory : String) -> &CodexClientVersionCache {
  let cache : OpenAIVersionFileCache = OpenAIVersionFileCache::{
    directory: Some(directory),
    last_version: Ref(None),
  }
  cache
}

///|
/// Run one scenario against a fresh fixture directory and remove the tree
/// afterwards — on success, assertion failure, or error alike.
async fn version_cache_with_fixture(scenario : async (String) -> Unit) -> Unit {
  let directory = version_cache_fixture_dir()
  defer version_cache_fixture_cleanup(directory)
  scenario(directory)
}

///|
async test "version cache write persists a real file and reads it back" {
  version_cache_with_fixture(directory => {
    let cache = version_cache_fixture_cache(directory)
    cache.write("0.161.0")
    let stored = version_cache_fixture_read_file(
      directory, "codex_client_version.json",
    ).unwrap_or("")
    assert_eq(parse_codex_client_version_payload(stored), Some("0.161.0"))
    // The atomic write leaves only the record behind, never a .tmp file.
    assert_eq(version_cache_fixture_list(directory), [
      "codex_client_version.json",
    ])
    let reread = cache.read().unwrap_or("")
    assert_eq(parse_codex_client_version_payload(reread), Some("0.161.0"))
  })
}

///|
async test "an empty cache directory reads as absent" {
  version_cache_with_fixture(directory => {
    assert_true(version_cache_fixture_cache(directory).read() is None)
  })
}

///|
async test "rewriting the record replaces it without temporary leftovers" {
  version_cache_with_fixture(directory => {
    let cache = version_cache_fixture_cache(directory)
    cache.write("0.161.0")
    cache.write("0.162.0")
    let rewritten = cache.read().unwrap_or("")
    assert_eq(parse_codex_client_version_payload(rewritten), Some("0.162.0"))
    assert_eq(version_cache_fixture_list(directory), [
      "codex_client_version.json",
    ])
  })
}

///|
async test "a vanished record still serves the last successful write" {
  version_cache_with_fixture(directory => {
    let cache = version_cache_fixture_cache(directory)
    cache.write("0.161.0")
    version_cache_fixture_remove_file(directory, "codex_client_version.json")
    // The host file is gone; the in-process last success stands in.
    let from_memory = cache.read().unwrap_or("")
    assert_eq(parse_codex_client_version_payload(from_memory), Some("0.161.0"))
  })
}

///|
async test "a blocked cache directory swallows the write failure" {
  version_cache_with_fixture(directory => {
    // A regular file occupies the cache "directory" path, so the recursive
    // mkdir behind every write must fail; the failure stays silent.
    version_cache_fixture_write_file(directory, "not-a-directory", "occupied")
    let blocked = openai_cache_join(directory, "not-a-directory")
    let cache : &CodexClientVersionCache = OpenAIVersionFileCache::{
      directory: Some(blocked),
      last_version: Ref(None),
    }
    cache.write("0.161.0")
    // Nothing was created under the occupied path: no host record, no
    // temporary leftovers. The failed write stays silent and the refresh
    // keeps the version only in memory.
    assert_eq(version_cache_fixture_list(directory), ["not-a-directory"])
    let from_memory = cache.read().unwrap_or("")
    assert_eq(parse_codex_client_version_payload(from_memory), Some("0.161.0"))
  })
}

///|
async test "a colliding temporary filename fails the write and preserves the record" {
  version_cache_with_fixture(directory => {
    let target = openai_cache_join(directory, "codex_client_version.json")
    let existing = "{\"client_version\":\"0.158.0\"}\n"
    version_cache_fixture_write_file(
      directory, "codex_client_version.json", existing,
    )
    // Occupy the exact nonce temporary filename so the CreateNew behind the
    // atomic write must fail.
    version_cache_fixture_write_file(
      directory, "codex_client_version.json.collide.tmp", "fixture",
    )
    let failed = try
      openai_version_write_atomic(
        directory, target, "collide", "{\"client_version\":\"0.160.0\"}\n",
      )
    catch {
      _ => true
    } noraise {
      _ => false
    }
    assert_true(failed)
    // The old record's bytes are unchanged, and the colliding fixture is
    // still there: cleanup only ever removes a temporary this call created.
    assert_eq(
      version_cache_fixture_read_file(directory, "codex_client_version.json"),
      Some(existing),
    )
    assert_eq(
      version_cache_fixture_read_file(
        directory, "codex_client_version.json.collide.tmp",
      ),
      Some("fixture"),
    )
    assert_eq(version_cache_fixture_list(directory).length(), 2)
  })
}

///|
async test "a corrupt real record falls back to the built-in version at the resolver" {
  version_cache_with_fixture(directory => {
    version_cache_fixture_write_file(
      directory, "codex_client_version.json", "{not json",
    )
    let cache = version_cache_fixture_cache(directory)
    // The corrupt bytes are still served verbatim; only parsing refuses
    // them, so the resolver degrades to the built-in constant.
    assert_eq(cache.read(), Some("{not json"))
    let offline : UnreachableModelsTransport = UnreachableModelsTransport::{ }
    let transport : &OpenAIModelsHttpTransport = offline
    assert_eq(
      resolve_codex_client_version_with_transport(transport, Some(cache)),
      openai_codex_models_client_version(),
    )
  })
}
