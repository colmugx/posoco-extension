///|
test "render_context_envelope: full attributes match ext-context output" {
  inspect(
    render_context_envelope(
      envelope="cetas-context",
      kind="project_instructions",
      trust=false,
      source="/repo/AGENTS.md",
      content="Build with: moon test",
    ),
    content="<cetas-context type=\"project_instructions\" trust=\"false\" source=\"/repo/AGENTS.md\">\nBuild with: moon test\n</cetas-context>",
  )
}

///|
test "render_context_envelope: omits source attribute when absent" {
  inspect(
    render_context_envelope(envelope="e", kind="t", trust=true, content="c"),
    content="<e type=\"t\" trust=\"true\">\nc\n</e>",
  )
}

///|
test "render_context_envelope: escapes source and content" {
  let rendered = render_context_envelope(
    envelope="e",
    kind="t",
    trust=false,
    source="/p?a=<x>",
    content="<tag> & \"q\" 'a'",
  )
  assert_true(rendered.contains("source=\"/p?a=&lt;x&gt;\""))
  assert_true(
    rendered.contains("&lt;tag&gt; &amp; &quot;q&quot; &apos;a&apos;"),
  )
}
