///|
/// An inline PTC program is the body of the guest handler, not shell source.
/// The generated bootstrap is a complete .mbtx program over the published
/// `posoco/ears` SDK — the host injects no protocol code of its own.
///
/// The guest owns the intermediate JSON values. It publishes exactly one
/// outer result, so nested tool results do not expand the model transcript.
///
/// `ctx.call` keeps the model-facing contract: success yields the structured
/// payload (falling back to the content string); failure yields
/// { "error": code, "content": text } as a plain value.
fn inline_guest_source(code : String) -> String {
  let prefix : String =
    #|import {
    #|  "moonbitlang/async@0.22.5",
    #|  "moonbitlang/core/json",
    #|  "posoco/ears@0.1.0" @ears,
    #|}
    #|
    #|struct GuestContext {
    #|  ears : @ears.Ears
    #|}
    #|
    #|/// Success yields the structured payload (falling back to the content
    #|/// string); failure yields { "error": code, "content": text }.
    #|async fn GuestContext::call(self : GuestContext, name : String, args : Json) -> Json {
    #|  match self.ears.call(name, args) {
    #|    @ears.Success(structured=Some(value), ..) => value
    #|    @ears.Success(content~, structured=None) => Json::string(content)
    #|    @ears.Failure(code~, content~, ..) => { "error": code, "content": content }
    #|  }
    #|}
    #|
    #|async fn main {
    #|  @ears.serve(wire=@ears.stdio(), run=(ears, input) => {
    #|  let ctx = GuestContext::{ ears, }
  let suffix : String =
    #|  })
    #|}
  prefix + "\n" + code + "\n" + suffix
}

///|
/// `code` is the handler body; the generated bootstrap supplies everything
/// around it. The prefixes below are complete programs or wrapped functions —
/// the recurring contract violations — named here so the model can fix them
/// before the compiler ever sees them.
fn reject_wrapped_code(code : String) -> String? {
  let trimmed = code.trim()
  if trimmed.has_prefix("async fn ptc_run") ||
    trimmed.has_prefix("fn ptc_run") ||
    trimmed.has_prefix("async fn main") ||
    trimmed.has_prefix("fn main") ||
    trimmed.has_prefix("import") {
    return Some(
      "run_code: `code` must be the handler body — send the statements only, without any function signature, imports, or main. To run a complete program, pass it as `source` instead.",
    )
  }
  None
}
