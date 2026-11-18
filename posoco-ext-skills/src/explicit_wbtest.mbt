///|
/// explicit_wbtest.mbt — harness-level explicit activation via `$name`
/// mentions: scanning, envelope injection, idempotency, failure surfacing,
/// and manifest registration.

///|
/// Text of a single-Text-block user message at `index`; empty when the
/// position or shape does not match, so structural asserts below fail
/// loudly on malformed transcripts.
fn single_user_text(messages : Array[@posoco.Message], index : Int32) -> String {
  let mut text = ""
  if index >= 0 && index < messages.length() {
    match messages[index] {
      @posoco.Message::UserMessage(content~) =>
        if content.length() == 1 {
          match content[0] {
            @posoco.Content::Text(value) => text = value
            _ => ()
          }
        }
      _ => ()
    }
  }
  text
}

///|
async test "explicit: scan matches exact names only, dedupes, and keeps order" {
  let dir = "/skills/design"
  let fs = FakeFs()
  fs.add_dir(dir, ["SKILL.md"])
  fs.add_file(
    dir + "/SKILL.md",
    "---\nname: design\ndescription: Design\n---\nDesign body.",
  )
  let skills = must_skills(
    fs,
    catalog_of([descriptor("design", "Design", dir)]),
  )
  assert_eq(skills.scan_explicit_mentions("use $design please"), ["design"])
  assert_eq(skills.scan_explicit_mentions("$design."), ["design"])
  assert_eq(skills.scan_explicit_mentions("$design, then $design"), ["design"])
  // `-` is a name character, so it joins into one longer token.
  assert_eq(skills.scan_explicit_mentions("$design-$other"), [])
  assert_eq(skills.scan_explicit_mentions("$designs is a longer word"), [])
  assert_eq(skills.scan_explicit_mentions("$PATH and $HOME"), [])
  assert_eq(skills.scan_explicit_mentions("awk '$1' stays inert"), [])
  assert_eq(skills.scan_explicit_mentions("see /usr/local/bin"), [])
  assert_eq(skills.scan_explicit_mentions("nothing mentioned"), [])
  assert_eq(skills.scan_explicit_mentions(""), [])
}

///|
async test "explicit: hook injects the activation envelope ahead of the user input" {
  let dir = "/skills/demo"
  let fs = FakeFs()
  fs.add_dir(dir, ["SKILL.md"])
  fs.add_file(
    dir + "/SKILL.md",
    "---\nname: demo\ndescription: Demo\n---\nDemo instructions body.",
  )
  let skills = must_skills(fs, catalog_of([descriptor("demo", "Demo", dir)]))
  let messages = [
    @posoco.Message::SystemMessage(content=[@posoco.Content::Text("sys")]),
    @posoco.Message::UserMessage(content=[
      @posoco.Content::Text("use $demo to build a wall"),
    ]),
  ]
  let rewritten = (skills as &@posoco.PipelineHook).before_model(messages)
  assert_eq(rewritten.length(), 3)
  let envelope_text = single_user_text(rewritten, 1)
  assert_true(
    envelope_text.has_prefix(
      "<cetas-context type=\"skill_activation\" trust=\"false\"",
    ),
  )
  assert_true(envelope_text.contains("source=\"skill:demo\""))
  assert_true(envelope_text.contains("invocation=\"explicit\""))
  assert_true(envelope_text.contains("scope=\"project\""))
  assert_true(envelope_text.contains("Demo instructions body."))
  // Parity with the model-facing activation text. Envelope content is
  // XML-escaped by convention (the boundary must not be breakable), so the
  // quoted header arrives as &quot; entities; the instruction body carries
  // no escapable characters and must match verbatim.
  assert_true(envelope_text.contains("Activated Agent Skill: &quot;demo&quot;"))
  assert_true(envelope_text.contains("Instructions:\nDemo instructions body."))
  match skills.activate("demo") {
    @posoco.ToolOutcome::Success(content~, ..) =>
      assert_true(content.contains("Instructions:\nDemo instructions body."))
    _ => assert_true(false)
  }
  // The harness note forbids redundant re-activation.
  assert_true(envelope_text.contains("do not call activate_skill"))
  // The user's own text is preserved verbatim.
  assert_eq(
    rewritten[2],
    @posoco.Message::UserMessage(content=[
      @posoco.Content::Text("use $demo to build a wall"),
    ]),
  )
}

///|
async test "explicit: several mentions inject one envelope each in mention order" {
  let dir_a = "/skills/alpha"
  let dir_b = "/skills/beta"
  let fs = FakeFs()
  fs.add_dir(dir_a, ["SKILL.md"])
  fs.add_file(
    dir_a + "/SKILL.md",
    "---\nname: alpha\ndescription: A\n---\nAlpha body.",
  )
  fs.add_dir(dir_b, ["SKILL.md"])
  fs.add_file(
    dir_b + "/SKILL.md",
    "---\nname: beta\ndescription: B\n---\nBeta body.",
  )
  let skills = must_skills(
    fs,
    catalog_of([descriptor("alpha", "A", dir_a), descriptor("beta", "B", dir_b)]),
  )
  let messages = [
    @posoco.Message::UserMessage(content=[
      @posoco.Content::Text("run $beta then $alpha then $beta again"),
    ]),
  ]
  let rewritten = (skills as &@posoco.PipelineHook).before_model(messages)
  assert_eq(rewritten.length(), 2)
  let text = single_user_text(rewritten, 0)
  // Splitting on the envelope opening tag yields exactly two envelopes:
  // beta first (first mention), alpha second; the duplicate beta is gone.
  let parts = text.split("<cetas-context type=\"skill_activation\" ").collect()
  assert_eq(parts.length(), 3)
  assert_true(
    parts[1].to_owned().has_prefix("trust=\"false\" source=\"skill:beta\""),
  )
  assert_true(
    parts[2].to_owned().has_prefix("trust=\"false\" source=\"skill:alpha\""),
  )
  assert_true(text.contains("Alpha body."))
  assert_true(text.contains("Beta body."))
}

///|
async test "explicit: no mention leaves the transcript untouched" {
  let dir = "/skills/demo"
  let fs = FakeFs()
  fs.add_dir(dir, ["SKILL.md"])
  fs.add_file(
    dir + "/SKILL.md",
    "---\nname: demo\ndescription: Demo\n---\nBody.",
  )
  let skills = must_skills(fs, catalog_of([descriptor("demo", "Demo", dir)]))
  let hook = skills as &@posoco.PipelineHook
  let plain = [
    @posoco.Message::UserMessage(content=[
      @posoco.Content::Text("$PATH and plain text"),
    ]),
  ]
  assert_eq(hook.before_model(plain), plain)
  // A turn already deep in the tool loop ends on a ToolMessage: nothing to
  // scan, nothing to inject.
  let tool_ended = [
    @posoco.Message::UserMessage(content=[@posoco.Content::Text("use $demo")]),
    @posoco.Message::ToolMessage(
      call_id=@posoco.CallId::unchecked("call-1"),
      tool_name=@posoco.ToolName::unchecked("bash"),
      outcome=@posoco.ToolOutcome::Success(content="ok", structured=None),
    ),
  ]
  assert_eq(hook.before_model(tool_ended), tool_ended)
  assert_eq(hook.before_model([]), [])
}

///|
async test "explicit: non-text content blocks survive next to the injected message" {
  let dir = "/skills/demo"
  let fs = FakeFs()
  fs.add_dir(dir, ["SKILL.md"])
  fs.add_file(
    dir + "/SKILL.md",
    "---\nname: demo\ndescription: Demo\n---\nBody.",
  )
  let skills = must_skills(fs, catalog_of([descriptor("demo", "Demo", dir)]))
  let messages = [
    @posoco.Message::UserMessage(content=[
      @posoco.Content::Image(media_type="image/png", data="AAAA"),
      @posoco.Content::Text("$demo with the attached screenshot"),
    ]),
  ]
  let rewritten = (skills as &@posoco.PipelineHook).before_model(messages)
  assert_eq(rewritten.length(), 2)
  match rewritten[1] {
    @posoco.Message::UserMessage(content~) => {
      assert_eq(content.length(), 2)
      assert_eq(
        content[0],
        @posoco.Content::Image(media_type="image/png", data="AAAA"),
      )
      assert_eq(
        content[1],
        @posoco.Content::Text("$demo with the attached screenshot"),
      )
    }
    _ => assert_true(false)
  }
}

///|
async test "explicit: re-running the hook on an injected transcript is a no-op" {
  let dir = "/skills/demo"
  let fs = FakeFs()
  fs.add_dir(dir, ["SKILL.md"])
  fs.add_file(
    dir + "/SKILL.md",
    "---\nname: demo\ndescription: Demo\n---\nBody.",
  )
  let skills = must_skills(fs, catalog_of([descriptor("demo", "Demo", dir)]))
  let hook = skills as &@posoco.PipelineHook
  let messages = [
    @posoco.Message::UserMessage(content=[@posoco.Content::Text("use $demo")]),
  ]
  let injected = hook.before_model(messages)
  assert_eq(injected.length(), 2)
  let again = hook.before_model(injected)
  assert_eq(again, injected)
}

///|
async test "explicit: activation failure surfaces a harness error envelope" {
  let dir = "/skills/demo"
  let fs = FakeFs()
  fs.add_dir(dir, ["SKILL.md"])
  fs.add_file(
    dir + "/SKILL.md",
    "---\nname: demo\ndescription: changed\n---\nBody.",
  )
  let skills = must_skills(
    fs,
    catalog_of([descriptor("demo", "original", dir)]),
  )
  let messages = [
    @posoco.Message::UserMessage(content=[@posoco.Content::Text("$demo now")]),
  ]
  let rewritten = (skills as &@posoco.PipelineHook).before_model(messages)
  assert_eq(rewritten.length(), 2)
  let text = single_user_text(rewritten, 0)
  assert_true(
    text.has_prefix(
      "<cetas-context type=\"skill_activation_error\" trust=\"true\"",
    ),
  )
  assert_true(text.contains("metadata changed"))
  assert_true(text.contains("source=\"skill:demo\""))
  assert_eq(
    rewritten[1],
    @posoco.Message::UserMessage(content=[@posoco.Content::Text("$demo now")]),
  )
}

///|
async test "explicit: manifest registers the hook only when enabled and populated" {
  let dir = "/skills/demo"
  let fs = FakeFs()
  fs.add_dir(dir, ["SKILL.md"])
  fs.add_file(
    dir + "/SKILL.md",
    "---\nname: demo\ndescription: Demo\n---\nBody.",
  )
  let enabled = must_skills(fs, catalog_of([descriptor("demo", "Demo", dir)]))
  assert_eq(enabled.manifest().hooks.length(), 1)
  let disabled = must_skills(
    fs,
    catalog_of([descriptor("demo", "Demo", dir)]),
    config={ ..SkillsConfig::default(), explicit_activation: false, },
  )
  assert_eq(disabled.manifest().hooks.length(), 0)
  assert_eq(must_skills(fs, catalog_of([])).manifest().hooks.length(), 0)
}

///|
async test "explicit: unknown skill names reach the model untouched" {
  let dir = "/skills/demo"
  let fs = FakeFs()
  fs.add_dir(dir, ["SKILL.md"])
  fs.add_file(
    dir + "/SKILL.md",
    "---\nname: demo\ndescription: Demo\n---\nBody.",
  )
  let skills = must_skills(fs, catalog_of([descriptor("demo", "Demo", dir)]))
  let messages = [
    @posoco.Message::UserMessage(content=[
      @posoco.Content::Text("what does $unknown do"),
    ]),
  ]
  let rewritten = (skills as &@posoco.PipelineHook).before_model(messages)
  assert_eq(rewritten, messages)
}
