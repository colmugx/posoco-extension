///|
/// Integration-level composition tests. These exercise the public high-level
/// API instead of duplicating the manual assembly in every Posoco host.

///|
test "compose_profiles_captures_members_and_preserves_other_deferred_prompts" {
  let profiled : &@posoco.Extension = FakeProfileExt::{
    id: "profiled",
    tools: [@tk.RecordingToolProvider([], Map::from_array([]))],
    observers: [],
    prompts: [FixedPrompt::{ text: "Profiled manual", }],
  }
  let unprofiled : &@posoco.Extension = FakeProfileExt::{
    id: "unprofiled",
    tools: [],
    observers: [],
    prompts: [FixedPrompt::{ text: "Keep this resident", }],
  }
  let resident : &@posoco.Extension = FakeProfileExt::{
    id: "resident",
    tools: [],
    observers: [],
    prompts: [FixedPrompt::{ text: "Resident manual", }],
  }
  let result = compose_profiles(
    resident=[resident],
    deferred=[profiled, unprofiled],
    manifests=[parsed_manifest("research", exts=["profiled"])],
  )
  let composition = match result {
    Ok(composition) => composition
    Err(message) => fail(message)
  }
  assert_eq(composition.deferred_ids, ["profiled"])
  assert_eq(composition.exts.length(), 5)
  assert_eq(composition.exts[0].extension_id(), "resident")
  assert_eq(composition.exts[1].extension_id(), "posoco_ext_profiles")
  assert_eq(composition.exts[2].extension_id(), "profiled")
  assert_eq(composition.exts[2].manifest().prompt_contributors.length(), 0)
  assert_eq(composition.exts[2].manifest().tools.length(), 0)
  assert_eq(composition.exts[3].extension_id(), "unprofiled")
  assert_eq(composition.exts[3].manifest().prompt_contributors.length(), 1)
  assert_eq(composition.exts[4].extension_id(), "posoco_ext_lazytools")
  let manual = composition.profiles.activation_message("research")
  match manual {
    @posoco.Message::UserMessage(content~) =>
      match content {
        [@posoco.Content::Text(text), ..] =>
          assert_true(text.contains("Profiled manual"))
        _ => fail("expected profile activation text")
      }
    _ => fail("expected user message")
  }
}

///|
test "compose_profiles_rejects_duplicate_extension_ids" {
  let ext : &@posoco.Extension = FakeProfileExt::{
    id: "duplicate",
    tools: [],
    observers: [],
    prompts: [],
  }
  match compose_profiles(resident=[ext], deferred=[ext], manifests=[]) {
    Err(message) => assert_true(message.contains("duplicate extension id"))
    Ok(_) => fail("duplicate extension ids must be rejected")
  }
}
