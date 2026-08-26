///|

// parent_dir (pure)

///|
test "parent_dir: root has no parent" {
  assert_eq(parent_dir("/"), None)
}

///|
test "parent_dir: single segment" {
  assert_eq(parent_dir("/foo"), Some("/"))
}

///|
test "parent_dir: nested path" {
  assert_eq(parent_dir("/a/b/c"), Some("/a/b"))
}

///|
test "parent_dir: strips trailing slash" {
  assert_eq(parent_dir("/a/b/"), Some("/a"))
}

// ContextPromptContributor: namespace rendering (pure)

///|
test "system_prompt: empty bundle renders nothing" {
  let bundle = ContextBundle::empty()
  let c = ContextPromptContributor(bundle~, ns="posoco")
  assert_eq(c.system_prompt(), "")
}

///|
test "system_prompt: renders caller-selected namespace with attributes" {
  let bundle : ContextBundle = {
    global: None,
    ancestors: [{ path: "/repo/AGENTS.md", content: "build: make test" }],
    warnings: [],
  }
  let c = ContextPromptContributor(bundle~, ns="posoco")
  let rendered = c.system_prompt()
  assert_true(rendered.contains("<posoco-context "))
  assert_true(rendered.contains("type=\"project_instructions\""))
  assert_true(rendered.contains("trust=\"false\""))
  assert_true(rendered.contains("source=\"/repo/AGENTS.md\""))
  assert_true(rendered.contains("build: make test"))
  assert_true(rendered.contains("</posoco-context>"))
}

///|
test "system_prompt: namespace is not hardcoded" {
  let bundle : ContextBundle = {
    global: None,
    ancestors: [{ path: "/repo/AGENTS.md", content: "repo" }],
    warnings: [],
  }
  let c = ContextPromptContributor(bundle~, ns="example")
  let rendered = c.system_prompt()
  assert_true(rendered.contains("<example-context "))
  assert_true(rendered.contains("</example-context>"))
  assert_false(rendered.contains("<posoco-context"))
}

///|
test "system_prompt: multiple documents render as parallel elements" {
  let bundle : ContextBundle = {
    global: Some({ path: "/home/.cetas/agent/AGENTS.md", content: "global" }),
    ancestors: [
      { path: "/repo/AGENTS.md", content: "repo" },
      { path: "/repo/sub/AGENTS.md", content: "sub" },
    ],
    warnings: [],
  }
  let c = ContextPromptContributor(bundle~, ns="posoco")
  let rendered = c.system_prompt()
  let parts = rendered.split("<posoco-context ")
  assert_eq(parts.length() - 1, 3)
  let global_pos = match rendered.find("<posoco-context ") {
    Some(i) => i
    None => -1
  }
  let repo_pos = match rendered.find("source=\"/repo/AGENTS.md\"") {
    Some(i) => i
    None => -1
  }
  assert_true(global_pos >= 0)
  assert_true(repo_pos > global_pos)
}

///|
test "system_prompt: xml-escapes special characters in content" {
  let bundle : ContextBundle = {
    global: None,
    ancestors: [
      { path: "/repo/AGENTS.md", content: "use <tag> & \"quotes\" for 'attrs'" },
    ],
    warnings: [],
  }
  let c = ContextPromptContributor(bundle~, ns="posoco")
  let rendered = c.system_prompt()
  assert_true(rendered.contains("&lt;tag&gt;"))
  assert_true(rendered.contains("&amp;"))
  assert_true(rendered.contains("&quot;quotes&quot;"))
  assert_true(rendered.contains("&apos;attrs&apos;"))
  assert_false(rendered.contains("<tag>"))
}
