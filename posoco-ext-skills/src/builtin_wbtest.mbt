///|
async test "builtin: activation returns the inline body without touching the filesystem" {
  let fs = FakeFs()
  let skills = must_skills(
    fs,
    catalog_of([
      SkillDescriptor::builtin(
        name="cetas-about",
        description="What cetas is",
        body="Do the builtin thing.",
      ),
    ]),
  )
  let outcome = skills.activate("cetas-about")
  match outcome {
    @posoco.ToolOutcome::Success(content~, structured~) => {
      assert_true(content.contains("Do the builtin thing."))
      assert_true(content.contains("Built-in Agent Skill"))
      match structured {
        Some(Object(values)) =>
          assert_eq(values.get("summary"), Some(Json::string("cetas-about")))
        _ => fail("expected structured activation metadata")
      }
    }
    _ => fail("builtin activation should succeed")
  }
  assert_true(fs.reads.is_empty())
  assert_true(fs.readdirs.is_empty())
}

///|
async test "builtin: body exceeding max_instruction_chars is rejected" {
  let fs = FakeFs()
  let config = SkillsConfig::{
    ..SkillsConfig::default(),
    max_instruction_chars: 10,
  }
  let skills = must_skills(
    fs,
    catalog_of([
      SkillDescriptor::builtin(
        name="cetas-about",
        description="What cetas is",
        body="this body is far longer than ten characters",
      ),
    ]),
    config~,
  )
  match skills.activate("cetas-about") {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) =>
      assert_true(content.contains("exceed configured activation limit"))
    _ => fail("oversized builtin body must fail")
  }
  assert_true(fs.reads.is_empty())
}

///|
async test "builtin: resource reads fail closed" {
  let fs = FakeFs()
  let skills = must_skills(
    fs,
    catalog_of([
      SkillDescriptor::builtin(
        name="cetas-about",
        description="What cetas is",
        body="Body",
      ),
    ]),
  )
  match skills.read_resource("cetas-about", "guide.md") {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) =>
      assert_true(content.contains("Skill resource not found"))
    _ => fail("builtin resource read must fail closed")
  }
  assert_true(fs.reads.is_empty())
}

///|
async test "builtin: inline resources are served without touching the filesystem" {
  let fs = FakeFs()
  let skills = must_skills(
    fs,
    catalog_of([
      SkillDescriptor::builtin(
        name="poteto-mode",
        description="Workflow",
        body="Read resources/guide.md when needed.",
        resources=Map([("resources/guide.md", "# Guide\nstep")]),
      ),
    ]),
  )
  match skills.read_resource("poteto-mode", "resources/guide.md") {
    @posoco.ToolOutcome::Success(content~, structured~) => {
      assert_true(content.contains("# Guide"))
      match structured {
        Some(Object(values)) =>
          assert_eq(
            values.get("path"),
            Some(Json::string("resources/guide.md")),
          )
        _ => fail("expected structured resource metadata")
      }
    }
    _ => fail("inline resource read should succeed")
  }
  match skills.read_resource("poteto-mode", "resources/missing.md") {
    @posoco.ToolOutcome::ToolReportedError(content~, ..) =>
      assert_true(content.contains("Skill resource not found"))
    _ => fail("missing inline resource must fail closed")
  }
  match skills.activate("poteto-mode") {
    @posoco.ToolOutcome::Success(content~, ..) => {
      assert_true(content.contains("resources/guide.md"))
      assert_true(content.contains("Bundled resources"))
    }
    _ => fail("builtin activation should succeed")
  }
  assert_true(fs.reads.is_empty())
  assert_true(fs.readdirs.is_empty())
}

///|
test "builtin: descriptors pass catalog validation and render into the prompt" {
  let builtin = SkillDescriptor::builtin(
    name="cetas-about",
    description="What cetas is",
    body="Body",
  )
  let catalog = catalog_of([builtin])
  assert_eq(catalog.validate(), Ok(()))
  let rendered = catalog.render_prompt_body(max_chars=8000)
  assert_true(rendered.contains("cetas-about"))
  assert_true(rendered.contains("What cetas is"))
}

///|
test "merge: discovered skill shadows same-name builtin; others pass through" {
  let discovered = catalog_of([
    descriptor("shared", "User override", "/skills/shared"),
  ])
  let builtins = [
    SkillDescriptor::builtin(
      name="shared",
      description="Builtin manual",
      body="Builtin body",
    ),
    SkillDescriptor::builtin(
      name="cetas-usage",
      description="How to use cetas",
      body="Usage body",
    ),
  ]
  let merged = merge_builtin_skills(discovered, builtins)
  assert_eq(merged.validate(), Ok(()))
  assert_eq(merged.skills.length(), 2)
  assert_eq(merged.skills[0].name, "cetas-usage")
  assert_eq(merged.skills[1].name, "shared")
  assert_true(has_diagnostic(merged.diagnostics, Shadowed))
  match merged.find("shared") {
    Some(skill) => assert_true(skill.body is None)
    None => fail("discovered skill must win the name")
  }
  match merged.find("cetas-usage") {
    Some(skill) => assert_eq(skill.body, Some("Usage body"))
    None => fail("non-colliding builtin must be kept")
  }
}
