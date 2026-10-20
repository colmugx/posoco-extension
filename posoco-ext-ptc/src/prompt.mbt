///|
/// Keep the stable prefix small. Full schemas for the core coding tools only;
/// all other capabilities are discoverable by concise name/description.
/// Model tools list contains only run_code; these are PROGRAM bindings only.
pub impl @posoco.SystemPromptContributor for PtcExtension with fn system_prompt(
  self : PtcExtension,
) -> String {
  let sections : Array[String] = [
    "## Programmatic tool calling (MoonBit)", "You have one tool: run_code. Its code is the BODY of:",
    "async fn ptc_run(ctx : PtcContext, input : Json) -> Json { ... }", "Do not include import statements, the function signature, or main.",
    "Use ctx.call(\"tool_name\", {\"arg\": value}) for nested tools.", "A successful nested call returns its structured JSON value, or a string if no structured result is supplied.",
    "A denied/failed nested call returns {\"error\": \"CODE\", \"content\": \"message\"}; check this before consuming.",
    "Filter, loop and summarize in MoonBit. Return ONLY the final Json value. Inner results remain in the program, not in the model transcript.",
    "For ordinary comparisons, use MoonBit patterns on JSON, e.g. if value is {\"error\": String(reason), ..} { ... }.",
    "Call run_code with code or source, description and optionally input.", "For reusable programs prefer source: a complete .mbtx with the versioned MBTX SDK, @mbtx.serve(run), and normal source locations.",
    "Available bindings (only these tool names may be called):",
  ]
  if self.exposed.is_empty() {
    sections.push("(none; pure MoonBit computation only)")
  } else {
    for def in self.exposed {
      let name = def.name.to_string()
      if self.tool_names.contains(name) {
        sections.push(
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
  sections.join("\n")
}

///|
pub extend PtcExtension with @posoco.SystemPromptContributor::{system_prompt}
