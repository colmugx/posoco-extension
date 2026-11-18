///|
/// Fake HTTP transport records requests and returns a controlled JSON envelope.
struct FakeKitesurfTransport {
  mut url : String
  mut auth : String
  mut body : String
  status : Int32
  reply : String
}

///|
impl KitesurfHttpTransport for FakeKitesurfTransport with fn post(
  self : FakeKitesurfTransport,
  url : String,
  headers : Map[String, String],
  body : String,
) -> KitesurfHttpResponse raise @posoco.RuntimeError {
  self.url = url
  self.auth = headers.get("Authorization").unwrap_or("")
  self.body = body
  { status: self.status, body: self.reply, }
}

///|
fn fake_config() -> KitesurfConfig {
  KitesurfConfig::KitesurfConfig(
    account_id="0123456789abcdef0123456789abcdef",
    api_token="do-not-log-this-secret",
    allowed_hosts=["example.com"],
  )
}

///|
test "kitesurf tool catalog has exactly two browser tools" {
  let tools = KitesurfTools::KitesurfTools(config=fake_config())
  let defs = tools.list_tools()
  assert_eq(defs.length(), 2)
  assert_eq(defs[0].name.to_string(), "kitesurf_markdown")
  assert_eq(defs[1].name.to_string(), "kitesurf_accessibility_tree")
  assert_eq(tools.extension_id(), "posoco_ext_kitesurf")
}

///|
test "Kitesurf endpoint pins browser=kitesurf" {
  let tools = KitesurfTools::KitesurfTools(config=fake_config())
  inspect(
    tools.endpoint("markdown"),
    content="https://api.cloudflare.com/client/v4/accounts/0123456789abcdef0123456789abcdef/browser-run/markdown?browser=kitesurf",
  )
}

///|
test "invalid URL and configuration fail closed" {
  let config = fake_config()
  assert_true(target_error(config, "file:///etc/passwd") is Some(_))
  assert_true(target_error(config, "http://127.0.0.1/") is Some(_))
  assert_true(target_error(config, "https://evil.example/") is Some(_))
  assert_true(target_error(config, "https://user:pass@example.com/") is Some(_))
  assert_true(target_error(config, "https://example.com/") is None)
}

///|
test "cloudflare markdown and tree envelopes are decoded" {
  inspect(
    decode_cloudflare("{\"success\":true,\"result\":\"# Example\"}", "markdown"),
    content="Ok(\"# Example\")",
  )
  inspect(
    decode_cloudflare(
      "{\"success\":true,\"result\":{\"accessibilityTree\":{\"role\":\"RootWebArea\"}}}",
      "accessibilityTree",
    ),
    content="Ok(\"{\\\"role\\\":\\\"RootWebArea\\\"}\")",
  )
  assert_true(
    decode_cloudflare("{\"success\":false,\"errors\":[{\"message\":\"sensitive\"}]}", "markdown") is Err(_),
  )
}

///|
test "unicode output is not split mid-scalar" {
  inspect(bounded_text("你好世界", 2), content="(\"你好\", true)")
}

///|
async test "quick action emits remote request and sanitizes error" {
  let fake = FakeKitesurfTransport::{
    url: "",
    auth: "",
    body: "",
    status: 200,
    reply: "{\"success\":true,\"result\":\"# Example\"}",
  }
  let tools = KitesurfTools::KitesurfTools(config=fake_config(), transport=fake)
  let result = tools.quick_action("markdown", "https://example.com/")
  match result {
    Ok((content, truncated)) => {
      assert_eq(content, "# Example")
      assert_false(truncated)
    }
    Err(error) => fail(error)
  }
  assert_true(fake.url.has_suffix("/markdown?browser=kitesurf"))
  assert_eq(fake.auth, "Bearer do-not-log-this-secret")
  assert_true(fake.body.contains("https://example.com/"))
}
