///|
/// Explicit OAuth model refresh discovers the official stable client version.
/// Persistence and fallback belong to this extension, not its consumers.
/// Discovery never carries subscription credentials; one resolved version is
/// used for both the catalog request and its 401 renewal retry.

///|
/// Public, unauthenticated upstream release discovery endpoint. Deliberately
/// the GitHub API rather than the chat backend: the query must not touch the
/// OpenAI subscription identity.
fn codex_release_discovery_url() -> String {
  "https://api.github.com/repos/openai/codex/releases/latest"
}

///|
/// Upper bound on the release payload accepted for parsing. The existing
/// bounded-timeout transport already caps the wait; this cap refuses to parse
/// pathological bodies so the refresh cannot inflate on a hostile response.
/// Calibrated against the live endpoint (2026-10-02): the genuine
/// `/releases/latest` document measures 362,240 bytes because GitHub embeds
/// the release assets array, so the bound sits at 1 MiB — above the real
/// payload, far below unbounded.
let codex_release_max_body_chars : Int = 1048576

///|
/// A client version is exactly three non-empty all-digit components joined by
/// dots (`0.160.0`). Pre-release suffixes, build metadata, and empty or
/// non-numeric runs are refused.
fn is_valid_codex_client_version(version : String) -> Bool {
  let mut components = 0
  let mut start = 0
  let n = version.length()
  for i in 0..<=n {
    if i == n || version[i] == '.' {
      let width = i - start
      if width == 0 {
        return false
      }
      for j in start..<i {
        let c = version[j]
        if c < '0' || c > '9' {
          return false
        }
      }
      components += 1
      start = i + 1
    }
  }
  components == 3
}

///|
/// Strict official-release tag parser: only the stable rust release shape
/// `rust-v<major>.<minor>.<patch>` yields a version. Every other tag shape
/// (`v0.160.0`, `rust-v0.160.0-beta.1`, `rust-v0.160`, non-numeric runs) is
/// refused so a prerelease or a moved tag can never become the client
/// version.
fn parse_codex_release_tag_version(tag : String) -> String? {
  match tag.strip_prefix("rust-v") {
    Some(rest) => {
      let rest = rest.to_owned()
      if is_valid_codex_client_version(rest) {
        Some(rest)
      } else {
        None
      }
    }
    None => None
  }
}

///|
/// Parse the GitHub `/releases/latest` document. Only a non-draft,
/// non-prerelease release whose `tag_name` carries the official stable rust
/// tag yields a version; malformed bodies and every refused shape degrade to
/// `None` (the caller falls back — discovery failure is not an error).
fn parse_codex_release_version(body : String) -> String? {
  if body.length() > codex_release_max_body_chars {
    return None
  }
  let json = @json.parse(body) catch { _ => return None }
  let fields = match json {
    Json::Object(fields) => fields
    _ => return None
  }
  // Both flags must be explicitly false: a missing flag is an unknown shape,
  // and unknown shapes are refused rather than guessed.
  match fields.get("draft") {
    Some(Json::False) => ()
    _ => return None
  }
  match fields.get("prerelease") {
    Some(Json::False) => ()
    _ => return None
  }
  match fields.get("tag_name") {
    Some(Json::String(tag)) => parse_codex_release_tag_version(tag)
    _ => None
  }
}

///|
/// Parse the persisted version-cache payload. Only the current format — a
/// JSON object `{"client_version":"<major>.<minor>.<patch>"}` — is accepted.
/// Older shapes, corruption, and wrong types degrade to `None` and the
/// built-in constant stands in; there are deliberately no migration branches.
fn parse_codex_client_version_payload(text : String) -> String? {
  let json = @json.parse(text) catch { _ => return None }
  match json {
    Json::Object(fields) =>
      match fields.get("client_version") {
        Some(Json::String(version)) =>
          if is_valid_codex_client_version(version) {
            Some(version)
          } else {
            None
          }
        _ => None
      }
    _ => None
  }
}

///|
/// Private persistence seam shared by the file implementation and test fake.
/// Writes are best-effort and must preserve an existing record on failure.
priv trait CodexClientVersionCache {
  async fn read(Self) -> String? noraise
  async fn write(Self, String) -> Unit noraise
}

///|
/// Run one credential-free release discovery probe over the injected
/// transport. Every failure mode — transport error, non-2xx status, refused
/// body — degrades to `None`; the probe never raises into the refresh.
async fn fetch_codex_release_version_with_transport(
  transport : &OpenAIModelsHttpTransport,
) -> String? noraise {
  // Credential-free by contract: no Authorization, no chatgpt-account-id, no
  // GitHub token — the discovery probe cannot leak the subscription identity.
  let headers : Map[String, String] = Map::from_array([
    ("Accept", "application/vnd.github+json"),
    ("User-Agent", identity_user_agent_now()),
  ])
  let response = transport.get(codex_release_discovery_url(), headers) catch {
    _ => return None
  }
  if response.status < 200 || response.status >= 300 {
    return None
  }
  parse_codex_release_version(response.body)
}

///|
/// Resolve the Codex `client_version` for one explicit model refresh. See the
/// module header for the selection order. The cache is only written after a
/// valid online discovery (never cleared on failure), the write is
/// best-effort, and the returned value is fixed for the whole refresh.
async fn resolve_codex_client_version_with_transport(
  transport : &OpenAIModelsHttpTransport,
  version_cache : &CodexClientVersionCache?,
) -> String noraise {
  match fetch_codex_release_version_with_transport(transport) {
    Some(version) => {
      // Persist before the catalog request runs; the write is best-effort
      // and must never block using the freshly discovered version.
      match version_cache {
        Some(cache) => cache.write(version)
        None => ()
      }
      return version
    }
    None => ()
  }
  let cached = match version_cache {
    Some(cache) => cache.read()
    None => None
  }
  match cached {
    Some(text) =>
      match parse_codex_client_version_payload(text) {
        Some(version) => return version
        None => ()
      }
    None => ()
  }
  openai_codex_models_client_version()
}
