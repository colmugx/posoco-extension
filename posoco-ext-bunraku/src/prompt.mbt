///|
pub impl @posoco.SystemPromptContributor for BunrakuExtension with fn system_prompt(
  self : BunrakuExtension,
) -> String {
  let sections : String =
    #|## Optional MoonBit programmatic tool calling
    #|Ordinary tools remain available. Prefer them for simple calls, uncertain next steps, or when compiling code would cost more than it saves.
    #|Choose run_code when several deterministic calls can be batched and intermediate results can stay out of the model context. Do not retry or promote run_code merely because it is available.
    #|code is the body of the run_code guest handler: statements over ctx and input; omit imports, signatures, and main.
    #|Use ctx.call("name", arguments). Success returns structured JSON or a content string; failure returns {"error": "CODE", "content": "message"}.
    #|Return a concise final Json value. source accepts a complete .mbtx program: import "posoco/ears@0.1.0" @ears and call @ears.serve(wire=@ears.stdio(), run=(ears, input) => { ... }); ears.call returns an @ears.Outcome whose failures are values.
  let names = if self.tool_names.is_empty() {
    "(none)"
  } else {
    self.tool_names.join(", ")
  }
  sections + "\nNested capabilities: " + names
}

///|
pub extend BunrakuExtension with @posoco.SystemPromptContributor::{
  system_prompt,
}
