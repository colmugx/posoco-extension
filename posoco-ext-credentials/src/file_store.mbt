///|
/// file_store.mbt — File-backed `ProviderCredentialStore` over `WorkspaceFs`.
///
/// This is the first durable backend. It performs no target-specific IO of
/// its own: all filesystem access goes through the injected `WorkspaceFs`
/// boundary, so the same store serves native (`NativeWorkspaceFs`) and js
/// (`JsWorkspaceFs`) hosts. Future OS secret-manager backends implement the
/// same `@oauth.ProviderCredentialStore` trait in their own module.
///
/// The record format is the canonical tagged record from `record.mbt`. There
/// is deliberately no legacy-file migration: a malformed record is a typed
/// error, never a silent reinterpretation.

///|
/// A file-backed canonical credential store. `dir` is injected by the host
/// (product layouts like `<cwd>/.cetas/credentials` stay the host's choice).
pub struct FileProviderCredentialStore {
  fs : &@workspace.WorkspaceFs
  dir : String
}

///|
pub fn FileProviderCredentialStore::new(
  fs : &@workspace.WorkspaceFs,
  dir : String,
) -> FileProviderCredentialStore {
  { fs, dir }
}

///|
/// The record file for one provider below the store directory.
fn FileProviderCredentialStore::credential_path(
  self : FileProviderCredentialStore,
  provider_id : String,
) -> String {
  self.dir + "/" + provider_id + ".json"
}

///|
/// Convert a filesystem failure into the store's typed error without leaking
/// secret material (paths and op names only).
fn store_err(
  op : String,
  provider_id : String,
  cause : String,
) -> @oauth.OAuthError {
  @oauth.OAuthError::HttpError(
    "credential " + op + " failed for provider " + provider_id + ": " + cause,
  )
}

///|
pub impl @oauth.ProviderCredentialStore for FileProviderCredentialStore with fn read(
  self : FileProviderCredentialStore,
  provider_id : String,
) -> @oauth.ProviderCredential? raise @oauth.OAuthError {
  match
    @workspace.read_file_result(self.fs, self.credential_path(provider_id)) {
    Missing => None
    Failed(message) => raise store_err("read", provider_id, message)
    Content(text) => {
      let credential = parse_provider_credential_text(text, provider_id) catch {
        @posoco.CompositionError::ManifestSchemaError(detail~, ..) =>
          raise @oauth.OAuthError::ParseError(detail)
        err =>
          raise @oauth.OAuthError::ParseError(
            "credential record unreadable for provider " +
            provider_id +
            ": " +
            err.to_string(),
          )
      }
      Some(credential)
    }
  }
}

///|
pub impl @oauth.ProviderCredentialStore for FileProviderCredentialStore with fn write(
  self : FileProviderCredentialStore,
  provider_id : String,
  credential : @oauth.ProviderCredential,
) -> Unit raise @oauth.OAuthError {
  self.fs.mkdir(self.dir, recursive=true) catch {
    @workspace.WorkspaceFsError::WorkspaceFsError(message) =>
      raise store_err("directory-create", provider_id, message)
  }
  // Atomic replace: a failure leaves the previous record intact.
  self.fs.write_file_atomic(
    self.credential_path(provider_id),
    encode_provider_credential(credential),
  ) catch {
    @workspace.WorkspaceFsError::WorkspaceFsError(message) =>
      raise store_err("write", provider_id, message)
  }
}

///|
pub impl @oauth.ProviderCredentialStore for FileProviderCredentialStore with fn delete(
  self : FileProviderCredentialStore,
  provider_id : String,
) -> Unit raise @oauth.OAuthError {
  let path = self.credential_path(provider_id)
  let present = self.fs.exists(path) catch {
    @workspace.WorkspaceFsError::WorkspaceFsError(message) =>
      raise store_err("delete", provider_id, message)
  }
  // Deleting an absent record is a successful logout, not an error.
  if present {
    self.fs.remove(path) catch {
      @workspace.WorkspaceFsError::WorkspaceFsError(message) =>
        raise store_err("delete", provider_id, message)
    }
  }
}
