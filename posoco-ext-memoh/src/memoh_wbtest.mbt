///|
async test "memoh session store is intentionally ephemeral" {
  let memoh = Memoh()
  let first = memoh.load("s1")
  assert_eq(first.messages.length(), 0)
  assert_eq(first.metadata.size(), 0)

  let user = @posoco.Message::UserMessage(content=[
    @posoco.Content::Text("hello"),
  ])
  let dirty = @posoco.Session::{
    messages: [user],
    metadata: Map::from_array([("marker", Json::string("value"))]),
  }

  memoh.save("s1", dirty)
  memoh.append_messages("s1", 0, [user][:])
  memoh.truncate("s1", 0)

  let after = memoh.load("s1")
  assert_eq(after.messages.length(), 0)
  assert_eq(after.metadata.size(), 0)
}

///|
test "memoh extension contributes the session store" {
  let memoh = Memoh()
  assert_eq(memoh.extension_id(), "posoco_ext_memoh")
  let manifest = memoh.manifest()
  assert_eq(manifest.sessions.length(), 1)
  assert_eq(manifest.hooks.length(), 0)
  assert_eq(manifest.tools.length(), 0)
}
