///|
pub impl @posoco.SystemPromptContributor for BunrakuExtension with fn system_prompt(
  self : BunrakuExtension,
) -> String {
  let sections : String =
    #|## Optional MoonBit programmatic tool calling
    #|Ordinary tools remain available. Prefer them for simple calls, uncertain next steps, or when compiling code would cost more than it saves.
    #|Choose run_code when several deterministic calls can be batched and intermediate results can stay out of the model context. Do not retry or promote run_code merely because it is available.
    #|code is the body of the run_code guest handler: statements over ctx and input; omit imports, signatures, and main.
    #|Use ctx.call("name", arguments). Success returns structured JSON or a content string; failure returns {"error": "CODE", "content": "message"} — branch on it, never assume success.
    #|When the program cannot continue, fail("reason") becomes the tool error. Return one concise final Json value; print only to diagnose.
    #|source accepts a complete .mbtx program: import "posoco/ears@0.1.0" @ears and call @ears.serve(wire=@ears.stdio(), run=(ears, input) => { ... }); ears.call returns an @ears.Outcome whose failures are values (outcome.is_error) — only a lost connection raises.
    #|
    #|## Writing good guest programs
    #|Batch the deterministic fan-out, fold results into one small summary, and let intermediate JSON stay in the guest.
    #|Keep handlers small and single-purpose; probe unfamiliar APIs with one tiny program per hypothesis — independent probes run in one round-trip and one failure never blocks the others.
    #|Prefer structured reads (glob/read) over printing whole files; truncate or summarize before returning.
  let sections = sections + "\n" + @mbtx.syntax_primer()
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
