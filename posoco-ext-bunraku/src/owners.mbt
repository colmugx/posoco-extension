///|
/// Single source of truth for the nested invocation face: the tool owners
/// whose capabilities run_code guest programs may reach through the kernel
/// child pipeline. The manifest declares this list as `tool_call_owners`
/// (default-deny); the kernel admits child calls per owner and computes the
/// guest-visible face (`ToolCallContext::tools`) from the same fact.

///|
/// Owner-level by design: adding a tool to one of these extensions
/// automatically joins the face, and any other owner stays out. bunraku
/// itself is NOT in the list — it is the composition caller, not the owner
/// of the face, and it never republishes other extensions' tools.
pub fn bunraku_nested_source_owners() -> Array[String] {
  [
    "posoco_ext_read", "posoco_ext_grep", "posoco_ext_glob", "posoco_ext_write",
    "posoco_ext_edit", "posoco_ext_bash",
  ]
}
