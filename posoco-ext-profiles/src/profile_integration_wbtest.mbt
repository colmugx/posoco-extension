///|
/// Regressions for overlapping profile activation and header-only compact
/// restoration. The transcript, not mutable extension state, drives both.

///|
async test "overlapping_profiles_inject_each_extension_manual_once" {
  let profiles = Profiles::build(
    manifests=[
      parsed_manifest("research", exts=["web", "memory"]),
      parsed_manifest("deep", exts=["web", "memory", "database"]),
    ],
    defer_set=["web", "memory", "database"],
    captured_prompts=Map::from_array([
      ("web", "UNIQUE_WEB_MANUAL"),
      ("memory", "UNIQUE_MEMORY_MANUAL"),
      ("database", "UNIQUE_DATABASE_MANUAL"),
    ]),
    attribution=Map::from_array([]),
  )
  let messages : Array[@posoco.Message] = [
    assistant_with_calls([
      activate_call("c1", profile="research"),
      activate_call("c2", profile="deep"),
    ]),
    tool_result("c1", "activated: research"),
    tool_result("c2", "activated: deep"),
  ]
  let output = profiles.before_model(messages)
  assert_eq(output.length(), 5)
  let first = match output[3] {
    @posoco.Message::UserMessage(content~) =>
      match content {
        [@posoco.Content::Text(text), ..] => text
        _ => ""
      }
    _ => ""
  }
  let second = match output[4] {
    @posoco.Message::UserMessage(content~) =>
      match content {
        [@posoco.Content::Text(text), ..] => text
        _ => ""
      }
    _ => ""
  }
  assert_true(first.contains("UNIQUE_WEB_MANUAL"))
  assert_true(first.contains("UNIQUE_MEMORY_MANUAL"))
  assert_false(first.contains("UNIQUE_DATABASE_MANUAL"))
  assert_true(second.contains("UNIQUE_DATABASE_MANUAL"))
  assert_false(second.contains("UNIQUE_WEB_MANUAL"))
  assert_false(second.contains("UNIQUE_MEMORY_MANUAL"))
}

///|
async test "compact_header_only_profile_rehydrates_manual_without_new_activation" {
  let profiles = Profiles::build(
    manifests=[parsed_manifest("research", exts=["web"])],
    defer_set=["web"],
    captured_prompts=Map::from_array([("web", "WEB_MANUAL_RESTORED")]),
    attribution=Map::from_array([]),
  )
  let messages : Array[@posoco.Message] = [
    user_msg("profile research activated"),
  ]
  let output = profiles.before_model(messages)
  assert_eq(output.length(), 1)
  match output[0] {
    @posoco.Message::UserMessage(content~) =>
      match content {
        [@posoco.Content::Text(text), ..] => {
          assert_true(text.has_prefix("profile research activated"))
          assert_true(text.contains("WEB_MANUAL_RESTORED"))
        }
        _ => fail("missing restored text")
      }
    _ => fail("missing restored activation message")
  }
}

///|
async test "direct_profile_command_rejects_unknown_id_before_submitting" {
  let sink = RecordingActivationSink::{ calls: [], failure: None, }
  let profiles = Profiles::build(
    manifests=[parsed_manifest("research")],
    defer_set=[],
    captured_prompts=Map::from_array([]),
    attribution=Map::from_array([]),
    activation_sink=Some(sink),
  )
  match profiles.invoke(
    "profiles",
    Json::object(Map::from_array([
      ("profile", Json::string("missing")),
      ("session_id", Json::string("s1")),
    ])),
  ) {
    @posoco.CommandOutcome::Failure(reason~) =>
      assert_true(reason.contains("unknown profile"))
    _ => fail("unknown profile must fail without submitting")
  }
  assert_eq(sink.calls.length(), 0)
}
