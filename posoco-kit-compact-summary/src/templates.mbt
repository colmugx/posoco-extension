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
fn template_system_instruction(template : SummaryTemplate) -> String {
  match template {
    StructuredMd =>
      (
        #|You are a context summarization assistant. Read the conversation between a user and an AI coding assistant, then produce a structured summary following the exact format specified below. Do NOT continue the conversation. Do NOT respond to any questions in the conversation. ONLY output the structured summary.
        #|
        #|Format the summary in Markdown with exactly these five sections, in this order:
        #|
        #|## Goal
        #|## State
        #|## Key Decisions
        #|## Next
        #|## Relevant Files
        #|
        #|Rules:
        #|- The State section reports progress as Done / In Progress / Blocked items.
        #|- Never omit a section. If a section has no content, write "(none)".
        #|- Preserve file paths, commands, error strings, and identifiers verbatim.
        #|- Do not mention that a compaction or summarization happened.
        #|- Output only the summary text itself, with no preamble and no tool calls.
      )
    KimiXml =>
      (
        #|You are a context compaction engine for a coding agent. Condense the conversation into a structured XML snapshot so another agent can resume with full context.
        #|
        #|Compression priorities, highest first:
        #|1. Current Task State
        #|2. Errors & Solutions
        #|3. Code Evolution (final working versions only)
        #|4. System Context
        #|5. Design Decisions
        #|6. TODO
        #|
        #|MUST KEEP: error messages, stack traces, working solutions, the current task.
        #|MERGE: duplicate or overlapping information into single statements.
        #|REMOVE: failed attempts (keep the lessons learned).
        #|CONDENSE: keep the full version of code under 20 lines, otherwise the signature plus key logic.
        #|
        #|Output the summary wrapped in exactly these XML tags, in this order:
        #|<current_focus> ... </current_focus>
        #|<environment> ... </environment>
        #|<completed_tasks> ... </completed_tasks>
        #|<active_issues> ... </active_issues>
        #|<code_state> ... </code_state>
        #|<important_context> ... </important_context>
      )
    CodexHandoff =>
      (
        #|You are performing a CONTEXT CHECKPOINT COMPACTION. Create a handoff summary for another LLM that will resume the task. Include: current progress and key decisions; important context, constraints, or user preferences; what remains to be done (clear next steps); any critical data, examples, or references needed to continue. Be concise, structured, and focused on helping the next LLM seamlessly continue the work. Output only the summary.
      )
  }
}

///|
fn template_user_requirement(template : SummaryTemplate) -> String {
  match template {
    StructuredMd =>
      "Summarize the conversation above into the structured five-section format defined in the system instructions. Output only the summary."
    KimiXml =>
      "Condense the conversation above into the XML snapshot defined in the system instructions. Output only the XML snapshot."
    CodexHandoff =>
      "Summarize the conversation above as the handoff summary described in the system instructions. Output only the summary."
  }
}
