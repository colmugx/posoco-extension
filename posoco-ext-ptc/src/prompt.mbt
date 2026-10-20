///|
pub impl @posoco.SystemPromptContributor for PtcExtension with fn system_prompt(
  self : PtcExtension,
) -> String {
  let sections : String =
    #|## Programmatic tool calling (MoonBit)
    #|run_code is optional. Use ordinary tools for simple operations and batch deterministic multi-tool work with run_code only when it reduces model turns.
    #|code is the body of: async fn ptc_run(ctx : PtcContext, input : Json) -> Json { ... }
    #|Do not include imports, the function signature, or main in code.
    #|Call ctx.call("tool_name", {"arg": value}) to invoke nested tools.
    #|Successful calls return structured JSON, or the content string when no structured result exists.
    #|Failed calls return {"error": "CODE", "content": "message"}; inspect errors before continuing.
    #|Keep intermediate tool results in MoonBit. Return a concise final Json value.
    #|Call run_code with code or source, description, and optionally input.
    #|For reusable programs, source accepts a complete .mbtx program using the versioned MBTX SDK and @mbtx.serve(run).
    #|Only these names are available through ctx.call; other model-visible tools remain directly usable:
  let entries : Array[String] = []
  if self.exposed.is_empty() {
    entries.push("(none; pure MoonBit computation only)")
  } else {
    for def in self.exposed {
      let name = def.name.to_string()
      if self.tool_names.contains(name) {
        entries.push(
          if name == "read" || name == "glob" || name == "grep" ||
            name == "edit" || name == "write" || name == "bash" ||
            name == "apply_patch" {
            name + ": " + def.description + "\n  input_schema=" +
            def.input_schema.stringify()
          } else {
            name + ": " + def.description
          },
        )
      }
    }
  }
  sections + "\n" + entries.join("\n")
}

///|
pub extend PtcExtension with @posoco.SystemPromptContributor::{system_prompt}
