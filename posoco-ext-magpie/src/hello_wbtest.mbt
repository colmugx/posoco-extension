///|
/// hello_wbtest.mbt — `/api/hello` identity validation
/// (scenarios 1: valid hello; 3: wrong service identity).

///|
test "valid hello payload parses identity and version" {
  let identity = parse_hello("{\"name\":\"magpie\",\"version\":\"0.1.1224\"}")
  inspect(identity.name, content="magpie")
  debug_inspect(identity.version, content="Some(\"0.1.1224\")")
  // Version is optional.
  let minimal = parse_hello("{\"name\":\"magpie\"}")
  debug_inspect(minimal.version, content="None")
}

///|
test "a non-magpie identity is rejected as WrongIdentity" {
  try parse_hello("{\"name\":\"llamacpp\",\"version\":\"1.0\"}") catch {
    MagpieGatewayError::WrongIdentity(detail) =>
      inspect(detail.contains("llamacpp"), content="true")
    _ => fail("expected WrongIdentity")
  } noraise {
    _ => fail("expected WrongIdentity")
  }
}

///|
test "malformed hello payloads are InvalidResponse" {
  for
    body in [
      "not json", "[]", "{\"version\":\"0.1\"}", "{\"name\":42}", "{\"name\":\"magpie\",\"version\":7}",
    ] {
    try parse_hello(body) catch {
      MagpieGatewayError::InvalidResponse(_) => ()
      _ => fail("expected InvalidResponse for \{body}")
    } noraise {
      _ => fail("expected InvalidResponse for \{body}")
    }
  }
}
