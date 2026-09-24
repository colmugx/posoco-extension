///|
/// Built-in summary prompt templates.
///
/// - `StructuredMd` — the default, fusing the pi/Cline/dsh Markdown style:
///   five fixed sections, empty sections kept with "(none)", verbatim
///   preservation of paths/commands/error strings/identifiers, no mention
///   of the compaction process itself.
/// - `KimiXml` — Kimi CLI style: six compression priorities, MUST
///   KEEP/MERGE/REMOVE/CONDENSE rules, XML-tagged output.
/// - `CodexHandoff` — one-paragraph minimal handoff for another LLM.
pub(all) enum SummaryTemplate {
  StructuredMd
  KimiXml
  CodexHandoff
} derive(Debug)

///|
pub extend SummaryTemplate with @moonbitlang/core/debug.Debug::{to_repr}

///|
fn template_system_instruction(template : SummaryTemplate) -> String {
  match template {
    StructuredMd =>
      (
        #|Summarize coding-agent context; do not continue the conversation. Output only Markdown with exactly these sections, in order:
        #|## Goal
        #|## State
        #|## Key Decisions
        #|## Next
        #|## Relevant Files
        #|State uses Done / In Progress / Blocked. Never omit a section; use "(none)" when empty. Preserve paths, commands, error strings, and identifiers verbatim. Do not mention compaction/summarization.
      )
    KimiXml =>
      (
        #|Compress coding-agent context into XML. Priority: current task; errors/solutions; final code; system context; design decisions; TODO. Keep errors, stack traces, working solutions, and current task; merge duplicates; drop failed attempts but keep lessons; keep code <=20 lines whole, otherwise signature + key logic. Output only these tags, in order:
        #|<current_focus> ... </current_focus>
        #|<environment> ... </environment>
        #|<completed_tasks> ... </completed_tasks>
        #|<active_issues> ... </active_issues>
        #|<code_state> ... </code_state>
        #|<important_context> ... </important_context>
      )
    CodexHandoff =>
      "Create a concise handoff for another LLM: current progress/decisions; constraints/preferences; remaining next steps; critical data, examples, files, commands, or references. Output only the handoff."
  }
}

///|
fn template_user_requirement(_template : SummaryTemplate) -> String {
  "Summarize now; output only the requested format."
}
