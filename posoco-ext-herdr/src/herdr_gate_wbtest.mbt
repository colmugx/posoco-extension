///|
/// Native+js only, like `herdr_gate`.
fn gate_summary(marker : String?, pane : String?, bin : String?) -> String {
  match herdr_gate(marker, pane, bin) {
    Some(cfg) => "open(\{cfg.pane}, \{cfg.bin})"
    None => "closed"
  }
}

///|
test "presence gate: marker+pane required, blank counts as missing, bin defaults" {
  inspect(
    gate_summary(Some("dev"), Some("1-2"), None),
    content="open(1-2, herdr)",
  )
  inspect(
    gate_summary(Some("dev"), Some("1-2"), Some("/opt/herdr")),
    content="open(1-2, /opt/herdr)",
  )
  inspect(gate_summary(None, Some("1-2"), None), content="closed")
  inspect(gate_summary(Some(""), Some("1-2"), None), content="closed")
  inspect(gate_summary(Some("dev"), Some(""), None), content="closed")
  inspect(
    gate_summary(Some("dev"), Some("1-2"), Some("")),
    content="open(1-2, herdr)",
  )
  inspect(gate_summary(None, None, None), content="closed")
}
