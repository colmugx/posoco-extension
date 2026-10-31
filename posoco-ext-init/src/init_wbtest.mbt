///|
test "init parses defaults and explicit modes" {
  assert_eq(init_parse_args(Json::null()), Ok(("create", ".", None)))
  assert_eq(init_parse_args(Json::string("check")), Ok(("check", ".", None)))
  assert_eq(init_parse_args(Json::string("refresh src")), Ok(("refresh", "src", None)))
  assert_eq(init_parse_args(Json::string("packages/core")), Ok(("create", "packages/core", None)))
}

///|
test "init rejects traversals and shell-unsafe paths" {
  for path in ["../foo", "/tmp", "a/../b", "a//b", "a;touch", "a b", "C:\\tmp", "a/$HOME", "a\nb"] {
    assert_true(init_validate_path(path) is Err(_))
  }
}

///|
test "init rejects ambiguous or invalid invocation" {
  assert_true(init_parse_args(Json::string("refresh a b")) is Err(_))
  assert_true(init_parse_args(Json::object({ "action": Json::number(2) })) is Err(_))
  assert_true(init_parse_args(Json::object({ "action": Json::string("force") })) is Err(_))
}

///|
test "init manifest declares command lifecycle and wakeup" {
  let ext = Init()
  let manifest = ext.manifest()
  assert_eq(manifest.id, "posoco_ext_init")
  assert_eq(manifest.commands.length(), 1)
  assert_eq(manifest.lifecycle.length(), 1)
  assert_eq(manifest.requires, [@posoco.Capability::Wakeup])
  let defs = ext.commands()
  assert_eq(defs[0].id, "init")
  assert_eq(defs[0].params.length(), 2)
}

///|
test "init prompt distinguishes audited and writable actions" {
  let create = init_instruction("create", ".")
  let check = init_instruction("check", ".")
  let refresh = init_instruction("refresh", "packages/core")
  assert_true(create.contains("CREATE ONLY IF MISSING"))
  assert_true(check.contains("Do not modify any file"))
  assert_true(refresh.contains("packages/core/AGENTS.md"))
  assert_true(refresh.contains("retain human-written policies"))
  assert_true(create.contains("never invent commands"))
}

///|
async test "init command rejects absent session and unbound wakeup" {
  let ext = Init()
  let no_session = ext.invoke("init", Json::null())
  assert_true(no_session is @posoco.CommandOutcome::Failure(..))
  ext.set_session(Some("session-1"))
  let no_wakeup = ext.invoke("init", Json::null())
  assert_true(no_wakeup is @posoco.CommandOutcome::Failure(..))
}
