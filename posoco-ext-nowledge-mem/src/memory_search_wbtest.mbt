///|
test "search_reply_text: renders results items as id-prefixed lines" {
  debug_inspect(
    search_reply_text(
      "{\"results\":[{\"id\":\"m1\",\"content\":\"first\"},{\"id\":\"m2\",\"content\":\"second\"}],\"total\":2}",
    ),
    content=(
      #|Some("- [m1] first\n- [m2] second")
    ),
  )
}

///|
test "search_reply_text: omits the id prefix when the server gives none" {
  debug_inspect(
    search_reply_text("{\"results\":[{\"content\":\"only content\"}]}"),
    content=(
      #|Some("- only content")
    ),
  )
}

///|
test "search_reply_text: truncated preview points at its reference_uri" {
  debug_inspect(
    search_reply_text(
      "{\"results\":[{\"id\":\"m1\",\"content\":\"cut short\",\"content_truncated\":true,\"reference_uri\":\"nowledgemem://memory/m1\"}]}",
    ),
    content=(
      #|Some("- [m1] cut short …[full: nowledgemem://memory/m1]")
    ),
  )
  // Truncation without a reference_uri keeps the plain line.
  debug_inspect(
    search_reply_text(
      "{\"results\":[{\"content\":\"cut short\",\"content_truncated\":true}]}",
    ),
    content=(
      #|Some("- cut short")
    ),
  )
}

///|
test "search_reply_text: empty or non-array results is a clean miss" {
  debug_inspect(
    search_reply_text("{\"results\":[],\"total\":0}"),
    content=(
      #|None
    ),
  )
  debug_inspect(
    search_reply_text("{\"total\":0}"),
    content=(
      #|None
    ),
  )
  // Only usable items count: all-unusable renders as a miss too.
  debug_inspect(
    search_reply_text(
      "{\"results\":[{\"id\":\"m1\"},{\"title\":\"no content\"}]}",
    ),
    content=(
      #|None
    ),
  )
}

///|
test "search_reply_text: the REST memories key is not the MCP contract" {
  // The REST search endpoint uses \"memories\"; the MCP memory_search tool
  // this port calls replies with \"results\". Accepting the REST shape here
  // once masked a server-side contract change as clean misses.
  debug_inspect(
    search_reply_text("{\"memories\":[{\"id\":\"m1\",\"content\":\"hit\"}]}"),
    content=(
      #|None
    ),
  )
}

///|
test "search_reply_text: non-JSON degrades to trimmed raw text" {
  debug_inspect(
    search_reply_text("  plain text  "),
    content=(
      #|Some("plain text")
    ),
  )
  debug_inspect(
    search_reply_text("   "),
    content=(
      #|None
    ),
  )
}
