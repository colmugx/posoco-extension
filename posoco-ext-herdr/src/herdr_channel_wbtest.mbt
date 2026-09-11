///|
test "channel argv builders produce the herdr verb shapes" {
  assert_eq(herdr_split_argv("herdr", "1-1", "/tmp/ws", "right"), [
    "herdr", "pane", "split", "--pane", "1-1", "--direction", "right", "--cwd", "/tmp/ws",
    "--no-focus",
  ])
  assert_eq(herdr_split_argv("herdr", "1-1", "/tmp/ws", "down"), [
    "herdr", "pane", "split", "--pane", "1-1", "--direction", "down", "--cwd", "/tmp/ws",
    "--no-focus",
  ])
  assert_eq(herdr_run_argv("herdr", "1-2", "cetas-headless -- 'do it'"), [
    "herdr", "pane", "run", "1-2", "cetas-headless -- 'do it'",
  ])
  assert_eq(herdr_wait_argv("herdr", "1-2", 5000), [
    "herdr", "pane", "wait-output", "--match", "[cetas-headless] turn 1 done", "--timeout",
    "5000", "1-2",
  ])
  assert_eq(herdr_read_argv("herdr", "1-2"), [
    "herdr", "pane", "read", "1-2", "--source", "recent-unwrapped",
  ])
  assert_eq(herdr_close_argv("herdr", "1-3"), ["herdr", "pane", "close", "1-3"])
}

///|
test "split pane id parses from result.pane.pane_id; errors and garbage yield None" {
  inspect(
    parse_split_pane_id("{\"result\":{\"pane\":{\"pane_id\":\"1-3\"}}}")
    is Some("1-3"),
    content="true",
  )
  inspect(
    parse_split_pane_id("{\"error\":{\"code\":\"boom\",\"message\":\"nope\"}}")
    is None,
    content="true",
  )
  inspect(parse_split_pane_id("not json") is None, content="true")
  inspect(parse_split_pane_id("") is None, content="true")
  inspect(
    parse_split_pane_id("{\"result\":{\"pane\":{\"pane_id\":3}}}") is None,
    content="true",
  )
}

///|
test "headless command line maps permission and forwards optional flags" {
  inspect(
    headless_command_line(
      "cetas-headless",
      "readonly",
      None,
      None,
      None,
      "the task",
    ),
    content="cetas-headless --permission readonly -- 'the task'",
  )
  inspect(
    headless_command_line(
      "cetas-headless",
      "write",
      Some("kimi-k2"),
      Some("high"),
      Some("sess-9"),
      "the task",
    ),
    content="cetas-headless --yolo --model kimi-k2 --effort high --session sess-9 -- 'the task'",
  )
  inspect(
    headless_command_line(
      "cetas-headless",
      "readonly",
      None,
      None,
      None,
      "it's",
    ),
    content="cetas-headless --permission readonly -- 'it'\\''s'",
  )
}

///|
test "parse_pane_text: session line bounds the answer, marker is stripped" {
  let pane = parse_pane_text(
    "session: sess-7\nheadless answer body\n[cetas-headless] turn 1 done\n",
  )
  assert_eq(pane.answer, "headless answer body")
  assert_eq(pane.child_session, Some("sess-7"))
  assert_eq(pane.failure, None)
}

///|
test "parse_pane_text: failure line replaces the answer block" {
  let pane = parse_pane_text(
    "session: s1\n[cetas-headless] turn failed: model exploded\n[cetas-headless] turn 1 done\n",
  )
  assert_eq(pane.answer, "")
  assert_eq(pane.child_session, Some("s1"))
  assert_eq(pane.failure, Some("model exploded"))
}

///|
test "parse_pane_text: prompt redraw after the marker is dropped" {
  let pane = parse_pane_text(
    "session: cetas-1789036261302\npong\n[cetas-headless] turn 1 done\n\n/private/tmp via C v17.0.0-clang via  v24.15.7 took 7s\n❯\n",
  )
  assert_eq(pane.answer, "pong")
  assert_eq(pane.child_session, Some("cetas-1789036261302"))
  assert_eq(pane.failure, None)
}

///|
test "parse_pane_text: no session line falls back to the whole screen" {
  let pane = parse_pane_text(
    "preamble\nanswer body\n[cetas-headless] turn 1 done\n",
  )
  assert_eq(pane.answer, "preamble\nanswer body")
  assert_eq(pane.child_session, None)
  assert_eq(pane.failure, None)
}

///|
test "parse_pane_text: empty screen parses to empty result" {
  let pane = parse_pane_text("")
  assert_eq(pane.answer, "")
  assert_eq(pane.child_session, None)
  assert_eq(pane.failure, None)
}

///|
test "timeout error needs exit 1 and the timeout code envelope" {
  assert_true(is_timeout_error(1, "{\"error\":{\"code\":\"timeout\"}}"))
  assert_false(is_timeout_error(0, "{\"error\":{\"code\":\"timeout\"}}"))
  assert_false(is_timeout_error(1, "{\"error\":{\"code\":\"boom\"}}"))
  assert_false(is_timeout_error(1, ""))
}
