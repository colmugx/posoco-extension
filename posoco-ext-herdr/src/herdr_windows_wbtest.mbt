///|
// The Win32 native shim takes argv elements, not an interpolated shell string.
test "native reporter argv encoding preserves metacharacters and spaces" {
  let payload = herdr_report_argv_payload(
    "C:\\Program Files\\herdr.exe",
    ["pane", "report-agent", "--message", "hi \" & whoami"],
  )
  assert_eq(
    payload,
    "C:\\Program Files\\herdr.exe\u{0}pane\u{0}report-agent\u{0}--message\u{0}hi \" & whoami\u{0}\u{0}",
  )
}

///|
test "native reporter argv encoding neutralizes embedded NUL" {
  let payload = herdr_report_argv_payload("herdr", ["--message", "a\u{0}b"])
  assert_eq(payload, "herdr\u{0}--message\u{0}a b\u{0}\u{0}")
}
