///|
/// Compile fixture for the intended public composition surface. This keeps
/// trait-object coercions explicit so API drift is caught by `moon test`.
test "handoff/public composition surface" {
  let store = DefaultHandoffStore()
  let workspace = HandoffWorkspaceState("/repo")
  let work = HandoffWorkState()

  let store_port : &HandoffStore = store
  let workspace_probe : &HandoffWorkspaceProbe = workspace
  let work_source : &HandoffWorkSource = work

  let handoff = Handoff(
    cwd="/repo",
    store=store_port,
    probe=workspace_probe,
    work_sources=[work_source],
  )

  let command_port : &@posoco.CommandPort = handoff
  let extension : &@posoco.Extension = handoff
  ignore(command_port)

  assert_eq(extension.extension_id(), "posoco_ext_handoff")
  let manifest = extension.manifest()
  assert_eq(manifest.id, "posoco_ext_handoff")
  assert_eq(manifest.commands.length(), 1)
  assert_eq(manifest.models.length(), 0)
  assert_eq(manifest.tools.length(), 0)
  assert_eq(manifest.sessions.length(), 0)
}
