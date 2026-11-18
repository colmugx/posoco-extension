///|
/// Typed, injectible cloud API adapter. Retains no browser or CDP state.
pub struct KitesurfTools {
  config : KitesurfConfig
  transport : &KitesurfHttpTransport
}

///|
pub fn KitesurfTools::KitesurfTools(
  config~ : KitesurfConfig,
  transport~ : &KitesurfHttpTransport = DefaultKitesurfTransport::DefaultKitesurfTransport(),
) -> KitesurfTools {
  { config, transport, }
}

///|
/// Cloudflare Browser Run API path, with Kitesurf explicitly selected.
/// No implicit fallback to Chromium is allowed.
fn KitesurfTools::endpoint(self : KitesurfTools, action : String) -> String {
  "https://api.cloudflare.com/client/v4/accounts/" +
  self.config.account_id + "/browser-run/" + action + "?browser=kitesurf"
}

///|
/// Parse the envelope without reflecting an arbitrary Cloudflare error
/// message back into an agent session or logs.
fn decode_cloudflare(
  body : String,
  action : String,
) -> Result[String, String] {
  let parsed = @json.parse(body) catch {
    _ => return Err("kitesurf: invalid JSON response")
  }
  match parsed {
    Object(fields) => {
      if fields.get("success") is not Some(True) {
        return Err("kitesurf: Cloudflare API returned success=false")
      }
      match fields.get("result") {
        Some(String(value)) =>
          if action == "markdown" { Ok(value) } else {
            Err("kitesurf: unexpected text result")
          }
        Some(Object(value)) =>
          if action == "accessibilityTree" {
            match value.get("accessibilityTree") {
              Some(Null) => Err("kitesurf: accessibility tree is empty")
              Some(tree) => Ok(tree.stringify())
              None => Err("kitesurf: response missing accessibilityTree")
            }
          } else {
            Err("kitesurf: unexpected object result")
          }
        _ => Err("kitesurf: response missing result")
      }
    }
    _ => Err("kitesurf: response must be a JSON object")
  }
}

///|
/// Cut at Unicode scalar boundaries, never inside a multibyte character.
fn bounded_text(value : String, cap : Int32) -> (String, Bool) {
  if value.length() <= cap {
    return (value, false)
  }
  let out = StringBuilder()
  let mut used = 0
  for ch in value {
    if used >= cap {
      break
    }
    out.write_char(ch)
    used += 1
  }
  (out.to_string(), true)
}

///|
/// One stateless remote Quick Action. No credentials are returned.
async fn KitesurfTools::quick_action(
  self : KitesurfTools,
  action : String,
  url : String,
) -> Result[(String, Bool), String] {
  match config_error(self.config) {
    Some(error) => return Err(error)
    None => ()
  }
  match target_error(self.config, url) {
    Some(error) => return Err(error)
    None => ()
  }
  let headers : Map[String, String] = Map::from_array([
    ("Authorization", "Bearer " + self.config.api_token),
    ("Content-Type", "application/json"),
  ])
  let request_body = Json::object({ "url": Json::string(url) }).stringify()
  let reply = @async.with_timeout(self.config.timeout_ms, () => {
    self.transport.post(self.endpoint(action), headers, request_body)
  }) catch {
    @async.TimeoutError => return Err("kitesurf: request timed out")
    _ => return Err("kitesurf: HTTP transport failed")
  }
  if reply.status < 200 || reply.status >= 300 {
    return Err("kitesurf: Cloudflare HTTP " + reply.status.to_string())
  }
  match decode_cloudflare(reply.body, action) {
    Ok(content) => Ok(bounded_text(content, self.config.max_output_chars))
    Err(error) => Err(error)
  }
}
