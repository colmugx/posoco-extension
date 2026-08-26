///|
/// Root normalization: empty → ".", trailing "/" dropped (except "/").

///|
test "anchor_normalizes_root" {
  inspect(WorkspaceAnchor::WorkspaceAnchor("").root, content=".")
  inspect(WorkspaceAnchor::WorkspaceAnchor(".").root, content=".")
  inspect(WorkspaceAnchor::WorkspaceAnchor("/").root, content="/")
  inspect(
    WorkspaceAnchor::WorkspaceAnchor("/tmp/proj/").root,
    content="/tmp/proj",
  )
  inspect(
    WorkspaceAnchor::WorkspaceAnchor("/tmp/proj").root,
    content="/tmp/proj",
  )
}

///|
test "resolve_keeps_absolute_paths_asis" {
  let anchor = WorkspaceAnchor::WorkspaceAnchor("/tmp/proj")
  inspect(anchor.resolve("/etc/hosts"), content="/etc/hosts")
  inspect(anchor.resolve("//x//y"), content="//x//y")
}

///|
test "resolve_joins_and_normalizes" {
  let anchor = WorkspaceAnchor::WorkspaceAnchor("/tmp/proj")
  inspect(anchor.resolve("src/main.mbt"), content="/tmp/proj/src/main.mbt")
  inspect(anchor.resolve("./a/../b"), content="/tmp/proj/b")
  inspect(anchor.resolve("a//b"), content="/tmp/proj/a/b")
  inspect(anchor.resolve(""), content="/tmp/proj")
  inspect(anchor.resolve("."), content="/tmp/proj")
}

///|
test "resolve_may_rise_above_root" {
  let anchor = WorkspaceAnchor::WorkspaceAnchor("/tmp/proj")
  inspect(anchor.resolve("../sibling"), content="/tmp/sibling")
  inspect(anchor.resolve("../../.."), content="/")
  let rel = WorkspaceAnchor::WorkspaceAnchor("proj")
  inspect(rel.resolve("../x"), content="x")
  inspect(rel.resolve("../../x"), content="../x")
}
