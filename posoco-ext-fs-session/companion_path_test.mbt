///|
test "companion_path puts a file beside the JSONL history" {
  inspect(
    @posoco-ext-fs-session.companion_path(
      "/cetas-home/.cetas/sessions", "cetas-1",
    ),
    content="/cetas-home/.cetas/sessions/cetas-1.host.json",
  )
}

///|
test "companion_path accepts a custom extension" {
  inspect(
    @posoco-ext-fs-session.companion_path("/root", "cetas-2", ext="wire.jsonl"),
    content="/root/cetas-2.wire.jsonl",
  )
}

///|
test "companion_path mirrors jsonl_session_path's directory and stem" {
  let root = "/cetas-home/.cetas/sessions"
  let jsonl = @posoco-ext-fs-session.jsonl_session_path(root, "cetas-3")
  let companion = @posoco-ext-fs-session.companion_path(root, "cetas-3")
  inspect(
    companion[:companion.length() - ".host.json".length()].to_owned(),
    content=jsonl[:jsonl.length() - ".jsonl".length()].to_owned(),
  )
}
