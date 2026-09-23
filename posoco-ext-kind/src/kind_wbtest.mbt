///|
/// Parse expecting failure; returns the rejection reason.
fn kind_parse_error(source : String) -> String raise {
  let outcome : Result[KindSpec, KindError] = Ok(parse_kind_file(source)) catch {
    error => Err(error)
  }
  match outcome {
    Err(KindError::InvalidKindFile(reason)) => reason
    _ => fail("expected the kind file to be rejected")
  }
}

///|
test "parse_kind_file_all_fields_comma_list" {
  let source = "---\n" +
    "name: fix\n" +
    "description: Tight-scope fixer\n" +
    "tools: read, edit , bash\n" +
    "model: zai/glm-5.3\n" +
    "skills: repo-map, tree\n" +
    "mode: yolo\n" +
    "unknown_key: ignored\n" +
    "---\n" +
    "Body line one.\n" +
    "Body line two.\n"
  let spec = parse_kind_file(source)
  assert_eq(spec.name, "fix")
  assert_eq(spec.description, "Tight-scope fixer")
  assert_eq(spec.tools, ["read", "edit", "bash"])
  assert_eq(spec.model, Some("zai/glm-5.3"))
  assert_eq(spec.skills, Some(["repo-map", "tree"]))
  assert_true(spec.mode is @permission.PermissionMode::Yolo)
  assert_true(spec.body.contains("Body line one."))
  assert_true(spec.body.contains("Body line two."))
  assert_false(spec.body.contains("unknown_key"))
}

///|
test "parse_kind_file_dash_lists" {
  let source = "---\n" +
    "name: scout\n" +
    "description: Read-only scout\n" +
    "tools:\n" +
    "  - read\n" +
    "  - glob\n" +
    "  - grep\n" +
    "skills:\n" +
    "  - repo-map\n" +
    "---\n" +
    "Body"
  let spec = parse_kind_file(source)
  assert_eq(spec.tools, ["read", "glob", "grep"])
  assert_eq(spec.skills, Some(["repo-map"]))
}

///|
test "parse_kind_file_defaults" {
  let spec = parse_kind_file(
    "---\nname: plain\ndescription: Bare kind\n---\nBody with {{instructions}}",
  )
  assert_eq(spec.tools, [])
  assert_eq(spec.model, None)
  assert_eq(spec.skills, None)
  assert_true(spec.mode is @permission.PermissionMode::WorkspaceWrite)
  assert_true(spec.body.contains("{{instructions}}"))
}

///|
test "parse_kind_file_empty_tools_list_is_legal" {
  let spec = parse_kind_file(
    "---\nname: bare\ndescription: No tools\ntools: []\n---\nBody",
  )
  assert_eq(spec.tools, [])
}

///|
test "parse_kind_file_rejects_missing_name" {
  assert_true(
    kind_parse_error("---\ndescription: No name\n---\nBody").contains("name"),
  )
}

///|
test "parse_kind_file_rejects_blank_name" {
  assert_true(
    kind_parse_error("---\nname: \"  \"\ndescription: Blank\n---\nBody").contains(
      "name",
    ),
  )
}

///|
test "parse_kind_file_rejects_missing_description" {
  assert_true(
    kind_parse_error("---\nname: x\n---\nBody").contains("description"),
  )
}

///|
test "parse_kind_file_rejects_unknown_mode" {
  assert_true(
    kind_parse_error("---\nname: x\ndescription: y\nmode: hyper\n---\nB").contains(
      "mode",
    ),
  )
}

///|
test "parse_kind_file_rejects_non_string_mode" {
  assert_true(
    kind_parse_error("---\nname: x\ndescription: y\nmode: [readonly]\n---\nB").contains(
      "mode",
    ),
  )
}

///|
test "parse_kind_file_rejects_malformed_list" {
  assert_true(
    kind_parse_error(
      "---\nname: x\ndescription: y\ntools:\n  - read\n  - 3\n---\nB",
    ).contains("tools"),
  )
}

///|
test "parse_kind_file_rejects_unterminated_frontmatter" {
  assert_true(
    kind_parse_error("---\nname: x\ndescription: y\nBody").contains(
      "frontmatter",
    ),
  )
}

///|
test "parse_kind_file_rejects_non_mapping_frontmatter" {
  assert_true(
    kind_parse_error("---\njust a string\n---\nBody").contains("frontmatter"),
  )
}

///|
test "render_kind_body_substitutes_repeated_placeholders" {
  let out = render_kind_body("A {{x}} B {{x}} C {{y}}", [("x", "1")])
  assert_eq(out, "A 1 B 1 C {{y}}")
}

///|
test "render_kind_body_empty_bindings_returns_body_unchanged" {
  let body = "keep {{k}} as-is"
  assert_eq(render_kind_body(body, []), body)
}

///|
test "render_kind_body_multiple_bindings" {
  let out = render_kind_body("{{a}} and {{b}}", [("a", "A"), ("b", "B")])
  assert_eq(out, "A and B")
}

///|
test "builtin_catalog_kinds" {
  let cat = KindCatalog::builtin()
  assert_eq(cat.names(), ["coder", "oracle", "reviewer", "scout"])
  assert_eq(cat.diagnostics(), [])
  for name in cat.names() {
    match cat.get(name) {
      Some(spec) => {
        assert_false(spec.description.is_empty())
        assert_true(spec.body.contains("{{instructions}}"))
        assert_true(spec.body.contains("<fillin>"))
      }
      None => fail("missing builtin kind " + name)
    }
  }
}

///|
test "builtin_coder_is_the_default_face" {
  let cat = KindCatalog::builtin()
  match cat.get("coder") {
    Some(coder) => {
      assert_true(coder.mode is @permission.PermissionMode::WorkspaceWrite)
      assert_eq(coder.tools, ["read", "write", "edit", "glob", "grep", "bash"])
      assert_eq(coder.model, None)
      assert_eq(coder.skills, None)
    }
    None => fail("builtin coder missing")
  }
}

///|
test "builtin_readonly_kinds" {
  let cat = KindCatalog::builtin()
  for name in ["scout", "reviewer", "oracle"] {
    match cat.get(name) {
      Some(spec) =>
        assert_true(spec.mode is @permission.PermissionMode::ReadOnly)
      None => fail("missing builtin kind " + name)
    }
  }
  match cat.get("scout") {
    Some(scout) => assert_eq(scout.tools, ["read", "glob", "grep"])
    None => fail("missing scout")
  }
  match cat.get("oracle") {
    Some(oracle) => assert_eq(oracle.tools, [])
    None => fail("missing oracle")
  }
  assert_true(cat.get("nope") is None)
}

///|
test "with_entries_roundtrip_and_duplicate_rejection" {
  let spec = parse_kind_file("---\nname: custom\ndescription: Mine\n---\nBody")
  let cat = KindCatalog::with_entries([spec])
  assert_eq(cat.names(), ["custom"])
  match cat.get("custom") {
    Some(found) => assert_eq(found.description, "Mine")
    None => fail("expected custom kind")
  }
  let outcome : Result[KindCatalog, KindError] = Ok(
    KindCatalog::with_entries([spec, spec]),
  ) catch {
    error => Err(error)
  }
  match outcome {
    Err(KindError::DuplicateKind(_)) => ()
    _ => fail("expected duplicate kind rejection")
  }
}

// ──────────────────────────────────────────────────────────────────────────
// On-disk loading (native fs)
// ──────────────────────────────────────────────────────────────────────────

///|
#cfg(target="native")
async test "load_project_overrides_global_and_skips_bad_files" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="posoco-kind-load")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(root, recursive=true))
    }
    let global_dir = root + "/home/.cetas/agents"
    let project_dir = root + "/cwd/.cetas/agents"
    @fs.mkdir(global_dir, recursive=true)
    @fs.mkdir(project_dir, recursive=true)
    // Global override of builtin coder.
    @fs.write_file(
      global_dir + "/coder.md",
      "---\nname: coder\ndescription: Global coder\ntools: read\n---\nGLOBAL {{instructions}}",
      create_mode=CreateNew,
    )
    // Project override wins over global for the same kind name...
    @fs.write_file(
      project_dir + "/coder.md",
      "---\nname: coder\ndescription: Project coder\nmode: readonly\ntools: read, glob\n---\nPROJECT {{instructions}}",
      create_mode=CreateNew,
    )
    // ...and adds a brand-new kind.
    @fs.write_file(
      project_dir + "/scout.md",
      "---\nname: scout\ndescription: Project scout\ntools:\n  - read\n---\nSCOUT {{instructions}}",
      create_mode=CreateNew,
    )
    // Broken frontmatter is skipped with a diagnostic, not fatal.
    @fs.write_file(
      project_dir + "/broken.md",
      "---\nname: broken\ndescription: x\nmode: hyper\n---\nB",
      create_mode=CreateNew,
    )
    // Non-md files are ignored silently.
    @fs.write_file(
      project_dir + "/README.txt",
      "ignore me",
      create_mode=CreateNew,
    )
    let cat = KindCatalog::load(home=root + "/home", cwd=root + "/cwd")
    match cat.get("coder") {
      Some(coder) => {
        assert_eq(coder.description, "Project coder")
        assert_true(coder.mode is @permission.PermissionMode::ReadOnly)
        assert_eq(coder.tools, ["read", "glob"])
        assert_true(coder.body.contains("PROJECT"))
      }
      None => fail("expected project coder override")
    }
    match cat.get("scout") {
      Some(scout) => assert_eq(scout.description, "Project scout")
      None => fail("expected project scout")
    }
    // Builtin-only kinds survive alongside overlays.
    match cat.get("oracle") {
      Some(_) => ()
      None => fail("expected builtin oracle to survive")
    }
    let diags = cat.diagnostics()
    assert_eq(diags.length(), 1)
    assert_true(diags[0].contains("broken.md"))
  }
}

///|
#cfg(target="native")
async test "load_without_directories_returns_clean_builtin" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="posoco-kind-empty")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(root, recursive=true))
    }
    let cat = KindCatalog::load(home=root, cwd=root + "/nowhere")
    assert_eq(cat.names(), ["coder", "oracle", "reviewer", "scout"])
    assert_eq(cat.diagnostics(), [])
  }
}

///|
#cfg(target="native")
async test "load_rejects_name_stem_mismatch_with_diagnostic" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="posoco-kind-mismatch")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(root, recursive=true))
    }
    let agents = root + "/.cetas/agents"
    @fs.mkdir(agents, recursive=true)
    @fs.write_file(
      agents + "/renamed.md",
      "---\nname: coder\ndescription: Mismatched\n---\nBODY",
      create_mode=CreateNew,
    )
    let cat = KindCatalog::load(home=root, cwd=root + "/project")
    assert_eq(cat.diagnostics().length(), 1)
    // The builtin coder was not displaced by the mismatched file.
    match cat.get("coder") {
      Some(coder) => assert_false(coder.body.contains("BODY"))
      None => fail("expected builtin coder to survive")
    }
  }
}

///|
#cfg(target="native")
async test "load_global_directory_alone_overrides_builtin" {
  @async.with_task_group() <| group => {
    let root = @fs.tmpdir(prefix="posoco-kind-global")
    group.add_defer() <| () => {
      @async.protect_from_cancel(() => @fs.rmdir(root, recursive=true))
    }
    let global_dir = root + "/.cetas/agents"
    @fs.mkdir(global_dir, recursive=true)
    @fs.write_file(
      global_dir + "/oracle.md",
      "---\nname: oracle\ndescription: House oracle\ntools:\n  - read\nmode: interactive\n---\nHOUSE {{instructions}}",
      create_mode=CreateNew,
    )
    let cat = KindCatalog::load(home=root, cwd=root + "/project")
    match cat.get("oracle") {
      Some(oracle) => {
        assert_eq(oracle.description, "House oracle")
        assert_true(oracle.mode is @permission.PermissionMode::Interactive)
        assert_eq(oracle.tools, ["read"])
        assert_true(oracle.body.contains("HOUSE"))
      }
      None => fail("expected global oracle override")
    }
    assert_eq(cat.diagnostics(), [])
  }
}
