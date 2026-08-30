///|
/// Host file access over the ACP `fs/read_text_file` / `fs/write_text_file`
/// Agent-to-Client reverse calls.
///
/// Path semantics belong to the host, which resolves each path against the
/// session cwd: this adapter passes the path string through verbatim — no
/// normalization, no existence check, and no permission policy of its own
/// (the host remains free to deny any request). Reads request the whole
/// file; the protocol's line/limit window is not exposed.
///
/// This is a plain struct adapter: it implements no posoco port and never
/// appears in an extension manifest.

///|
/// One failed host `fs/*` reverse call. `method_name` names the adapter call
/// ("read_text_file" / "write_text_file"); `cause` preserves the underlying
/// `AgentContextError`, whose variants carry the wire method names
/// ("fs/read_text_file" / "fs/write_text_file").
pub(all) suberror AcpHostFsError {
  HostFsCallFailed(method_name~ : String, cause~ : @acp.AgentContextError)
} derive(Eq, Debug)

///|
pub struct AcpHostFs {
  context : @acp.AgentContext
  session_id : String
}

///|
/// Bind host fs access to one live context and one ACP session. The session
/// id is stamped on every reverse request, so one instance must not be
/// reused across sessions.
pub fn AcpHostFs::AcpHostFs(
  context~ : @acp.AgentContext,
  session_id~ : String,
) -> AcpHostFs {
  { context, session_id, }
}

///|
/// Tag one context failure with the adapter method that issued it.
fn host_fs_failure(
  method_name : String,
  error : @acp.AgentContextError,
) -> AcpHostFsError {
  HostFsCallFailed(method_name~, cause=error)
}

///|
/// Read one whole file from the host and return its content. Any context
/// failure is wrapped with this method's name.
pub async fn AcpHostFs::read_text_file(
  self : AcpHostFs,
  path~ : String,
) -> String raise AcpHostFsError {
  let params : @acp.ReadTextFileParams = {
    session_id: self.session_id,
    path,
    line: Omitted,
    limit: Omitted,
    meta: Omitted,
  }
  let result = self.context.read_text_file(params) catch {
    error => raise host_fs_failure("read_text_file", error)
  }
  result.content
}

///|
/// Write one file on the host. Any context failure is wrapped with this
/// method's name.
pub async fn AcpHostFs::write_text_file(
  self : AcpHostFs,
  path~ : String,
  content~ : String,
) -> Unit raise AcpHostFsError {
  let params : @acp.WriteTextFileParams = {
    session_id: self.session_id,
    path,
    content,
    meta: Omitted,
  }
  ignore(
    self.context.write_text_file(params) catch {
      error => raise host_fs_failure("write_text_file", error)
    },
  )
}
