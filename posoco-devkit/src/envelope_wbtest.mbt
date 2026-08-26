///|
test "render_context_envelope: full attributes match ext-context output" {
  inspect(
    render_context_envelope(
      ns="cetas",
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
    render_context_envelope(ns="e", kind="t", trust=true, content="c"),
    content="<e-context type=\"t\" trust=\"true\">\nc\n</e-context>",
  )
}

///|
test "render_context_envelope: escapes source and content" {
  inspect(
    render_context_envelope(
      ns="e",
      kind="t",
      trust=false,
      source="a\"b&c",
      content="<script>",
    ),
    content="<e-context type=\"t\" trust=\"false\" source=\"a&quot;b&amp;c\">\n&lt;script&gt;\n</e-context>",
  )
}
