///|
/// A PTC program is a MoonBit async function body, not shell source. The
/// bootstrap imports only the released async/stdio modules; it does not
/// assume that the experimental MBTX SDK ABI has been published yet.
///
/// The guest owns the intermediate JSON values. It publishes exactly one
/// outer result, so nested tool results do not expand the model transcript.
///
/// The request/reply channel is serialized by a Mutex. Parallel branches
/// may compute concurrently but individual nested tool calls are serialized
/// until Posoco supplies its governed scheduler bridge.
fn ptc_guest_source(code : String) -> String {
  let prefix : String =
    #|import {
    #|  "moonbitlang/async@0.22.5",
    #|  "moonbitlang/async@0.22.5/stdio",
    #|  "moonbitlang/core/json",
    #|}
    #|
    #|struct PtcContext {
    #|  mut next_id : Int32
    #|  wire : @async.Mutex
    #|}
    #|
    #|/// Call a capability from the current PTC program.
    #|/// Success returns structured JSON (falling back to content string);
    #|/// failure returns { "error": code, "content": text }.
    #|async fn PtcContext::call(self : PtcContext, name : String, args : Json) -> Json {
    #|  self.wire.acquire()
    #|  defer self.wire.release()
    #|  self.next_id += 1
    #|  let request : Json = {
    #|    "type": "request", "id": self.next_id,
    #|    "name": name, "arguments": args,
    #|  }
    #|  @stdio.stdout.write(request.stringify() + "\n")
    #|  guard @stdio.stdin.read_until("\n") is Some(reply) else {
    #|    fail("PTC host disconnected while waiting for tool reply")
    #|  }
    #|  match @json.parse(reply) {
    #|    {"type": "reply", "outcome": {"kind": "success", "structured": value, ..}, ..} => value
    #|    {"type": "reply", "outcome": {"kind": "success", "content": String(text), ..}, ..} => Json::string(text)
    #|    {"type": "reply", "outcome": {"kind": "failure", "code": String(code), "content": String(text), ..}, ..} =>
    #|      {"error": code, "content": text}
    #|    _ => fail("PTC received malformed tool reply")
    #|  }
    #|}
    #|
    #|async fn ptc_run(ctx : PtcContext, input : Json) -> Json {
  let suffix : String =
    #|}
    #|
    #|async fn main {
    #|  @stdio.stdout.write("{\"type\":\"hello\",\"protocol\":1}\n")
    #|  guard @stdio.stdin.read_until("\n") is Some(line) else {
    #|    fail("PTC missing host invocation")
    #|  }
    #|  guard @json.parse(line) is {"type": "invoke", "input": input, ..} else {
    #|    fail("PTC invalid host invocation")
    #|  }
    #|  let ctx = PtcContext::{next_id: 0, wire: @async.Mutex()}
    #|  let value = ptc_run(ctx, input)
    #|  let response : Json = {
    #|    "type": "result",
    #|    "outcome": {"kind": "success", "content": value.stringify(), "structured": value},
    #|  }
    #|  @stdio.stdout.write(response.stringify() + "\n")
    #|}
  prefix + "\n" + code + "\n" + suffix
}

///|
/// `code` is the body of `ptc_run`, whose signature the bootstrap supplies.
/// A caller that includes the signature declares `ptc_run` twice and the
/// build fails, so name that contract violation before building.
fn reject_wrapped_code(code : String) -> String? {
  let trimmed = code.trim()
  if trimmed.has_prefix("async fn ptc_run") || trimmed.has_prefix("fn ptc_run") {
    return Some(
      "run_code: `code` must be the body of async fn ptc_run(ctx, input) — send the statements only, without the function signature, imports, or main. To run a complete program, pass it as `source` instead.",
    )
  }
  None
}
