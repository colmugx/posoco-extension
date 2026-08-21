///|
/// White-box tests for the file credential backend and the record codec.
///
/// The fake WorkspaceFs keeps an in-memory map plus failure injection so the
/// Missing/Content/Failed matrix runs on every target without real IO.

///|
priv struct FakeFs {
  files : Map[String, String]
  fail_ops : Map[String, Bool]
}

///|
fn FakeFs::new() -> FakeFs {
  { files: Map::from_array([]), fail_ops: Map::from_array([]) }
}

///|
fn FakeFs::should_fail(self : FakeFs, op : String) -> Bool {
  self.fail_ops.get(op) is Some(true)
}

///|
impl @workspace.WorkspaceFs for FakeFs with fn exists(self, path) {
  if self.should_fail("exists") {
    raise @workspace.WorkspaceFsError::WorkspaceFsError("exists failed")
  }
  self.files.contains(path)
}

///|
impl @workspace.WorkspaceFs for FakeFs with fn kind(
  _self,
  _path,
  follow_symlink~,
) {
  let _ = follow_symlink
  @workspace.WorkspaceFileKind::File
}

///|
impl @workspace.WorkspaceFs for FakeFs with fn read_file(self, path) {
  if self.should_fail("read_file") {
    raise @workspace.WorkspaceFsError::WorkspaceFsError("read failed")
  }
  match self.files.get(path) {
    Some(content) => content
    None => raise @workspace.WorkspaceFsError::WorkspaceFsError("missing")
  }
}

///|
impl @workspace.WorkspaceFs for FakeFs with fn write_file(self, path, content) {
  if self.should_fail("write_file") {
    raise @workspace.WorkspaceFsError::WorkspaceFsError("write failed")
  }
  self.files[path] = content
}

///|
impl @workspace.WorkspaceFs for FakeFs with fn write_file_atomic(
  self,
  path,
  content,
) {
  if self.should_fail("write_file_atomic") {
    raise @workspace.WorkspaceFsError::WorkspaceFsError("atomic write failed")
  }
  self.files[path] = content
}

///|
impl @workspace.WorkspaceFs for FakeFs with fn remove(self, path) {
  if self.should_fail("remove") {
    raise @workspace.WorkspaceFsError::WorkspaceFsError("remove failed")
  }
  self.files.remove(path)
}

///|
impl @workspace.WorkspaceFs for FakeFs with fn rename(
  _self,
  _from,
  _to,
  replace~,
) {
  let _ = replace
}

///|
impl @workspace.WorkspaceFs for FakeFs with fn realpath(_self, path) {
  path
}

///|
impl @workspace.WorkspaceFs for FakeFs with fn readdir(
  _self,
  _path,
  include_hidden~,
) {
  let _ = include_hidden
  []
}

///|
impl @workspace.WorkspaceFs for FakeFs with fn walk(_self, _root, _callback) {

}

///|
impl @workspace.WorkspaceFs for FakeFs with fn mkdir(self, _path, recursive~) {
  let _ = recursive
  if self.should_fail("mkdir") {
    raise @workspace.WorkspaceFsError::WorkspaceFsError("mkdir failed")
  }
}

///|
fn api_key_credential() -> @oauth.ProviderCredential {
  @oauth.ProviderCredential::ApiKey(
    @oauth.ApiKeyCredential::ApiKeyCredential(secret="sk-test"),
  )
}

///|
test "record codec round-trips tagged credentials" {
  let credential = api_key_credential()
  let text = encode_provider_credential(credential)
  let json = @json.parse(text) catch { _ => fail("encoded record must parse") }
  let parsed = parse_provider_credential(json, "kimi")
  assert_eq(parsed.method_id(), "api_key")
}

///|
test "record codec rejects malformed shapes with a typed error" {
  let malformed = @json.parse("{\"oauth\":{}}") catch {
    _ => fail("fixture must parse")
  }
  try parse_provider_credential(malformed, "kimi") catch {
    @posoco.CompositionError::ManifestSchemaError(detail~, ..) =>
      assert_true(detail.contains("kimi"))
    _ => fail("expected ManifestSchemaError")
  } noraise {
    _ => fail("expected parse to raise")
  }
  try parse_provider_credential_text("not json", "kimi") catch {
    @posoco.CompositionError::ManifestSchemaError(detail~, ..) =>
      assert_true(detail.contains("not valid JSON"))
    _ => fail("expected ManifestSchemaError")
  } noraise {
    _ => fail("expected parse to raise")
  }
}

///|
async test "file store read missing content malformed" {
  let fs = FakeFs::new()
  let store = FileProviderCredentialStore::new(fs, "/cfg/credentials")
  // Missing → None (unconfigured), never an error.
  assert_true(store.read("kimi") is None)
  // Round-trip: write then read back the same method.
  store.write("kimi", api_key_credential())
  match store.read("kimi") {
    Some(credential) => assert_eq(credential.method_id(), "api_key")
    None => fail("expected a stored credential")
  }
  // Malformed record → typed parse error, never a silent None.
  fs.files["/cfg/credentials/deepseek.json"] = "{\"legacy\":true}"
  try store.read("deepseek") catch {
    @oauth.OAuthError::ParseError(detail) =>
      assert_true(detail.contains("deepseek"))
    _ => fail("expected ParseError")
  } noraise {
    _ => fail("expected read to raise")
  }
}

///|
async test "file store delete is idempotent and failure is observable" {
  let fs = FakeFs::new()
  let store = FileProviderCredentialStore::new(fs, "/cfg/credentials")
  // Deleting an absent record is a successful logout.
  store.delete("kimi")
  store.write("kimi", api_key_credential())
  store.delete("kimi")
  assert_true(store.read("kimi") is None)
  // A filesystem refusal surfaces as a typed error.
  fs.fail_ops["exists"] = true
  try store.delete("kimi") catch {
    @oauth.OAuthError::HttpError(_) => ()
    _ => fail("expected HttpError")
  } noraise {
    _ => fail("expected delete to raise")
  }
}

///|
async test "file store write failure keeps previous record" {
  let fs = FakeFs::new()
  let store = FileProviderCredentialStore::new(fs, "/cfg/credentials")
  store.write("kimi", api_key_credential())
  let before = fs.files["/cfg/credentials/kimi.json"]
  fs.fail_ops["write_file_atomic"] = true
  try store.write("kimi", api_key_credential()) catch {
    @oauth.OAuthError::HttpError(_) => ()
    _ => fail("expected HttpError")
  } noraise {
    _ => fail("expected write to raise")
  }
  assert_eq(fs.files["/cfg/credentials/kimi.json"], before)
}
