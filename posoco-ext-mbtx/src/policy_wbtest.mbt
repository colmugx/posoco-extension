///|
/// Snapshot of the moonrun policy for the default
/// allowlist, the args_prefix omission rule, and the effective-allowlist
/// computation (defaults minus `without`, plus `extra`).

///|
test "build_policy default allowlist snapshot with two write roots" {
  json_inspect(
    build_policy(rules=default_allowlist, write_roots=[
      "/tmp/mbtx-call/build", "/tmp/mbtx-call/run",
    ]),
    content={
      "env": { "from_host": ["*"] },
      "fs": {
        "read": ["*"],
        "write": ["/tmp/mbtx-call/build", "/tmp/mbtx-call/run"],
      },
      "net": {
        "dns": ["*"],
        "connect": ["*:*"],
        "bind": ["127.0.0.1:*", "[::1]:*"],
      },
      "process": {
        "allow": [
          { "program": "moon" },
          { "program": "git" },
          { "program": "gh" },
          { "program": "rg" },
          { "program": "diff" },
        ],
      },
    },
  )
}

///|
test "build_policy omits empty args_prefix and keeps constrained ones" {
  json_inspect(
    build_policy(
      rules=[
        { program: "git", args_prefix: ["status"], },
        { program: "diff", args_prefix: [], },
      ],
      write_roots=[],
    ),
    content={
      "env": { "from_host": ["*"] },
      "fs": { "read": ["*"], "write": [] },
      "net": {
        "dns": ["*"],
        "connect": ["*:*"],
        "bind": ["127.0.0.1:*", "[::1]:*"],
      },
      "process": {
        "allow": [
          { "program": "git", "args_prefix": ["status"] },
          { "program": "diff" },
        ],
      },
    },
  )
}

///|
test "default allowlist is the five documented programs with any arguments" {
  let programs = default_allowlist.map(fn(rule) { rule.program })
  assert_eq(programs, ["moon", "git", "gh", "rg", "diff"])
  for rule in default_allowlist {
    assert_eq(rule.args_prefix.length(), 0)
  }
}

///|
test "allowlist_without removes by program name and allowlist_extra appends" {
  let tools = MbtxTools(allowlist_without=["git"], allowlist_extra=[
    { program: "rtk", args_prefix: ["run"], },
  ])
  let programs = tools.allowlist.map(fn(rule) { rule.program })
  assert_eq(programs, ["moon", "gh", "rg", "diff", "rtk"])
}

///|
test "allowlist without configuration equals the default table" {
  let tools = MbtxTools()
  let programs = tools.allowlist.map(fn(rule) { rule.program })
  assert_eq(programs, ["moon", "git", "gh", "rg", "diff"])
}
