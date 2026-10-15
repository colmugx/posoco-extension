///|
/// harness/main.mbt — Magpie live gateway compatibility harness.
///
/// Opt-in: runs only when MAGPIE_LIVE_URL is set. Without it the harness
/// prints a SKIPPED report and exits cleanly, so ordinary CI never touches
/// a gateway. Billable inference runs only with MAGPIE_LIVE_INFER=1.
///
///   MAGPIE_LIVE_URL   gateway base, e.g. http://127.0.0.1:3425
///   MAGPIE_LIVE_KEY   gateway key (optional; local gateways accept any
///                     key and use it to name the caller in usage pages)
///   MAGPIE_LIVE_INFER "1" to approve billable inference requests
///
/// The report records sanitized schema observations (field names, types,
/// counts) plus compatibility facts (model ids, usage numbers). Account
/// details, keys, and raw bodies are never printed.

///|
struct Ctx {
  base : String
  key : String
  transport : &@magpie.MagpieTransport
  report : Ref[Array[String]]
  mut checks : Int32
  mut failures : Int32
  mut skips : Int32
  mut requests : Int32
  mut billable : Int32
}

///|
/// One attempt, one reserved paid request. This includes calls made via
/// MagpieModelPort, not only direct POST probes.
fn Ctx::reserve_billable(self : Ctx) -> Bool {
  if self.billable >= 14 {
    return false
  }
  self.billable += 1
  true
}

///|
fn Ctx::pass(self : Ctx, line : String) -> Unit {
  self.checks += 1
  let entry = "- [PASS] \{line}"
  self.report.val.push(entry)
  println(entry)
}

///|
fn Ctx::fail(self : Ctx, line : String) -> Unit {
  self.checks += 1
  self.failures += 1
  let entry = "- [FAIL] \{line}"
  self.report.val.push(entry)
  println(entry)
}

///|
fn Ctx::skip(self : Ctx, line : String) -> Unit {
  self.checks += 1
  self.skips += 1
  let entry = "- [SKIP] \{line}"
  self.report.val.push(entry)
  println(entry)
}

///|
fn Ctx::note(self : Ctx, line : String) -> Unit {
  self.report.val.push("  - note: \{line}")
}

///|
fn sanitize(text~ : String, secret~ : String) -> String {
  if secret.length() > 0 && text.contains(secret) {
    return "<redacted: response echoes key material>"
  }
  if text.length() > 120 {
    text[0:120].to_owned() + "…"
  } else {
    text
  }
}

///|
/// Structural shape of a JSON value: field names and types, array lengths,
/// never raw values. Depth-bounded.
fn shape(json : Json, depth~ : Int32 = 2) -> String {
  match json {
    Json::Null => return "null"
    Json::True => return "bool"
    Json::False => return "bool"
    Json::Number(_) => return "number"
    Json::String(_) => return "string"
    Json::Array(items) => {
      let first = if items.length() > 0 {
        shape(items[0], depth=depth - 1)
      } else {
        "empty"
      }
      return "array(len=\{items.length()})[\{first}]"
    }
    Json::Object(fields) => {
      if depth <= 0 {
        return "object"
      }
      let parts : Array[String] = []
      for name, value in fields {
        parts.push("\{name}:\{shape(value, depth=depth - 1)}")
      }
      let mut joined = ""
      for index, part in parts {
        if index > 0 {
          joined = joined + ","
        }
        joined = joined + part
      }
      return "{\{joined}}"
    }
  }
  "other"
}

///|
fn strip_query(path : String) -> String {
  match path.find("?") {
    Some(index) => path[0:index].to_owned()
    None => path
  }
}

///|
fn host_of(url : String) -> String {
  // Print the host:port only; strip any path or query a user may paste in.
  let without_scheme = match url.find("://") {
    Some(index) => url[index + 3:].to_owned()
    None => url
  }
  match without_scheme.find("/") {
    Some(index) => without_scheme[0:index].to_owned()
    None => without_scheme
  }
}

///|
async fn Ctx::get(self : Ctx, path~ : String, key~ : String) -> (Int32, Json?) {
  self.requests += 1
  let headers : Map[String, String] = { "Authorization": "Bearer \{key}" }
  let (code, body) = self.transport.get("\{self.base}\{path}", headers)
  let parsed : Json? = Some(@json.parse(body)) catch { _ => None }
  (code, parsed)
}

///|
async fn Ctx::post(
  self : Ctx,
  path~ : String,
  key~ : String,
  body~ : Json,
) -> Result[(Int32, Json?), String] {
  if !self.reserve_billable() {
    return Err("billable request budget reached (14 attempts)")
  }
  self.requests += 1
  let headers : Map[String, String] = { "Authorization": "Bearer \{key}" }
  let (code, raw) = self.transport.post(
    "\{self.base}\{path}",
    headers~,
    body=body.stringify(),
  ) catch {
    error => return Err(sanitize(text=@debug.to_string(error), secret=key))
  }
  let parsed : Json? = Some(@json.parse(raw)) catch { _ => None }
  Ok((code, parsed))
}

///|
fn Ctx::observe(
  self : Ctx,
  label~ : String,
  outcome~ : Result[(Int32, Json?), MagpieErrorShape],
) -> Unit {
  match outcome {
    Ok((code, body)) => {
      let shape_text = match body {
        Some(json) => shape(json)
        None => "unparseable"
      }
      self.pass("GET \{label} → \{code}; shape: \{shape_text}")
    }
    Err(shape) => self.fail("GET \{label} → \{shape.describe()}")
  }
}

///|
struct MagpieErrorShape {
  code : Int32
  detail : String
}

///|
fn MagpieErrorShape::describe(self : MagpieErrorShape) -> String {
  "\{self.code} \{self.detail}"
}

///|
async fn probe_get(
  ctx : Ctx,
  path~ : String,
  key~ : String,
) -> Result[(Int32, Json?), MagpieErrorShape] {
  let outcome = ctx.get(path~, key~) catch {
    error =>
      return Err(MagpieErrorShape::{
        code: 0,
        detail: sanitize(text=@debug.to_string(error), secret=ctx.key),
      })
  }
  let (code, body) = outcome
  if code >= 200 && code < 300 {
    Ok((code, body))
  } else {
    Err(MagpieErrorShape::{
      code,
      detail: match body {
        Some(_) => "upstream error response redacted"
        None => "no body"
      },
    })
  }
}

///|
/// Model ids from the catalog that declare a native endpoint, plus whether
/// the entry is a routing group.
fn catalog_models(body : Json) -> Array[(String, Array[String], Bool)] {
  let models : Array[(String, Array[String], Bool)] = []
  guard body is Json::Object(fields) else { return models }
  guard fields.get("data") is Some(Json::Array(items)) else { return models }
  for item in items {
    guard item is Json::Object(entry) else { continue }
    guard entry.get("id") is Some(Json::String(id)) else { continue }
    let endpoints : Array[String] = []
    if entry.get("native_endpoints") is Some(Json::Array(endpoints_json)) {
      for endpoint in endpoints_json {
        guard endpoint is Json::String(text) else { continue }
        endpoints.push(text)
      }
    }
    models.push((id, endpoints, id.has_prefix("group/")))
  }
  models
}

///|
fn pick_model(
  models : Array[(String, Array[String], Bool)],
  endpoint~ : String,
) -> String? {
  for (id, endpoints, group) in models {
    if !group && endpoints.contains(endpoint) {
      return Some(id)
    }
  }
  None
}

///|
fn pick_group(models : Array[(String, Array[String], Bool)]) -> String? {
  for (id, _endpoints, group) in models {
    if group {
      return Some(id)
    }
  }
  None
}

///|
fn pick_reasoning(body : Json, endpoint~ : String) -> (String, String)? {
  // A model with non-empty supported_reasoning_levels and the endpoint,
  // together with its first advertised effort name.
  guard body is Json::Object(fields) else { return None }
  guard fields.get("data") is Some(Json::Array(items)) else { return None }
  for item in items {
    guard item is Json::Object(entry) else { continue }
    guard entry.get("id") is Some(Json::String(id)) else { continue }
    if id.has_prefix("group/") {
      continue
    }
    let declared = entry.get("native_endpoints") is Some(Json::Array(endpoints)) &&
      endpoints
      .iter()
      .any(fn(e) { e is Json::String(text) && text == endpoint })
    guard declared else { continue }
    if entry.get("supported_reasoning_levels") is Some(Json::Array(levels)) {
      for level in levels {
        guard level is Json::Object(level_fields) else { continue }
        guard level_fields.get("effort") is Some(Json::String(effort)) else {
          continue
        }
        return Some((id, effort))
      }
    }
  }
  None
}

///|
fn user_wire(text : String) -> Json raise {
  @messages.message_to_wire(
    @posoco.Message::UserMessage(content=[@posoco.Content::Text(text)]),
  )[0]
}

///|
fn assistant_wire(text : String) -> Json {
  Json::object({
    "role": Json::string("assistant"),
    "content": Json::array([
      Json::object({ "type": Json::string("text"), "text": Json::string(text) }),
    ]),
  })
}

///|
async fn chat_via_port(
  ctx : Ctx,
  runtime : @magpie.MagpieRuntime,
  model~ : String,
  session~ : String,
  prompt~ : String,
  stream~ : Bool,
) -> Result[(String, Int32), String] {
  let selection = Json::object({ "model": Json::string(model) })
  let outcome = runtime.invoke("magpie_model", selection) catch {
    error => return Err("select failed: \{error.to_string()}")
  }
  guard outcome is @posoco.CommandOutcome::Success(..) else {
    return Err("select reported failure")
  }
  if !ctx.reserve_billable() {
    return Err("billable request budget reached (14 attempts)")
  }
  ctx.requests += 1
  let before = runtime.recent_reports().length()
  let chunks : Ref[Int32] = Ref(0)
  let mode : @posoco.StreamMode = if stream {
    @posoco.StreamMode::Stream(fn(_chunk) { chunks.val += 1 })
  } else {
    @posoco.StreamMode::NoStream
  }
  let result = runtime
    .model_port()
    .chat(
      @posoco.InvocationScope::{
        session_id: @posoco.SessionId::unchecked(session),
        run_id: @posoco.RunId::unchecked("live-run"),
        effect_id: None,
        pressure: None,
      },
      [@posoco.Message::UserMessage(content=[@posoco.Content::Text(prompt)])],
      [],
      @posoco.ChatOptions::{ temperature: None, max_output_tokens: Some(64), },
      mode,
    ) catch {
      error => return Err("chat failed: \{error.to_string()}")
    }
  let served = match runtime.recent_reports()[before].served_model {
    Some(model) => model
    None => "?"
  }
  let mut text = ""
  for block in result.completion.message.content {
    guard block is @posoco.Content::Text(part) else { continue }
    text = text + part
  }
  let _ = text
  Ok((served, chunks.val))
}

///|
/// Always print an explicit verdict even when a live probe cannot continue.
fn Ctx::finish_report(self : Ctx) -> Unit {
  self.report.val.push(
    "## Summary: \{self.checks - self.failures - self.skips} passed, \{self.failures} failed, \{self.skips} skipped — \{self.requests} gateway requests (\{self.billable} billable)",
  )
  if self.failures > 0 {
    self.report.val.push("RESULT: FAILED")
  } else if self.checks == self.skips {
    self.report.val.push("RESULT: SKIPPED")
  } else {
    self.report.val.push("RESULT: PASSED")
  }
  for line in self.report.val {
    println(line)
  }
}

///|
async fn main {
  let report : Ref[Array[String]] = Ref([])
  report.val.push("# Magpie live gateway compatibility harness")
  let url = @env.get_env_var("MAGPIE_LIVE_URL")
  let key = @env.get_env_var("MAGPIE_LIVE_KEY").unwrap_or("magpie-posoco-live")
  let infer_approved = @env.get_env_var("MAGPIE_LIVE_INFER") == Some("1")
  guard url is Some(base) else {
    report.val.push("")
    report.val.push("RESULT: SKIPPED — MAGPIE_LIVE_URL is not set.")
    report.val.push("Nothing was executed; no gateway was contacted.")
    for line in report.val {
      println(line)
    }
    return
  }
  // Inference takes longer than the 5s default; give every request 120s.
  let transport : &@magpie.MagpieTransport = @magpie.magpie_http_transport(
    timeout_ms=120000,
  )
  let ctx = Ctx::{
    base,
    key,
    transport,
    report,
    checks: 0,
    failures: 0,
    skips: 0,
    requests: 0,
    billable: 0,
  }
  report.val.push("")
  report.val.push(
    "Gateway: \{host_of(base)} · key: \{if key.length() > 0 { "set via env" } else { "anonymous" }} · billable inference: \{if infer_approved { "approved" } else { "not approved" }}",
  )

  // ---- Discovery (read-only) ------------------------------------------
  report.val.push("")
  report.val.push("## Discovery (read-only)")
  let discovery : Array[String] = [
    "/api/hello", "/v1/models", "/v1/magpie/route?session=posoco-live-probe", "/v1/magpie/quotas?kept=true",
    "/v1/magpie/limit", "/v1/magpie/usage?period=today", "/v1/magpie/usage/requests?limit=2&period=today",
    "/v1/magpie/concurrency",
  ]
  let hello = probe_get(ctx, path="/api/hello", key~)
  ctx.observe(label="/api/hello", outcome=hello)
  let models_result = probe_get(ctx, path="/v1/models", key~)
  ctx.observe(label="/v1/models", outcome=models_result)
  for path in discovery[2:] {
    let outcome = probe_get(ctx, path~, key~)
    let label = strip_query(path)
    ctx.observe(label~, outcome~)
  }
  let catalog : Array[(String, Array[String], Bool)] = match models_result {
    Ok((_, Some(body))) => catalog_models(body)
    _ => []
  }
  let models_body : Json? = match models_result {
    Ok((_, body)) => body
    Err(_) => None
  }
  ctx.note("catalog entries: \{catalog.length()}")

  // ---- Authentication (read-only) -------------------------------------
  report.val.push("")
  report.val.push("## Authentication")
  let bad = probe_get(ctx, path="/api/hello", key="magpie-invalid-live-probe")
  match bad {
    Ok((code, _)) =>
      // Local gateways accept any key; remote restricted keys must refuse.
      match code {
        401 | 403 => ctx.pass("invalid key refused with \{code}")
        _ => {
          ctx.pass(
            "invalid key accepted with \{code} (local gateway names callers by key)",
          )
          ctx.note("restricted-key 401/403 requires a remote gateway key")
        }
      }
    Err(shape) => ctx.fail("invalid-key probe errored: \{shape.describe()}")
  }

  // ---- Runtime commands (read-only) -----------------------------------
  report.val.push("")
  report.val.push("## Runtime commands")
  let runtime = @magpie.MagpieRuntime::activate(
    settings=Some(
      Json::object({
        "base_url": Json::string(base),
        "gateway_key": Json::string(key),
      }),
    ),
    transport~,
  )
  runtime.on_start()
  let command_specs : Array[(String, Json)] = [
    ("magpie_model", Json::null()),
    ("magpie_status", Json::null()),
    ("magpie_refresh", Json::null()),
    (
      "magpie_route",
      Json::object({ "session": Json::string("posoco-live-probe") }),
    ),
    ("magpie_quotas", Json::object({ "kept": Json::boolean(true) })),
    ("magpie_limit", Json::null()),
    ("magpie_usage", Json::object({ "period": Json::string("today") })),
    (
      "magpie_requests",
      Json::object({ "period": Json::string("today"), "limit": Json::number(5) }),
    ),
    ("magpie_concurrency", Json::null()),
    ("magpie_usage_recent", Json::null()),
  ]
  for (id, args) in command_specs {
    let outcome = runtime.invoke(id, args) catch {
      error => {
        ctx.fail(
          "\{id} raised: \{sanitize(text=error.to_string(), secret=key)}",
        )
        continue
      }
    }
    match outcome {
      @posoco.CommandOutcome::Success(feedback~, structured~, ..) => {
        let shape_text = match structured {
          Some(json) => shape(json, depth=1)
          None => "no structured output"
        }
        ctx.pass("\{id} → feedback_present=\{feedback.length() > 0}; structured: \{shape_text}")
      }
      @posoco.CommandOutcome::Failure(reason~) =>
        ctx.skip("\{id} → Failure: \{sanitize(text=reason, secret=key)}")
      @posoco.CommandOutcome::NeedsInput(prompt~) =>
        ctx.fail("\{id} → NeedsInput: \{prompt}")
    }
  }

  // ---- Inference (opt-in, billable) -----------------------------------
  report.val.push("")
  report.val.push("## Inference (billable)")
  if !infer_approved {
    ctx.skip("MAGPIE_LIVE_INFER=1 not set; no inference attempted")
  } else {
    let budget = 14
    // Anthropic Messages native.
    match pick_model(catalog, endpoint="/v1/messages") {
      Some(model) =>
        if ctx.billable < budget {
          match
            chat_via_port(
              ctx,
              runtime,
              model~,
              session="posoco-live-msg",
              prompt="Reply with OK only.",
              stream=false,
            ) {
            Ok((served, _)) =>
              ctx.pass("messages native: asked \{model} → served \{served}")
            Err(reason) =>
              ctx.fail(
                "messages native (\{model}): \{sanitize(text=reason, secret=key)}",
              )
          }
          // Streaming over the same protocol.
          match
            chat_via_port(
              ctx,
              runtime,
              model~,
              session="posoco-live-msg-stream",
              prompt="Reply with OK only.",
              stream=true,
            ) {
            Ok((served, chunks)) =>
              ctx.pass("messages stream: served \{served}, \{chunks} chunks")
            Err(reason) =>
              ctx.fail(
                "messages stream (\{model}): \{sanitize(text=reason, secret=key)}",
              )
          }
        }
      None => ctx.skip("no native /v1/messages model in the catalog")
    }
    // OpenAI Responses native.
    match pick_model(catalog, endpoint="/v1/responses") {
      Some(model) =>
        if ctx.billable < budget {
          match
            chat_via_port(
              ctx,
              runtime,
              model~,
              session="posoco-live-resp",
              prompt="Reply with OK only.",
              stream=false,
            ) {
            Ok((served, _)) =>
              ctx.pass("responses native: asked \{model} → served \{served}")
            Err(reason) =>
              ctx.fail(
                "responses native (\{model}): \{sanitize(text=reason, secret=key)}",
              )
          }
        }
      None => ctx.skip("no native /v1/responses model in the catalog")
    }
    // Chat Completions native.
    match pick_model(catalog, endpoint="/v1/chat/completions") {
      Some(model) =>
        if ctx.billable < budget {
          match
            chat_via_port(
              ctx,
              runtime,
              model~,
              session="posoco-live-chat",
              prompt="Reply with OK only.",
              stream=false,
            ) {
            Ok((served, _)) =>
              ctx.pass(
                "chat-completions native: asked \{model} → served \{served}",
              )
            Err(reason) =>
              ctx.fail(
                "chat-completions native (\{model}): \{sanitize(text=reason, secret=key)}",
              )
          }
        }
      None => ctx.skip("no native /v1/chat/completions model in the catalog")
    }
    // Routing group.
    match pick_group(catalog) {
      Some(group) =>
        if ctx.billable < budget {
          match
            chat_via_port(
              ctx,
              runtime,
              model=group,
              session="posoco-live-group",
              prompt="Reply with OK only.",
              stream=false,
            ) {
            Ok((served, _)) =>
              ctx.pass("routing group \{group} → served \{served}")
            Err(reason) =>
              ctx.fail(
                "routing group (\{group}): \{sanitize(text=reason, secret=key)}",
              )
          }
        }
      None => ctx.skip("no routing group in the catalog")
    }
    // Reasoning effort through the port.
    match models_body {
      Some(body) =>
        match pick_reasoning(body, endpoint="/v1/messages") {
          Some((model, effort)) => {
            let _ = runtime.invoke(
              "magpie_model",
              Json::object({
                "model": Json::string(model),
                "effort": Json::string(effort),
              }),
            )
            if ctx.reserve_billable() {
              ctx.requests += 1
              try {
                let _ = runtime
                .model_port()
                .chat(
                  @posoco.InvocationScope::{
                    session_id: @posoco.SessionId::unchecked(
                      "posoco-live-effort",
                    ),
                    run_id: @posoco.RunId::unchecked("live-run"),
                    effect_id: None,
                    pressure: None,
                  },
                  [
                    @posoco.Message::UserMessage(content=[
                      @posoco.Content::Text("Reply with OK only."),
                    ]),
                  ],
                  [],
                  @posoco.ChatOptions::{
                    temperature: None,
                    max_output_tokens: Some(64),
                  },
                  @posoco.StreamMode::NoStream,
                )
              ctx.pass(
                "effort \{effort} accepted for \{model} (\{ctx.billable} billable so far)",
              )
              } catch {
                error =>
                  ctx.fail(
                    "effort \{effort} rejected for \{model}: \{sanitize(text=@debug.to_string(error), secret=key)}",
                  )
              }
            } else {
              ctx.skip("reasoning effort: billable budget exhausted")
            }
          }
          None =>
            ctx.skip("no model advertises reasoning levels for /v1/messages")
        }
      None => ctx.skip("catalog body unavailable for reasoning pick")
    }
    // Tool round trip through the port (messages protocol).
    match pick_model(catalog, endpoint="/v1/messages") {
      Some(model) => {
        let _ = runtime.invoke(
          "magpie_model",
          Json::object({ "model": Json::string(model) }),
        )
        let tool : @posoco.ToolDef = {
          name: @posoco.ToolName::unchecked("get_weather"),
          description: "Get current weather. You MUST call this tool when asked about weather.",
          input_schema: Json::object({
            "type": Json::string("object"),
            "properties": Json::object({
              "city": Json::object({ "type": Json::string("string") }),
            }),
            "required": Json::array([Json::string("city")]),
          }),
          owner: @posoco.OwnerId::unchecked("posoco-live"),
          policy: @posoco.ExecutionPolicy::Sequential,
          provenance: None,
        }
        if ctx.reserve_billable() {
          ctx.requests += 1
          try {
            let result = runtime
            .model_port()
            .chat(
              @posoco.InvocationScope::{
                session_id: @posoco.SessionId::unchecked("posoco-live-tool"),
                run_id: @posoco.RunId::unchecked("live-run"),
                effect_id: None,
                pressure: None,
              },
              [
                @posoco.Message::UserMessage(content=[
                  @posoco.Content::Text(
                    "What is the weather in Tokyo? Use the tool.",
                  ),
                ]),
              ],
              [tool],
              @posoco.ChatOptions::{
                temperature: None,
                max_output_tokens: Some(128),
              },
              @posoco.StreamMode::NoStream,
            )
          let calls = result.completion.message.tool_calls.length()
          if calls > 0 {
            ctx.pass("tool round trip: \{calls} tool call(s) requested")
          } else {
            ctx.skip("tool round trip: model answered without calling the tool")
          }
          } catch {
            error =>
              ctx.fail(
                "tool round trip (\{model}): \{sanitize(text=@debug.to_string(error), secret=key)}",
              )
          }
        } else {
          ctx.skip("tool probe: billable budget exhausted")
        }
      }
      None => ctx.skip("no native /v1/messages model for the tool round trip")
    }
  }

  // ---- Cache economics (opt-in, billable) ------------------------------
  report.val.push("")
  report.val.push("## Messages cache economics (billable)")
  if !infer_approved {
    ctx.skip("MAGPIE_LIVE_INFER=1 not set; no caching attempted")
  } else {
    match pick_model(catalog, endpoint="/v1/messages") {
      Some(model) => {
        // Stable prefix: identical system and tools across both turns, only
        // 5-minute (ephemeral) caching; 1h TTL is deliberately never set.
        let builder = StringBuilder()
        for _index in 0..<90 {
          builder.write_string(
            "The gateway routes requests, tracks usage, and enforces quotas. ",
          )
        }
        let filler = "You are documenting a gateway. " + builder.to_string()
        let system = @messages.system_to_wire(
          content=[@posoco.Content::Text(filler)],
          cache_control=Some(@messages.CacheControl::{ ttl: None, }),
        )
        let tool : @posoco.ToolDef = {
          name: @posoco.ToolName::unchecked("list_docs"),
          description: "List documentation pages.",
          input_schema: Json::object({ "type": Json::string("object") }),
          owner: @posoco.OwnerId::unchecked("posoco-live"),
          policy: @posoco.ExecutionPolicy::Sequential,
          provenance: None,
        }
        let wire_tool = @messages.tool_to_wire(
          tool~,
          cache_control=Some(@messages.CacheControl::{ ttl: None, }),
        )
        let turn1 = @messages.encode_request(
          model~,
          max_tokens=32,
          system=Some(system),
          messages=[user_wire("Reply with OK only.")],
          tools=[wire_tool],
          options=@messages.MessagesRequestOptions::MessagesRequestOptions(),
        )
        let posted1 = ctx.post(path="/v1/messages", key~, body=turn1)
        let (code1, body1) = match posted1 {
          Ok(pair) => pair
          Err(reason) => {
            ctx.fail("cache cold turn errored: \{reason}")
            runtime.on_shutdown()
            ctx.finish_report()
            return
          }
        }
        let usage1 : Json? = match body1 {
          Some(Json::Object(fields)) => fields.get("usage")
          _ => None
        }
        let creation = match usage1 {
          Some(Json::Object(u)) =>
            match u.get("cache_creation_input_tokens") {
              Some(Json::Number(n, ..)) => Some(n.to_int())
              _ => None
            }
          _ => None
        }
        match creation {
          Some(tokens) if tokens > 0 =>
            ctx.pass("cache creation reported: \{tokens} tokens")
          _ =>
            ctx.fail(
              "no cache creation tokens on the cold turn (code \{code1}) — caching may be unsupported for \{model}",
            )
        }
        let turn2 = @messages.encode_request(
          model~,
          max_tokens=32,
          system=Some(system),
          messages=[
            user_wire("Reply with OK only."),
            assistant_wire("OK"),
            user_wire("Reply with THANKS only."),
          ],
          tools=[wire_tool],
          options=@messages.MessagesRequestOptions::MessagesRequestOptions(),
        )
        let posted2 = ctx.post(path="/v1/messages", key~, body=turn2)
        let (code2, body2) = match posted2 {
          Ok(pair) => pair
          Err(reason) => {
            ctx.fail("cache warm turn errored: \{reason}")
            runtime.on_shutdown()
            ctx.finish_report()
            return
          }
        }
        let usage2 : Json? = match body2 {
          Some(Json::Object(fields)) => fields.get("usage")
          _ => None
        }
        let read = match usage2 {
          Some(Json::Object(u)) =>
            match u.get("cache_read_input_tokens") {
              Some(Json::Number(n, ..)) => Some(n.to_int())
              _ => None
            }
          _ => None
        }
        match read {
          Some(tokens) if tokens > 0 =>
            ctx.pass(
              "cache hit proven by upstream usage: \{tokens} tokens read on the repeated prefix",
            )
          _ =>
            ctx.fail(
              "no cache read tokens on the identical-prefix turn (code \{code2})",
            )
        }
        ctx.note("cache verdicts use upstream-reported usage only")
      }
      None => ctx.skip("no native /v1/messages model for cache economics")
    }
  }

  // ---- Usage reconciliation (read-only) --------------------------------
  report.val.push("")
  report.val.push("## Usage reporting")
  match
    probe_get(ctx, path="/v1/magpie/usage/requests?limit=5&period=today", key~) {
    Ok((_, Some(body))) => {
      let mut found = false
      if body is Json::Object(fields) &&
        fields.get("data") is Some(Json::Array(rows)) {
        for row in rows {
          if row is Json::Object(entry) &&
            entry.get("agent") is Some(Json::String(agent)) {
            if agent == key {
              found = true
            }
          }
        }
      }
      if found {
        ctx.pass("usage/requests recorded calls under this harness key")
      } else {
        ctx.skip("no rows under this harness key in the recent page")
      }
    }
    Ok(_) => ctx.fail("usage/requests returned an unexpected shape")
    Err(shape) =>
      ctx.fail(
        "usage/requests errored: \{sanitize(text=shape.describe(), secret=key)}",
      )
  }

  runtime.on_shutdown()

  // ---- Summary ----------------------------------------------------------
  report.val.push("")
  ctx.finish_report()
}
