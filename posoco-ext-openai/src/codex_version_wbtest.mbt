///|
/// White-box tests for Codex client-version discovery and persistence.
/// Everything runs on injected fakes (no sockets): the probe transport below
/// answers scripted responses. Resolver-level tests script the private
/// in-memory cache seam; provider-level tests run the real file cache through
/// an isolated `cache_dir` fixture. Native-only, matching the package's other
/// transport tests.

///|
/// Build a GitHub `/releases/latest`-shaped body with a pinned tag and flags.
fn codex_release_body(
  tag : String,
  draft? : Bool = false,
  prerelease? : Bool = false,
) -> String {
  "{\"url\":\"https://api.github.com/repos/openai/codex/releases/1\"," +
  "\"tag_name\":\"" +
  tag +
  "\",\"name\":\"release\"," +
  "\"draft\":" +
  (if draft { "true" } else { "false" }) +
  ",\"prerelease\":" +
  (if prerelease { "true" } else { "false" }) +
  ",\"body\":\"release notes\"}"
}

///|
/// Probe transport that records every request (URL + headers) into shared
/// logs so tests can pin discovery → persist → catalog-request ordering and
/// assert the discovery probe carries no credentials.
struct CodexVersionProbeTransport {
  log : Array[String]
  header_log : Array[Map[String, String]]
  responses : Array[OpenAIModelsHttpResponse]
  mut calls : Int
}

///|
fn CodexVersionProbeTransport::CodexVersionProbeTransport(
  log : Array[String],
  responses : Array[OpenAIModelsHttpResponse],
) -> CodexVersionProbeTransport {
  { log, header_log: [], responses, calls: 0, }
}

///|
pub impl OpenAIModelsHttpTransport for CodexVersionProbeTransport with fn get(
  self : CodexVersionProbeTransport,
  url : String,
  headers : Map[String, String],
) -> OpenAIModelsHttpResponse {
  self.log.push("get " + url)
  self.header_log.push(headers)
  let index = self.calls
  self.calls = self.calls + 1
  self.responses[index]
}

///|
pub extend CodexVersionProbeTransport with OpenAIModelsHttpTransport::{get}

///|
/// Transport whose every request fails; stands in for an offline network.
struct UnreachableModelsTransport {}

///|
pub impl OpenAIModelsHttpTransport for UnreachableModelsTransport with fn get(
  _self : UnreachableModelsTransport,
  _url : String,
  _headers : Map[String, String],
) -> OpenAIModelsHttpResponse raise @posoco.ModelError {
  raise @posoco.ModelError::Transport("discovery transport unreachable")
}

///|
pub extend UnreachableModelsTransport with OpenAIModelsHttpTransport::{get}

///|
/// In-memory stand-in for the private persistence seam: resolver-level tests
/// script the raw payload it serves and observe the writes it records.
struct RecordingVersionCache {
  log : Array[String]
  raw : String?
}

///|
fn RecordingVersionCache::RecordingVersionCache(
  log : Array[String],
  raw? : String? = None,
) -> RecordingVersionCache {
  { log, raw, }
}

///|
impl CodexClientVersionCache for RecordingVersionCache with fn read(
  self : RecordingVersionCache,
) -> String? {
  self.raw
}

///|
impl CodexClientVersionCache for RecordingVersionCache with fn write(
  self : RecordingVersionCache,
  version : String,
) -> Unit {
  self.log.push("write " + version)
}

///|
/// Configured OAuth source shaped like the production Codex credential.
fn codex_version_refresh_source() -> @llm.ProviderConfigSource {
  let settings = Json::object(
    Map::from_array([("model", Json::string("gpt-codex"))]),
  )
  let credential = @oauth.Credential::Credential(
    access_token=codex_test_access_token(),
    refresh_token="refresh",
    expires_at=0,
    metadata=Map([("account_id", "acct-123")]),
  )
  @llm.ProviderConfigSource::ProviderConfigSource(
    settings=Some(settings),
    provider_credential=Some(@oauth.ProviderCredential::OAuth(credential)),
  )
}

// ------------------------------------------------------------- tag parsing

///|
test "official stable rust release tag parses to the client version" {
  assert_eq(
    parse_codex_release_version(codex_release_body("rust-v0.160.0")),
    Some("0.160.0"),
  )
}

///|
test "draft, prerelease, and non-official tags are refused" {
  let refused : Array[String?] = [
    // A prerelease or draft must never become the client version.
    parse_codex_release_version(
      codex_release_body("rust-v0.161.0", prerelease=true),
    ),
    parse_codex_release_version(codex_release_body("rust-v0.161.0", draft=true)),
    // Wrong tag shapes: missing rust-v prefix, truncated, pre-release
    // suffix, non-numeric run, extra component.
    parse_codex_release_version(codex_release_body("v0.160.0")),
    parse_codex_release_version(codex_release_body("rust-v0.160")),
    parse_codex_release_version(codex_release_body("rust-v0.160.0-beta.1")),
    parse_codex_release_version(codex_release_body("rust-vlatest")),
    parse_codex_release_version(codex_release_body("rust-v0.160.0.1")),
    // Malformed payloads.
    parse_codex_release_version("{\"tag_name\":\"rust-v0.160.0\""),
    parse_codex_release_version("[\"rust-v0.160.0\"]"),
    parse_codex_release_version("{\"tag_name\":123}"),
    parse_codex_release_version("{}"),
  ]
  for value in refused {
    assert_true(value is None)
  }
}

///|
test "oversized release payloads are refused before parsing" {
  // One char past the bound, so the parser refuses on size, not shape.
  let buf = StringBuilder()
  for _i in 0..<(codex_release_max_body_chars + 1) {
    buf.write_char('x')
  }
  let body = "{\"pad\":\"" +
    buf.to_string() +
    "\",\"tag_name\":\"rust-v0.160.0\"," +
    "\"draft\":false,\"prerelease\":false}"
  assert_true(parse_codex_release_version(body) is None)
}

///|
test "client-version shape validation is exactly three numeric components" {
  assert_true(is_valid_codex_client_version("0.160.0"))
  assert_true(is_valid_codex_client_version("10.20.30"))
  let invalid : Array[String] = [
    "", "0", "0.", ".0.0", "0.160", "0.160.0.1", "0.160.x", "v0.160.0", "0.-1.0",
    "0.160.0-beta",
  ]
  for value in invalid {
    assert_true(!is_valid_codex_client_version(value))
  }
}

// ------------------------------------------------------- discovery + cache

///|
async test "online discovery saves the version before the catalog request" {
  let log : Array[String] = []
  let transport_impl = CodexVersionProbeTransport::CodexVersionProbeTransport(
    log,
    [
      // 1: release discovery; 2: models; 3: best-effort usage probe.
      OpenAIModelsHttpResponse::{
        status: 200,
        body: codex_release_body("rust-v0.160.0"),
      },
      OpenAIModelsHttpResponse::{
        status: 200,
        body: load_refresh_models_body(),
      },
      OpenAIModelsHttpResponse::{
        status: 200,
        body: load_refresh_usage_body(),
      },
    ],
  )
  let transport : &OpenAIModelsHttpTransport = transport_impl
  version_cache_with_fixture(directory => {
    let provider = OpenAIProvider(
      transport=Some(transport),
      cache_dir=Some(directory),
    )
    match provider.refresh(codex_version_refresh_source()) {
      @llm.ProviderBuildResult::Ready(_) => ()
      @llm.ProviderBuildResult::Unconfigured =>
        fail("OAuth source was configured")
    }
    // Ordering: discovery GET, then the catalog request — which already
    // carries the freshly discovered version, so the persist never waited
    // for it.
    assert_eq(log, [
      "get " + codex_release_discovery_url(),
      "get https://chatgpt.com/backend-api/codex/models?client_version=0.160.0",
      "get https://chatgpt.com/backend-api/wham/usage",
    ])
    // The discovered version reached the isolated cache as a real file in
    // the current payload format.
    let persisted = version_cache_fixture_read_file(
      directory, "codex_client_version.json",
    )
    assert_eq(
      persisted.map(parse_codex_client_version_payload),
      Some(Some("0.160.0")),
    )
  })
}

///|
async test "discovery probe sends no OAuth token, account id, or GitHub token" {
  let transport_impl = CodexVersionProbeTransport::CodexVersionProbeTransport(
    [],
    [
      OpenAIModelsHttpResponse::{
        status: 200,
        body: codex_release_body("rust-v0.160.0"),
      },
      OpenAIModelsHttpResponse::{
        status: 200,
        body: load_refresh_models_body(),
      },
      OpenAIModelsHttpResponse::{
        status: 200,
        body: load_refresh_usage_body(),
      },
    ],
  )
  let transport : &OpenAIModelsHttpTransport = transport_impl
  let log : Array[String] = []
  let cache : &CodexClientVersionCache = RecordingVersionCache::RecordingVersionCache(
    log,
  )
  assert_eq(
    resolve_codex_client_version_with_transport(transport, Some(cache)),
    "0.160.0",
  )
  let headers = transport_impl.header_log[0]
  assert_true(headers.get("Authorization") is None)
  assert_true(headers.get("chatgpt-account-id") is None)
  // Only the credential-free acceptance and posoco identity headers ride the
  // discovery request.
  assert_eq(headers.get("Accept"), Some("application/vnd.github+json"))
  assert_true(headers.get("User-Agent") is Some(_))
}

///|
async test "discovery failure falls back to the persisted cache version" {
  let log : Array[String] = []
  let transport_impl = CodexVersionProbeTransport::CodexVersionProbeTransport(
    log,
    [
      // Discovery answers 500; the catalog request must still run with the
      // last cached success.
      OpenAIModelsHttpResponse::{ status: 500, body: "{\"message\":\"boom\"}", },
      OpenAIModelsHttpResponse::{
        status: 200,
        body: load_refresh_models_body(),
      },
      OpenAIModelsHttpResponse::{
        status: 200,
        body: load_refresh_usage_body(),
      },
    ],
  )
  let transport : &OpenAIModelsHttpTransport = transport_impl
  version_cache_with_fixture(directory => {
    // Seed the isolated cache with the last persisted success, shaped like
    // the host's record on disk.
    version_cache_fixture_write_file(
      directory, "codex_client_version.json", "{\"client_version\":\"0.158.0\"}\n",
    )
    let provider = OpenAIProvider(
      transport=Some(transport),
      cache_dir=Some(directory),
    )
    match provider.refresh(codex_version_refresh_source()) {
      @llm.ProviderBuildResult::Ready(_) => ()
      @llm.ProviderBuildResult::Unconfigured =>
        fail("OAuth source was configured")
    }
    // No discovery success means no cache write: the record still holds the
    // seeded version, and the catalog request used it.
    let persisted = version_cache_fixture_read_file(
      directory, "codex_client_version.json",
    )
    assert_eq(
      persisted.map(parse_codex_client_version_payload),
      Some(Some("0.158.0")),
    )
    assert_eq(
      transport_impl.log[1],
      "get https://chatgpt.com/backend-api/codex/models?client_version=0.158.0",
    )
  })
}

///|
async test "an unreachable discovery transport degrades to the cached version" {
  let transport_impl : UnreachableModelsTransport = UnreachableModelsTransport::{
  }
  let transport : &OpenAIModelsHttpTransport = transport_impl
  let log : Array[String] = []
  let cache : &CodexClientVersionCache = RecordingVersionCache::RecordingVersionCache(
    log,
    raw=Some("{\"client_version\":\"0.157.0\"}"),
  )
  assert_eq(
    resolve_codex_client_version_with_transport(transport, Some(cache)),
    "0.157.0",
  )
  assert_eq(log, [])
}

///|
async test "missing or invalid cache falls back to the built-in constant" {
  // Discovery down, no cache file: the built-in version stands in.
  let transport_impl : UnreachableModelsTransport = UnreachableModelsTransport::{
  }
  let transport : &OpenAIModelsHttpTransport = transport_impl
  let log : Array[String] = []
  let cache : &CodexClientVersionCache = RecordingVersionCache::RecordingVersionCache(
    log,
  )
  assert_eq(
    resolve_codex_client_version_with_transport(transport, Some(cache)),
    openai_codex_models_client_version(),
  )
  // Corrupt payloads — not JSON, wrong shape, wrong type, malformed version —
  // are ignored, never migrated.
  let corrupt : Array[String] = [
    "{not json", "[]", "{\"version\":\"0.99.0\"}", "{\"client_version\":42}", "{\"client_version\":\"0.160.0-beta\"}",
  ]
  for raw in corrupt {
    let fallback_cache : &CodexClientVersionCache = RecordingVersionCache::RecordingVersionCache(
      log,
      raw=Some(raw),
    )
    assert_eq(
      resolve_codex_client_version_with_transport(
        transport,
        Some(fallback_cache),
      ),
      openai_codex_models_client_version(),
    )
  }
}

///|
async test "a refused discovery keeps the built-in version without persisting" {
  let log : Array[String] = []
  let transport_impl = CodexVersionProbeTransport::CodexVersionProbeTransport(
    log,
    [
      // 1: discovery refused; 2: models; 3: best-effort usage probe.
      OpenAIModelsHttpResponse::{ status: 500, body: "{\"message\":\"boom\"}", },
      OpenAIModelsHttpResponse::{
        status: 200,
        body: load_refresh_models_body(),
      },
      OpenAIModelsHttpResponse::{
        status: 200,
        body: load_refresh_usage_body(),
      },
    ],
  )
  let transport : &OpenAIModelsHttpTransport = transport_impl
  version_cache_with_fixture(directory => {
    let provider = OpenAIProvider(
      transport=Some(transport),
      cache_dir=Some(directory),
    )
    match provider.refresh(codex_version_refresh_source()) {
      @llm.ProviderBuildResult::Ready(_) => ()
      @llm.ProviderBuildResult::Unconfigured =>
        fail("OAuth source was configured")
    }
    // No discovery success: the built-in version stands in and nothing is
    // persisted into the isolated cache.
    assert_eq(transport_impl.calls, 3)
    assert_eq(transport_impl.log[0], "get " + codex_release_discovery_url())
    assert_eq(
      transport_impl.log[1],
      "get https://chatgpt.com/backend-api/codex/models?client_version=0.159.0",
    )
    assert_true(
      version_cache_fixture_read_file(directory, "codex_client_version.json")
      is None,
    )
  })
}

///|
async test "model request failure keeps the original error and the saved version" {
  let log : Array[String] = []
  let transport_impl = CodexVersionProbeTransport::CodexVersionProbeTransport(
    log,
    [
      OpenAIModelsHttpResponse::{
        status: 200,
        body: codex_release_body("rust-v0.160.0"),
      },
      OpenAIModelsHttpResponse::{ status: 500, body: "{\"error\":\"down\"}", },
    ],
  )
  let transport : &OpenAIModelsHttpTransport = transport_impl
  version_cache_with_fixture(directory => {
    let provider = OpenAIProvider(
      transport=Some(transport),
      cache_dir=Some(directory),
    )
    try provider.refresh(codex_version_refresh_source()) catch {
      @posoco.CompositionError::ManifestSchemaError(manifest_id~, detail~) => {
        // The original models-refresh error text is preserved verbatim inside
        // the typed composition error.
        assert_eq(manifest_id, "posoco_ext_openai")
        assert_true(
          detail.contains(
            "OpenAI models HTTP status: 500, body_chars=" +
            "{\"error\":\"down\"}".length().to_string(),
          ),
        )
        assert_true(detail.contains("Codex model catalog refresh failed: "))
      }
      _ => fail("expected the typed models refresh failure")
    } noraise {
      _ => fail("expected the refresh to fail on the models request")
    }
    // The version was persisted even though the model request failed: saving
    // is gated on discovery success only.
    let persisted = version_cache_fixture_read_file(
      directory, "codex_client_version.json",
    )
    assert_eq(
      persisted.map(parse_codex_client_version_payload),
      Some(Some("0.160.0")),
    )
  })
}

///|
async test "401 renewal retry reuses the same resolved version" {
  let log : Array[String] = []
  let transport_impl = CodexVersionProbeTransport::CodexVersionProbeTransport(
    log,
    [
      OpenAIModelsHttpResponse::{
        status: 200,
        body: codex_release_body("rust-v0.160.0"),
      },
      // First catalog request rejected; renewal then retry.
      OpenAIModelsHttpResponse::{
        status: 401,
        body: "{\"error\":\"expired\"}",
      },
      OpenAIModelsHttpResponse::{
        status: 200,
        body: load_refresh_models_body(),
      },
      OpenAIModelsHttpResponse::{
        status: 200,
        body: load_refresh_usage_body(),
      },
    ],
  )
  let transport : &OpenAIModelsHttpTransport = transport_impl
  let oauth_transport_impl = CodexRecordingTransport::{
    requests: [],
    responses: [
      @oauth.OAuthHttpResponse::{
        status: 200,
        body: codex_renewal_response_body(),
      },
    ],
  }
  let oauth_transport : &@oauth.OAuthHttpTransport = oauth_transport_impl
  version_cache_with_fixture(directory => {
    let provider = OpenAIProvider(
      transport=Some(transport),
      oauth_transport=Some(oauth_transport),
      cache_dir=Some(directory),
    )
    match provider.refresh(codex_version_refresh_source()) {
      @llm.ProviderBuildResult::Ready(_) => ()
      @llm.ProviderBuildResult::Unconfigured =>
        fail("OAuth source was configured")
    }
    // Exactly one renewal and one retry; both catalog requests carry the same
    // resolved version, and discovery ran exactly once for the whole refresh.
    assert_eq(oauth_transport_impl.requests.length(), 1)
    let models_urls = [transport_impl.log[1], transport_impl.log[2]]
    assert_eq(
      models_urls[0],
      "get https://chatgpt.com/backend-api/codex/models?client_version=0.160.0",
    )
    assert_eq(models_urls[0], models_urls[1])
    // The first request carried the stored token, the retry the renewed one.
    assert_eq(
      transport_impl.header_log[1].get("Authorization"),
      Some("Bearer " + codex_test_access_token()),
    )
    assert_eq(
      transport_impl.header_log[2].get("Authorization"),
      Some("Bearer " + codex_renewed_access_token()),
    )
  })
}

///|
async test "a failed version-cache write does not shadow the refresh" {
  let log : Array[String] = []
  let transport_impl = CodexVersionProbeTransport::CodexVersionProbeTransport(
    log,
    [
      OpenAIModelsHttpResponse::{
        status: 200,
        body: codex_release_body("rust-v0.160.0"),
      },
      OpenAIModelsHttpResponse::{
        status: 200,
        body: load_refresh_models_body(),
      },
      OpenAIModelsHttpResponse::{
        status: 200,
        body: load_refresh_usage_body(),
      },
    ],
  )
  let transport : &OpenAIModelsHttpTransport = transport_impl
  // A regular file occupies the cache_dir path, so every host write fails
  // like a full disk or a read-only cache root: nothing persists, and the
  // refresh must still succeed on the discovered version.
  version_cache_with_fixture(directory => {
    version_cache_fixture_write_file(directory, "occupied", "not a directory")
    let provider = OpenAIProvider(
      transport=Some(transport),
      cache_dir=Some(openai_cache_join(directory, "occupied")),
    )
    match provider.refresh(codex_version_refresh_source()) {
      @llm.ProviderBuildResult::Ready(catalog) =>
        assert_eq(catalog.slots().length(), 1)
      @llm.ProviderBuildResult::Unconfigured =>
        fail("OAuth source was configured")
    }
    assert_eq(version_cache_fixture_list(directory), ["occupied"])
    assert_eq(
      transport_impl.log[1],
      "get https://chatgpt.com/backend-api/codex/models?client_version=0.160.0",
    )
  })
}

///|
test "cache payload parser accepts only the current format" {
  assert_eq(
    parse_codex_client_version_payload("{\"client_version\":\"0.160.0\"}"),
    Some("0.160.0"),
  )
  // Pretty-printed (the host writes indented JSON) still parses.
  assert_eq(
    parse_codex_client_version_payload(
      "{\n  \"client_version\": \"0.160.0\"\n}\n",
    ),
    Some("0.160.0"),
  )
  let refused : Array[String] = [
    "", "not json", "[]", "\"0.160.0\"", "{\"client_version\":true}", "{\"client_version\":\"rust-v0.160.0\"}",
    "{\"client_version\":\"\"}",
  ]
  for raw in refused {
    assert_true(parse_codex_client_version_payload(raw) is None)
  }
}
