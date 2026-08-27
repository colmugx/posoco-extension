///|
test "context_envelope: full attributes match ext-context output" {
  inspect(
    context_envelope(
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
test "context_envelope: omits source attribute when absent" {
  inspect(
    context_envelope(ns="e", kind="t", trust=true, content="c"),
    content="<e-context type=\"t\" trust=\"true\">\nc\n</e-context>",
  )
}

///|
test "context_envelope: escapes source and content" {
  inspect(
    context_envelope(
      ns="e",
      kind="t",
      trust=false,
      source="a\"b&c",
      content="<script>",
    ),
    content="<e-context type=\"t\" trust=\"false\" source=\"a&quot;b&amp;c\">\n&lt;script&gt;\n</e-context>",
  )
}

///|
test "context_envelope: custom attrs render after standard ones, in order" {
  inspect(
    context_envelope(
      ns="goal",
      kind="progress",
      trust=true,
      source="session_1",
      attrs=[("turn", "4/10"), ("tokens", "12.3k/100k")],
      content="NEXT STEP: fix parser",
    ),
    content="<goal-context type=\"progress\" trust=\"true\" source=\"session_1\" turn=\"4/10\" tokens=\"12.3k/100k\">\nNEXT STEP: fix parser\n</goal-context>",
  )
}

///|
test "context_envelope: escapes custom attribute values" {
  inspect(
    context_envelope(
      ns="e",
      kind="t",
      trust=true,
      attrs=[("label", "a\"b<c")],
      content="c",
    ),
    content="<e-context type=\"t\" trust=\"true\" label=\"a&quot;b&lt;c\">\nc\n</e-context>",
  )
}
