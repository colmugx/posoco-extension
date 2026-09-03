///|
/// Pi prompt-snippet bridge: projects the shared JS host's
/// promptSnippet/promptGuidelines self-description onto the Posoco
/// PipelineHook::before_model point. The SystemPromptContributor contract is
/// stable-only (dynamic catalogs forbidden there), so dynamic injection rides
/// the hook instead. One delimited <pi-tools> block is appended to the system
/// message (created when absent) and rebuilt from live host state on every
/// model call, mirroring pi's own system-prompt rendering: registration
/// order, `- name: snippet` lines, deduplicated guideline bullets.
pub struct PiHook {
  host : JsPiHost
}

///|
pub fn PiHook::PiHook(host~ : JsPiHost) -> PiHook {
  { host, }
}

///|
priv struct PiSnippetEntry {
  name : String
  snippet : String
  guidelines : Array[String]
}

///|
fn PiHook::entries(self : PiHook) -> Array[PiSnippetEntry] {
  let entries : Array[PiSnippetEntry] = []
  match parse_json_or_null(js_prompt_snippets_json(self.host)) {
    Json::Array(items) =>
      for item in items {
        match item {
          Json::Object(fields) => {
            let name = pi_json_string_or(fields, "name")
            let snippet = pi_json_string_or(fields, "snippet")
            let guidelines : Array[String] = []
            match fields.get("guidelines") {
              Some(Json::Array(raw)) =>
                for guideline in raw {
                  match guideline {
                    Json::String(text) => guidelines.push(text)
                    _ => ()
                  }
                }
              _ => ()
            }
            if name != "" {
              entries.push({ name, snippet, guidelines, })
            }
          }
          _ => ()
        }
      }
    _ => ()
  }
  entries
}

///|
/// Render the <pi-tools> block; empty when no registered tool self-describes.
fn pi_prompt_block(entries : Array[PiSnippetEntry]) -> String {
  let tool_lines : Array[String] = []
  let guideline_lines : Array[String] = []
  let seen : Map[String, Bool] = Map::from_array([])
  for entry in entries {
    let snippet = entry.snippet.trim()
    if snippet != "" {
      tool_lines.push("- \{entry.name}: \{snippet}")
    }
    for guideline in entry.guidelines {
      let text = guideline.trim().to_owned()
      if text != "" && !seen.contains(text) {
        seen[text] = true
        guideline_lines.push("- \{text}")
      }
    }
  }
  if tool_lines.is_empty() && guideline_lines.is_empty() {
    return ""
  }
  let builder = StringBuilder()
  builder.write_string("<pi-tools>")
  if !tool_lines.is_empty() {
    builder.write_string("\nAvailable tools:")
    for line in tool_lines {
      builder.write_string("\n")
      builder.write_string(line)
    }
  }
  if !guideline_lines.is_empty() {
    if !tool_lines.is_empty() {
      builder.write_string("\n")
    }
    builder.write_string("\nGuidelines:")
    for line in guideline_lines {
      builder.write_string("\n")
      builder.write_string(line)
    }
  }
  builder.write_string("\n</pi-tools>")
  builder.to_string()
}

///|
/// Append the block to the system message's content as its own Text element;
/// messages other than the system message pass through untouched. Sync body
/// satisfying the async trait slot: the read is a synchronous JS host peek.
pub impl @posoco.PipelineHook for PiHook with fn before_model(
  self : PiHook,
  messages : Array[@kernel.Message],
) -> Array[@kernel.Message] raise @posoco.HookAbort {
  let block = pi_prompt_block(self.entries())
  if block == "" {
    return messages
  }
  if messages.length() == 0 {
    return [@kernel.SystemMessage(content=[@kernel.Text(block)])]
  }
  match messages[0] {
    @kernel.SystemMessage(content~) => {
      let merged : Array[@kernel.Content] = content.copy()
      merged.push(@kernel.Text(block))
      let new_messages : Array[@kernel.Message] = [
        @kernel.SystemMessage(content=merged),
      ]
      new_messages.append(messages[1:])
      new_messages
    }
    _ => {
      let new_messages : Array[@kernel.Message] = [
        @kernel.SystemMessage(content=[@kernel.Text(block)]),
      ]
      new_messages.append(messages)
      new_messages
    }
  }
}
// before_tool stays at its default (Approve unchanged): v1 implements no
// argument rewriting (parked W4b). Revalidation ruling recorded here: posoco
// core validates tool arguments reducer-side BEFORE hooks run
// (kernel_exec/reducer_model.mbt classify_rejected_outcome) and does NOT
// revalidate after a hook rewrite (pump.mbt rebuilds ExecuteTool payloads
// verbatim). Revalidating against the raw pi schema generically is not
// feasible from the host state — TypeBox ships bundled per package and no
// generic validator is reachable — so for hook-free pi tools the effective
// guard remains execution-time validation inside pi tools themselves; W4b
// must land revalidation together with rewriting.
