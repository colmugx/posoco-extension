///|
/// White-box tests for the host-facing `skills` CommandPort: catalog listing
/// payload shape (scope mapping), host-driven activation, and argument
/// validation.

///|
async test "command: list returns catalog snapshot with scope labels" {
  let skills = must_skills(
    FakeFs(),
    catalog_of([
      descriptor("review-pr", "Review a PR", "/repo/.agents/skills/review-pr"),
      descriptor("tdd", "Test first", "/repo/.agents/skills/tdd"),
      descriptor(
        "ego-browser",
        "Browse",
        "/home/u/.agents/skills/ego-browser",
        scope=SkillScope::User,
      ),
      descriptor(
        "custom",
        "Extra root",
        "/opt/skills/custom",
        scope=SkillScope::Extra("/opt/skills"),
      ),
    ]),
  )
  let defs = skills.commands()
  assert_eq(defs.length(), 1)
  assert_eq(defs[0].id, "skills")
  match skills.invoke("skills", Json::object(Map([]))) {
    @posoco.CommandOutcome::Success(feedback~, structured~, ..) => {
      assert_eq(feedback, "4 skills (project 2, user 1, extension 1)")
      assert_eq(
        structured,
        Some(
          Json::object(
            Map([
              ("kind", Json::string("skills_catalog")),
              (
                "skills",
                Json::array([
                  Json::object(
                    Map([
                      ("name", Json::string("review-pr")),
                      ("description", Json::string("Review a PR")),
                      ("scope", Json::string("project")),
                      ("user_invoked_only", Json::boolean(false)),
                    ]),
                  ),
                  Json::object(
                    Map([
                      ("name", Json::string("tdd")),
                      ("description", Json::string("Test first")),
                      ("scope", Json::string("project")),
                      ("user_invoked_only", Json::boolean(false)),
                    ]),
                  ),
                  Json::object(
                    Map([
                      ("name", Json::string("ego-browser")),
                      ("description", Json::string("Browse")),
                      ("scope", Json::string("user")),
                      ("user_invoked_only", Json::boolean(false)),
                    ]),
                  ),
                  Json::object(
                    Map([
                      ("name", Json::string("custom")),
                      ("description", Json::string("Extra root")),
                      ("scope", Json::string("extension")),
                      ("root", Json::string("/opt/skills")),
                      ("user_invoked_only", Json::boolean(false)),
                    ]),
                  ),
                ]),
              ),
            ]),
          ),
        ),
      )
    }
    _ => fail("expected success outcome")
  }
}

///|
async test "command: user-invoked-only skills list with a marker and a summary count" {
  let skills = must_skills(
    FakeFs(),
    catalog_of([
      descriptor("review-pr", "Review a PR", "/repo/.agents/skills/review-pr"),
      descriptor(
        "figure-it-out",
        "Design an auditable playbook",
        "/repo/.agents/skills/figure-it-out",
        user_invoked_only=true,
      ),
    ]),
  )
  match skills.invoke("skills", Json::object(Map([]))) {
    @posoco.CommandOutcome::Success(feedback~, structured~, ..) => {
      // Humans see the user-invoked-only count in the summary line.
      assert_eq(
        feedback, "2 skills (project 2, user 0, extension 0; 1 user-invoked only)",
      )
      match structured {
        Some(
          Json::Object(
            {
              "kind": Json::String("skills_catalog"),
              "skills": Json::Array(entries),
              ..
            },
          ),
        ) => {
          assert_eq(entries.length(), 2)
          // The user-invoked-only entry keeps its scope field and gains the
          // additive marker; the model-invocable entry keeps false.
          match entries[1] {
            Json::Object(fields) => {
              assert_eq(fields.get("name"), Some(Json::string("figure-it-out")))
              assert_eq(fields.get("scope"), Some(Json::string("project")))
              assert_eq(
                fields.get("user_invoked_only"),
                Some(Json::boolean(true)),
              )
            }
            other =>
              fail("expected a JSON object entry, got: " + other.stringify())
          }
          match entries[0] {
            Json::Object(fields) =>
              assert_eq(
                fields.get("user_invoked_only"),
                Some(Json::boolean(false)),
              )
            other =>
              fail("expected a JSON object entry, got: " + other.stringify())
          }
        }
        other =>
          fail(
            "unexpected structured payload: " +
            other.map(value => value.stringify()).unwrap_or("None"),
          )
      }
    }
    _ => fail("expected success outcome")
  }
}

///|
async test "command: list on empty catalog stays registered and reports clearly" {
  let skills = must_skills(FakeFs(), SkillCatalog::empty())
  assert_eq(skills.commands().length(), 1)
  let manifest = skills.manifest()
  assert_eq(manifest.commands.length(), 1)
  assert_eq(manifest.tools.length(), 0)
  match
    skills.invoke(
      "skills",
      Json::object(Map([("action", Json::string("list"))])),
    ) {
    @posoco.CommandOutcome::Success(feedback~, structured~, ..) => {
      assert_eq(feedback, "no skills discovered")
      assert_eq(
        structured,
        Some(
          Json::object(
            Map([
              ("kind", Json::string("skills_catalog")),
              ("skills", Json::array([])),
            ]),
          ),
        ),
      )
    }
    _ => fail("expected success outcome")
  }
}

///|
async test "command: activate returns instructions through the guarded path" {
  let fs = FakeFs()
  fs.add_file(
    "/s/demo/SKILL.md", "---\nname: demo\ndescription: Demo skill\n---\n\nDo the demo.",
  )
  let skills = must_skills(
    fs,
    catalog_of([descriptor("demo", "Demo skill", "/s/demo")]),
  )
  match
    skills.invoke(
      "skills",
      Json::object(
        Map([
          ("action", Json::string("activate")),
          ("name", Json::string("demo")),
        ]),
      ),
    ) {
    @posoco.CommandOutcome::Success(feedback~, structured~, ..) => {
      assert_eq(feedback, "activated skill: demo")
      match structured {
        Some(
          Json::Object(
            {
              "kind": Json::String("agent_skill_activation"),
              "name": Json::String("demo"),
              "instructions": Json::String(text),
              ..
            },
          ),
        ) => assert_true(text.contains("Do the demo."))
        other =>
          fail(
            "unexpected structured payload: " +
            other.map(value => value.stringify()).unwrap_or("None"),
          )
      }
    }
    _ => fail("expected success outcome")
  }
}

///|
async test "command: unknown names and actions fail without raising" {
  let skills = must_skills(
    FakeFs(),
    catalog_of([descriptor("demo", "Demo skill", "/s/demo")]),
  )
  match
    skills.invoke(
      "skills",
      Json::object(
        Map([
          ("action", Json::string("activate")),
          ("name", Json::string("nope")),
        ]),
      ),
    ) {
    @posoco.CommandOutcome::Failure(reason~) =>
      assert_true(reason.contains("Unknown skill"))
    _ => fail("expected failure for unknown skill name")
  }
  match
    skills.invoke(
      "skills",
      Json::object(Map([("action", Json::string(" purge "))])),
    ) {
    @posoco.CommandOutcome::Failure(reason~) =>
      assert_true(reason.contains("unknown action"))
    _ => fail("expected failure for unknown action")
  }
  match
    skills.invoke(
      "skills",
      Json::object(Map([("action", Json::string("activate"))])),
    ) {
    @posoco.CommandOutcome::Failure(reason~) =>
      assert_true(reason.contains("requires a 'name'"))
    _ => fail("expected failure for missing name")
  }
}

///|
async test "command: malformed arguments raise typed InvalidArgs" {
  let skills = must_skills(
    FakeFs(),
    catalog_of([descriptor("demo", "Demo skill", "/s/demo")]),
  )
  try
    skills.invoke("skills", Json::object(Map([("action", Json::number(1.0))])))
  catch {
    @posoco.CommandError::InvalidArgs(_) => ()
    other => fail("expected InvalidArgs, got: \{other}")
  } noraise {
    _ => fail("expected InvalidArgs to raise")
  }
  try skills.invoke("skills", Json::array([])) catch {
    @posoco.CommandError::InvalidArgs(_) => ()
    other => fail("expected InvalidArgs, got: \{other}")
  } noraise {
    _ => fail("expected InvalidArgs to raise")
  }
  try skills.invoke("other", Json::object(Map([]))) catch {
    @posoco.CommandError::NotFound(id) => assert_eq(id, "other")
    other => fail("expected NotFound, got: \{other}")
  } noraise {
    _ => fail("expected NotFound to raise")
  }
}
