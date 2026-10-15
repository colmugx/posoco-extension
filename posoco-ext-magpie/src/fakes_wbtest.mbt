///|
/// fakes_wbtest.mbt — deterministic gateway fakes shared by the suite.
///
/// Everything runs against scripted responses: no network, no Magpie
/// process, no environment.

///|
priv enum FakeStep {
  Respond(code~ : Int32, body~ : String)
  FailWith(MagpieGatewayError)
}

///|
/// One scripted POST answer: a buffered body, or SSE lines when
/// `stream_lines` is present (each element is one raw line; EOF after the
/// last).
priv struct FakePostStep {
  status : Int32
  body : String
  stream_lines : Array[String]?
}

///|
fn buffered_post(status~ : Int32, body~ : String) -> FakePostStep {
  { status, body, stream_lines: None }
}

///|
fn streaming_post(status~ : Int32, lines~ : Array[String]) -> FakePostStep {
  { status, body: "", stream_lines: Some(lines) }
}

///|
/// Scripted `MagpieTransport`: hands out queued steps in request order and
/// records every URL plus the presented credential.
struct FakeTransport {
  steps : Array[FakeStep]
  mut next : Int32
  calls : Array[String]
  auths : Array[String]
  posts : Array[FakePostStep]
  mut post_next : Int32
  post_calls : Array[String]
  post_auths : Array[String]
  post_sessions : Array[String]
  /// Artificial pause before answering, to force overlapping refreshes.
  mut delay_ms : Int32
}

///|
fn FakeTransport::FakeTransport(
  steps : Array[FakeStep],
  posts? : Array[FakePostStep] = [],
) -> FakeTransport {
  {
    steps,
    next: 0,
    calls: [],
    auths: [],
    posts,
    post_next: 0,
    post_calls: [],
    post_auths: [],
    post_sessions: [],
    delay_ms: 0,
  }
}

///|
impl MagpieTransport for FakeTransport with fn get(
  self : FakeTransport,
  url : String,
  headers : Map[String, String],
) -> (Int32, String) raise MagpieGatewayError {
  self.calls.push(url)
  self.auths.push(headers.get("Authorization").unwrap_or(""))
  if self.delay_ms > 0 {
    @async.sleep(self.delay_ms)
  }
  if self.next >= self.steps.length() {
    raise MagpieGatewayError::Offline(
      "fake transport exhausted; unexpected request to \{url}",
    )
  }
  match self.steps[self.next] {
    Respond(code~, body~) => {
      self.next += 1
      (code, body)
    }
    FailWith(error) => {
      self.next += 1
      raise error
    }
  }
}

///|
/// Scripted SSE stream over the queued lines, with an optional per-line
/// pause so cancellation tests can land mid-read.
struct FakeEventStream {
  lines : Array[String]
  mut cursor : Int
  delay_ms : Int32
}

///|
impl MagpieEventStream for FakeEventStream with fn next_line(
  self : FakeEventStream,
) -> String? raise MagpieGatewayError {
  if self.delay_ms > 0 {
    @async.sleep(self.delay_ms)
  }
  if self.cursor >= self.lines.length() {
    return None
  }
  let line = self.lines[self.cursor]
  self.cursor += 1
  Some(line)
}

///|
impl MagpieEventStream for FakeEventStream with fn close_stream(
  self : FakeEventStream,
) -> Unit raise MagpieGatewayError {
  let _ = self
}

///|
fn FakeTransport::record_post(
  self : FakeTransport,
  url : String,
  body : String,
  headers : Map[String, String],
) -> Unit {
  self.post_calls.push(url + " " + body)
  self.post_auths.push(headers.get("Authorization").unwrap_or(""))
  self.post_sessions.push(headers.get("X-Magpie-Session").unwrap_or(""))
}

///|
fn FakeTransport::take_post(
  self : FakeTransport,
) -> FakePostStep raise MagpieGatewayError {
  if self.post_next >= self.posts.length() {
    raise MagpieGatewayError::Offline(
      "fake transport: unexpected POST, script exhausted",
    )
  }
  let step = self.posts[self.post_next]
  self.post_next += 1
  step
}

///|
impl MagpieTransport for FakeTransport with fn post(
  self : FakeTransport,
  url : String,
  headers~ : Map[String, String],
  body~ : String,
) -> (Int32, String) raise MagpieGatewayError {
  self.record_post(url, body, headers)
  let step = self.take_post()
  (step.status, step.body)
}

///|
impl MagpieTransport for FakeTransport with fn post_stream(
  self : FakeTransport,
  url : String,
  headers~ : Map[String, String],
  body~ : String,
) -> (Int32, &MagpieEventStream) raise MagpieGatewayError {
  self.record_post(url, body, headers)
  let step = self.take_post()
  guard step.stream_lines is Some(lines) else {
    raise MagpieGatewayError::Offline(
      "fake transport: streaming POST got a buffered step",
    )
  }
  (step.status, FakeEventStream::{ lines, cursor: 0, delay_ms: self.delay_ms })
}
///|
/// A valid `/api/hello` body.
fn hello_body(version~ : String = "0.1.1224") -> String {
  "{\"name\":\"magpie\",\"version\":\"\{version}\"}"
}

///|
/// A valid `/v1/models` body over the given entry objects.
fn models_body(entries : String) -> String {
  "{\"data\":[\{entries}]}"
}

///|
/// A complete, well-formed catalog entry. `fields` carries the optional
/// attributes so tests can drop or replace any of them.
fn model_entry(
  id~ : String,
  name~ : String = "Model",
  owned_by~ : String = "deepseek",
  fields~ : String = "\"reasoning\":true,\"supported_reasoning_levels\":[{\"effort\":\"low\"},{\"effort\":\"medium\"},{\"effort\":\"high\"}],\"context_window\":131072,\"modalities\":{\"input\":[\"text\",\"image\"]}",
) -> String {
  "{\"id\":\"\{id}\",\"display_name\":\"\{name}\",\"owned_by\":\"\{owned_by}\",\{fields}}"
}

///|
/// A two-step gateway script: hello, then the given models body.
fn gateway(models~ : String, hello~ : String = hello_body()) -> FakeTransport {
  FakeTransport([Respond(code=200, body=hello), Respond(code=200, body=models)])
}

///|
/// The default local configuration.
fn local_config() -> MagpieConfig raise {
  MagpieConfig::MagpieConfig() catch {
    _ => fail("default config must be valid")
  }
}

///|
/// A configuration that must construct successfully.
fn must_config(
  make : () -> MagpieConfig raise MagpieGatewayError,
) -> MagpieConfig raise {
  make() catch {
    _ => fail("expected a valid configuration")
  }
}

///|
/// A manager over the given transport and configuration.
fn manager_with(
  transport~ : FakeTransport,
  config~ : MagpieConfig,
) -> MagpieManager {
  MagpieManager::MagpieManager(config~, transport~)
}

///|
/// A refresh that must succeed; the outcome is discarded.
async fn refresh_ok(manager : MagpieManager) -> Unit {
  let _ = manager.refresh() catch {
    error => fail("refresh must succeed, got \{error}")
  }
}

///|
/// Model ids of a catalog snapshot, in presentation order.
fn ids(models : Array[@modelmgmt.ManagerModelInfo]) -> Array[String] {
  models.map(fn(model) { model.model_id })
}

///|
/// The selection of a manager, as a compact string for snapshots.
fn selection_text(manager : MagpieManager) -> String {
  let selection = manager.active_selection()
  let effort = match selection.effort {
    Some(e) => e
    None => "-"
  }
  "\{selection.model_id}/\{effort}/pending=\{selection.pending}"
}

///|
/// The transport a manager was built with (test wiring: the port shares it).
fn transport_of(manager : MagpieManager) -> &MagpieTransport {
  manager.transport
}
