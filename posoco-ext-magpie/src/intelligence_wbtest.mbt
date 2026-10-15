///|
/// intelligence_wbtest.mbt — deterministic offline tests for the gateway
/// intelligence client. Fixture bodies follow the shapes observed on the
/// real gateway; the fake transport replays them as GET steps.

///|
fn intel_transport(gets~ : Array[FakeStep]) -> FakeTransport {
  FakeTransport(gets)
}

///|
fn intel_client(
  transport~ : &MagpieTransport,
) -> MagpieGatewayIntelligence raise {
  MagpieGatewayIntelligence::MagpieGatewayIntelligence(
    config=local_config(),
    transport~,
  )
}

///|
fn route_body(route : Json?) -> String {
  Json::object({
    "route": match route {
      Some(route) => route
      None => Json::null()
    },
    "seq": Json::number(7),
    "session": Json::string("sess-intel"),
  }).stringify()
}

///|
/// A decided route: group matched, one failed try, then the served member.
fn route_decided() -> Json {
  Json::object({
    "asked": Json::string("group/auto"),
    "group": Json::string("group/auto"),
    "rule": Json::object({
      "name": Json::string("auto"),
      "pick": Json::string("high"),
    }),
    "model": Json::string("codex/gpt-6-luna"),
    "effort": Json::string("high"),
    "served": Json::string("codex/gpt-6-luna"),
    "done": Json::boolean(true),
    "status": Json::number(200),
    "tries": Json::array([
      Json::object({
        "model": Json::string("codex/gpt-6-sol"),
        "effort": Json::string("high"),
        "fail": Json::string("429 window used up"),
      }),
      Json::object({
        "model": Json::string("codex/gpt-6-luna"),
        "effort": Json::string("high"),
      }),
    ]),
  })
}

///|
fn quotas_body() -> String {
  Json::object({
    "data": Json::array([
      Json::object({
        "provider": Json::string("codex"),
        "name": Json::string("Codex"),
        "kind": Json::string("subscription"),
        "plan": Json::string("plus"),
        "user": Json::string("a@example.com"),
        "windows": Json::array([
          Json::object({
            "name": Json::string("5 hours"),
            "used": Json::number(47),
            "remaining": Json::number(53),
            "resetsAt": Json::string("2026-10-15T15:24:39+08:00"),
          }),
          Json::object({
            "name": Json::string("MCP · Month"),
            "used": Json::number(2),
            "remaining": Json::number(98),
            "resetsAt": Json::string("2026-10-28T11:16:00.983Z"),
            "display": Json::string("2 / 100"),
            "amount": Json::number(2),
            "limit": Json::number(100),
          }),
        ]),
        "readAt": Json::string("2026-10-14T23:57:33.447434+08:00"),
        "resets": Json::object({
          "count": Json::number(2),
          "until": Json::string("2026-10-22T21:02:01Z"),
          "each": Json::array([
            Json::object({ "until": Json::string("2026-10-22T21:02:01Z") }),
            Json::object({ "until": Json::string("2026-10-29T18:34:49Z") }),
          ]),
        }),
      }),
      Json::object({
        "provider": Json::string("gemini"),
        "name": Json::string("Gemini CLI"),
        "kind": Json::string("subscription"),
        "user": Json::string("b@example.com"),
        "windows": Json::array([]),
        "error": Json::string("signed out"),
      }),
    ]),
    "object": Json::string("list"),
  }).stringify()
}

///|
fn usage_requests_page(rows : Array[Json]) -> String {
  Json::object({
    "rows": Json::array(rows),
    "offset": Json::number(20),
    "total": Json::number(2),
    "period": Json::string("30d"),
  }).stringify()
}

///|
fn full_usage_row() -> Json {
  Json::object({
    "t": Json::string("2026-10-15T08:00:00Z"),
    "agent": Json::string("pi"),
    "provider": Json::string("codex"),
    "model": Json::string("gpt-6-luna"),
    "served": Json::string("codex/gpt-6-luna"),
    "session": Json::string("sess-row"),
    "in": Json::number(100),
    "out": Json::number(50),
    "cache_read": Json::number(800),
    "cache_write": Json::number(20),
    "cache_write_1h": Json::number(5),
    "reasoning": Json::number(12),
    "cost": Json::number(0.0123),
    "priced": Json::boolean(true),
    "status": Json::number(200),
    "ms": Json::number(2400),
  })
}

///|
async test "a valid route decision decodes with tries and fallbacks" {
  let client = intel_client(
    transport=intel_transport(gets=[
      Respond(code=200, body=route_body(Some(route_decided()))),
    ]),
  )
  let snapshot = client.route_snapshot(query={
    session: "sess-intel",
    after: None,
    wait: None,
  })
  inspect(snapshot.session, content="sess-intel")
  inspect(snapshot.seq == Some(7), content="true")
  guard snapshot.route is Some(route) else { fail("route expected") }
  inspect(route.asked == Some("group/auto"), content="true")
  inspect(route.group == Some("group/auto"), content="true")
  inspect(route.rule_pick == Some("high"), content="true")
  inspect(route.model == Some("codex/gpt-6-luna"), content="true")
  inspect(route.served == Some("codex/gpt-6-luna"), content="true")
  inspect(route.done == Some(true), content="true")
  let tries = route.tries.unwrap()
  inspect(tries.length(), content="2")
  inspect(tries[0].fail == Some("429 window used up"), content="true")
  inspect(tries[1].fail is None, content="true")
}

///|
async test "a routing group resolving to an upstream keeps both identities" {
  let client = intel_client(
    transport=intel_transport(gets=[
      Respond(code=200, body=route_body(Some(route_decided()))),
    ]),
  )
  let snapshot = client.route_snapshot(query={
    session: "g",
    after: None,
    wait: None,
  })
  let route = snapshot.route.unwrap()
  // Group identity and the concrete upstream member travel separately.
  inspect(route.group == Some("group/auto"), content="true")
  inspect(route.model == Some("codex/gpt-6-luna"), content="true")
}

///|
async test "route polls record after and wait, and follow route changes" {
  let decided = route_body(Some(route_decided()))
  let empty = route_body(None)
  let transport = intel_transport(gets=[
    Respond(code=200, body=empty),
    Respond(code=200, body=decided),
  ])
  let client = intel_client(transport~)
  let first = client.route_snapshot(query={
    session: "sess-intel",
    after: None,
    wait: None,
  })
  inspect(first.route is None, content="true")
  let second = client.route_snapshot(query={
    session: "sess-intel",
    after: Some(7),
    wait: Some(30),
  })
  inspect(second.route is Some(_), content="true")
  // The long-poll parameters were encoded into the query.
  inspect(transport.calls[1].contains("after=7"), content="true")
  inspect(transport.calls[1].contains("wait=30"), content="true")
}

///|
async test "nothing is inferred from model identifiers" {
  let client = intel_client(
    transport=intel_transport(gets=[
      Respond(code=200, body=route_body(None)),
      Respond(
        code=200,
        body=route_body(
          Some(
            Json::object({
              "asked": Json::string("weird-no-slash"),
              "group": Json::null(),
              "model": Json::string("group/never-stuck"),
            }),
          ),
        ),
      ),
    ]),
  )
  // No session route yet: the client reports exactly that.
  let empty = client.route_snapshot(query={
    session: "s",
    after: None,
    wait: None,
  })
  inspect(empty.route is None, content="true")
  // An opaque asked id passes through verbatim; the client derives no
  // provider, no protocol, and no group membership from its shape.
  let decided = client.route_snapshot(query={
    session: "s",
    after: None,
    wait: None,
  })
  let route = decided.route.unwrap()
  inspect(route.asked == Some("weird-no-slash"), content="true")
  inspect(route.group is None, content="true")
  inspect(route.model == Some("group/never-stuck"), content="true")
}

///|
async test "quota cards decode windows, resets, plan and read errors" {
  let client = intel_client(
    transport=intel_transport(gets=[Respond(code=200, body=quotas_body())]),
  )
  let snapshot = client.quota_snapshot()
  inspect(snapshot.kept, content="false")
  inspect(snapshot.cards.length(), content="2")
  let codex = snapshot.cards[0]
  inspect(codex.provider, content="codex")
  inspect(codex.plan == Some("plus"), content="true")
  inspect(codex.user == Some("a@example.com"), content="true")
  let windows = codex.windows.unwrap()
  inspect(windows.length(), content="2")
  inspect(windows[0].used == Some(47), content="true")
  inspect(windows[1].limit == Some(100), content="true")
  inspect(windows[1].display == Some("2 / 100"), content="true")
  inspect(codex.resets_count == Some(2), content="true")
  inspect(codex.resets_each_until.unwrap().length(), content="2")
  // A card's own read error is the gateway's message, surfaced verbatim.
  let gemini = snapshot.cards[1]
  inspect(gemini.error == Some("signed out"), content="true")
  inspect(gemini.windows.unwrap().length(), content="0")
}

///|
async test "the gateway key reads its own limit" {
  let client = intel_client(
    transport=intel_transport(gets=[
      Respond(code=200, body="{\"key\":\"k1\",\"limited\":true}"),
    ]),
  )
  let limit = client.key_limit()
  inspect(limit.key == Some("k1"), content="true")
  inspect(limit.limited, content="true")
}

///|
async test "a 403 on quotas is recorded forbidden while inference stays usable" {
  let held = "{\"code\":\"gateway_key_held\"}"
  let transport = FakeTransport(
    [
      Respond(code=200, body=hello_body()),
      Respond(code=200, body=exec_catalog_body()),
      Respond(code=403, body=held),
      Respond(code=200, body=hello_body()),
      Respond(code=200, body=exec_catalog_body()),
    ],
    posts=[
      buffered_post(
        status=200,
        body=messages_nonstream_body(text="still working"),
      ),
    ],
  )
  let manager = manager_with(transport~, config=local_config())
  refresh_ok(manager)
  let client = intel_client(transport=transport_of(manager))
  try client.quota_snapshot() catch {
    @posoco.ModelError::Transport(detail) => {
      inspect(detail.contains("403"), content="true")
      // The documented denial code is quoted; the body never is.
      inspect(detail.contains("gateway_key_held"), content="true")
      inspect(detail.contains("{"), content="false")
    }
    _ => fail("expected Transport")
  } noraise {
    _ => fail("403 must raise")
  }
  inspect(client.service_availability(service=Quotas), content="Forbidden")
  // Inference on the same gateway keeps working end to end.
  refresh_ok(manager)
  let port = select_and_port(manager, "anthropic/claude-native")
  let result = port.chat(
    exec_scope(session="sess-Q"),
    user_text("hi"),
    [],
    chat_options(),
    NoStream,
  )
  inspect(
    result.completion.message.content ==
    [@posoco.Content::Text("still working")],
    content="true",
  )
  // The manager's own availability surface is untouched by the denial.
  inspect(manager.connection_status().connected(), content="true")
}

///|
async test "missing optional usage dimensions stay None" {
  let sparse = Json::object({
    "t": Json::string("2026-10-15T09:00:00Z"),
    "agent": Json::string("pi"),
    "provider": Json::string("relay"),
    "model": Json::string("m"),
    "in": Json::number(3),
    "out": Json::number(1),
  })
  let client = intel_client(
    transport=intel_transport(gets=[
      Respond(code=200, body=usage_requests_page([sparse])),
    ]),
  )
  let page = client.usage_requests()
  inspect(page.rows.length(), content="1")
  let row = page.rows[0]
  inspect(row.cost is None, content="true")
  inspect(row.priced is None, content="true")
  inspect(row.cache_read_tokens is None, content="true")
  inspect(row.duration_ms is None, content="true")
  inspect(row.served is None, content="true")
  inspect(row.input_tokens == Some(3), content="true")
}

///|
async test "cache read and write accounting with kit economics" {
  let client = intel_client(
    transport=intel_transport(gets=[
      Respond(code=200, body=usage_requests_page([full_usage_row()])),
    ]),
  )
  let page = client.usage_requests()
  let row = page.rows[0]
  inspect(row.cache_read_tokens == Some(800), content="true")
  inspect(row.cache_write_tokens == Some(20), content="true")
  inspect(row.reasoning_tokens == Some(12), content="true")
  // Protocol-local economics reuse the messages kit: the caller supplies
  // the rates, nothing is invented.
  let economics = row
    .cache_economics(rates=@messages.MessagesCacheRates::{
      ordinary_input: 3,
      cache_read: 0.3,
      cache_write_5m: 3.75,
      cache_write_1h: 7.5,
    })
    .unwrap()
  inspect(economics.cache_read_tokens == Some(800), content="true")
  inspect(economics.cache_write_tokens == Some(20), content="true")
  inspect(economics.effective_input_cost is Some(_), content="true")
}

///|
async test "reported cost is preserved exactly" {
  let client = intel_client(
    transport=intel_transport(gets=[
      Respond(code=200, body=usage_requests_page([full_usage_row()])),
    ]),
  )
  let row = client.usage_requests().rows[0]
  // The gateway's billed cost is authoritative and passes through
  // bit-for-bit; the priced flag travels with it.
  inspect(row.cost == Some(0.0123), content="true")
  inspect(row.priced == Some(true), content="true")
}

///|
async test "request history pages with offset and limit" {
  let client = intel_client(
    transport=intel_transport(gets=[
      Respond(
        code=200,
        body=usage_requests_page([full_usage_row(), full_usage_row()]),
      ),
    ]),
  )
  let page = client.usage_requests(offset=20, limit=2, period=Some(Month))
  inspect(page.rows.length(), content="2")
  inspect(page.offset == Some(20), content="true")
  inspect(page.total == Some(2), content="true")
  let mut refused = false
  try {
    let _ = client.usage_requests(offset=0, limit=501)
  } catch {
    @posoco.ModelError::RequestBuild(_) => refused = true
    _ => ()
  } noraise {
    _ => ()
  }
  inspect(refused, content="true")
}

///|
async test "concurrent usage requests both decode" {
  let page_body = usage_requests_page([full_usage_row()])
  let client = intel_client(
    transport=intel_transport(gets=[
      Respond(code=200, body=page_body),
      Respond(code=200, body=page_body),
    ]),
  )
  let (first, second) = @async.with_task_group(group => {
    let first = group.spawn(() => client.usage_requests())
    let second = group.spawn(() => client.usage_requests())
    (first, second)
  })
  inspect(first.wait().rows.length(), content="1")
  inspect(second.wait().rows.length(), content="1")
}

///|
async test "concurrency snapshots decode waiting, tools and per-key data" {
  let body = Json::object({
    "requests": Json::array([
      Json::object({
        "model": Json::string("group/auto"),
        "waiting": Json::boolean(true),
      }),
    ]),
    "waiting": Json::number(1),
    "tools": Json::number(2),
    "data": Json::object({
      "codex": Json::number(1),
      "anthropic": Json::number(2),
    }),
  }).stringify()
  let client = intel_client(
    transport=intel_transport(gets=[Respond(code=200, body~)]),
  )
  let snapshot = client.concurrency_snapshot()
  inspect(snapshot.requests.length(), content="1")
  inspect(snapshot.waiting == Some(1), content="true")
  inspect(snapshot.tools == Some(2), content="true")
  let entries = snapshot.data.map(fn(pair) { "\{pair.0}=\{pair.1}" })
  inspect(entries.length(), content="2")
  inspect(entries.contains("anthropic=2"), content="true")
  inspect(entries.contains("codex=1"), content="true")
}

///|
async test "an unsupported endpoint is recorded not-supported" {
  let client = intel_client(
    transport=intel_transport(gets=[Respond(code=404, body="not found")]),
  )
  try client.quota_snapshot() catch {
    @posoco.ModelError::Transport(detail) =>
      inspect(detail.contains("not supported"), content="true")
    _ => fail("expected Transport")
  } noraise {
    _ => fail("404 must raise")
  }
  inspect(client.service_availability(service=Quotas), content="NotSupported")
}

///|
async test "malformed responses are parse errors" {
  let client = intel_client(
    transport=intel_transport(gets=[
      Respond(code=200, body="not json at all"),
      Respond(code=200, body="{\"data\":\"not-an-array\"}"),
      Respond(code=200, body="{\"key\":42,\"limited\":\"yes\"}"),
    ]),
  )
  try client.quota_snapshot() catch {
    @posoco.ModelError::ResponseParse(detail) =>
      inspect(detail.contains("invalid_json"), content="true")
    _ => fail("expected ResponseParse")
  } noraise {
    _ => ()
  }
  try client.quota_snapshot() catch {
    @posoco.ModelError::ResponseParse(detail) =>
      inspect(detail.contains("wrong_type"), content="true")
    _ => fail("expected ResponseParse")
  } noraise {
    _ => ()
  }
  try client.key_limit() catch {
    @posoco.ModelError::ResponseParse(detail) =>
      inspect(detail.contains("limit.limited"), content="true")
    _ => fail("expected ResponseParse")
  } noraise {
    _ => ()
  }
}

///|
async test "sensitive identifiers never reach diagnostics" {
  let marker_session = "sess-SECRET-MARKER"
  let client = intel_client(
    transport=intel_transport(gets=[
      Respond(code=500, body="internal error details"),
    ]),
  )
  try
    client.route_snapshot(query={
      session: marker_session,
      after: None,
      wait: None,
    })
  catch {
    @posoco.ModelError::Transport(detail) => {
      inspect(detail.contains("500"), content="true")
      inspect(detail.contains(marker_session), content="false")
      inspect(detail.contains("internal error details"), content="false")
    }
    _ => fail("expected Transport")
  } noraise {
    _ => ()
  }
}

///|
async test "kept quota answers are marked as cached observations" {
  let transport = intel_transport(gets=[Respond(code=200, body=quotas_body())])
  let client = intel_client(transport~)
  let kept = client.quota_snapshot(kept=true)
  inspect(kept.kept, content="true")
  // Staleness is observable through the card's own read timestamps.
  inspect(
    kept.cards[0].read_at == Some("2026-10-14T23:57:33.447434+08:00"),
    content="true",
  )
  inspect(transport.calls[0].contains("kept=1"), content="true")
}

///|
async test "intelligence queries never mutate selection or session affinity" {
  // Refresh, intel query, refresh again, then chat: one scripted transport.
  let combined = FakeTransport(
    [
      Respond(code=200, body=hello_body()),
      Respond(code=200, body=exec_catalog_body()),
      Respond(code=200, body=route_body(Some(route_decided()))),
      Respond(code=200, body=hello_body()),
      Respond(code=200, body=exec_catalog_body()),
    ],
    posts=[
      buffered_post(status=200, body=messages_nonstream_body(text="answer")),
    ],
  )
  let manager = manager_with(transport=combined, config=local_config())
  refresh_ok(manager)
  let client = intel_client(transport=transport_of(manager))
  let _ = client.route_snapshot(query={
    session: "sess-M",
    after: None,
    wait: None,
  })
  refresh_ok(manager)
  let port = select_and_port(manager, "anthropic/claude-native")
  let _ = port.chat(
    exec_scope(session="sess-M"),
    user_text("hi"),
    [],
    chat_options(),
    NoStream,
  )
  // Selection and session affinity are exactly as the caller set them.
  let selection = manager.active_selection()
  inspect(selection.model_id, content="anthropic/claude-native")
  inspect(selection.pending, content="false")
  inspect(combined.post_sessions[0], content="sess-M")
}

///|
async test "manual quota refresh posts and decodes the refreshed list" {
  let refreshed = FakeTransport([], posts=[
    buffered_post(status=200, body=quotas_body()),
  ])
  let client = intel_client(transport=refreshed)
  let snapshot = client.refresh_quota_cards()
  inspect(snapshot.cards.length(), content="2")
  inspect(snapshot.kept, content="false")
  inspect(
    refreshed.post_calls[0].contains("/v1/magpie/quotas/refresh"),
    content="true",
  )
  inspect(refreshed.post_auths[0], content="Bearer magpie-posoco")
}

 
///|
async test "one-hour cache writes use the actual TTL split" {
  let client = intel_client(
    transport=intel_transport(gets=[
      Respond(code=200, body=usage_requests_page([full_usage_row()])),
    ]),
  )
  let row = client.usage_requests().rows[0]
  inspect(row.cache_write_1h_tokens, content="Some(5)")
  let economics = row.cache_economics(rates=@messages.MessagesCacheRates::{
    ordinary_input: 3,
    cache_read: 0.3,
    cache_write_5m: 3.75,
    cache_write_1h: 7.5,
  }).unwrap()
  // 100 ordinary, 800 cache reads, 15 five-minute, 5 one-hour writes.
  inspect(economics.effective_input_cost, content="Some(633.75)")
}

///|
async test "unknown cache-write TTL distribution cannot claim cost savings" {
  let row = intel_usage_row({
    "in": 100,
    "out": 20,
    "cache_read": 800,
    "cache_write": 20,
  })
  let economics = row.cache_economics(rates=@messages.MessagesCacheRates::{
    ordinary_input: 3,
    cache_read: 0.3,
    cache_write_5m: 3.75,
    cache_write_1h: 7.5,
  }).unwrap()
  inspect(economics.effective_input_cost is None, content="true")
  inspect(economics.net_savings is None, content="true")
}

///|
test "intel_int rejects fractional and overflowing counts" {
  for bad in [Json::number(-1), Json::number(1.5), Json::number(2147483648.0)] {
    let result = Ok(intel_int({ "calls": bad }, "calls", "usage")) catch {
      error => Err(error)
    }
    inspect(result is Err(_), content="true")
  }
}
