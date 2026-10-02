///|
priv struct OpenAIVersionFileCache {
  directory : String?
  last_version : Ref[String?]
}

///|
fn openai_cache_join(directory : String, name : String) -> String {
  let mut end = directory.length()
  while end > 0 && (directory[end - 1] == '/' || directory[end - 1] == '\\') {
    end -= 1
  }
  directory[:end].to_owned() + "/" + name
}

///|
fn openai_default_cache_dir() -> String? {
  for key in ["XDG_CACHE_HOME", "LOCALAPPDATA"] {
    match @env.get_env_var(key) {
      Some(base) if !base.is_empty() =>
        return Some(openai_cache_join(base, "posoco-ext-openai"))
      _ => ()
    }
  }
  match @env.get_env_var("HOME") {
    Some(home) if !home.is_empty() =>
      Some(openai_cache_join(home, ".cache/posoco-ext-openai"))
    _ => None
  }
}

///|
impl CodexClientVersionCache for OpenAIVersionFileCache with fn read(self) {
  match self.directory {
    Some(directory) if !directory.is_empty() => {
      let text = openai_version_read_file(
        openai_cache_join(directory, "codex_client_version.json"),
      ) catch {
        _ =>
          return self.last_version.val.map(version => {
            Json::object(
              Map::from_array([("client_version", Json::string(version))]),
            ).stringify()
          })
      }
      Some(text)
    }
    _ =>
      self.last_version.val.map(version => {
        Json::object(
          Map::from_array([("client_version", Json::string(version))]),
        ).stringify()
      })
  }
}

///|
impl CodexClientVersionCache for OpenAIVersionFileCache with fn write(
  self,
  version,
) {
  self.last_version.val = Some(version)
  guard self.directory is Some(directory) && !directory.is_empty() else {
    return
  }
  let target = openai_cache_join(directory, "codex_client_version.json")
  guard @env.rand(16) is Some(bytes) else { return }
  let nonce = @uuid.from_bytes(bytes).to_string() catch { _ => return }
  let payload = Json::object(
      Map::from_array([("client_version", Json::string(version))]),
    ).stringify() +
    "\n"
  openai_version_write_atomic(directory, target, nonce, payload) catch {
    _ => ()
  }
}
