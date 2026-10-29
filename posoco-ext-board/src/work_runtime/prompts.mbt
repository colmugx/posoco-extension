///|
pub fn ticket_language_contract() -> String {
  "Language override for this Board ticket:\n" +
  "- The host prompt is English for stability. The user's language is the language of the ticket title/description and the most recent Inbox answer.\n" +
  "- Ask questions and write descriptions, definition-of-done items, summaries, split titles, results, and explanations in that language.\n" +
  "- If the user switches language, follow the latest user-authored text.\n" +
  "- Keep code, identifiers, file paths, commands, and quoted errors verbatim. JSON keys stay English."
}

///|
pub fn worker_prompt(
  task : Json,
  role : String,
  resuming : Bool,
  prior : Array[WorkRun],
) -> String {
  let title = task_field(task, "title")
  let description = task_field(task, "description")
  let done = task_definition_of_done(task)
  let feedback = match task_review_feedback(task) {
    Some(text) =>
      "\n\nReviewer feedback — this attempt must address it:\n" + text
    None => ""
  }
  let evidence = if role == "te" {
    let lines : Array[String] = []
    for run in prior {
      if run.role != "te" {
        lines.push(
          run.role +
          " (" +
          run.status +
          "): " +
          (match run.result {
            Some(result) => result
            None => "(no result)"
          }),
        )
      }
    }
    if lines.is_empty() {
      ""
    } else {
      "\n\nDevelopment handoff:\n" + lines.join("\n")
    }
  } else {
    ""
  }
  let opening = if resuming {
    "Resume this Board ticket after the host restarted. Continue from the recorded session; do not repeat work that is already complete.\n\n"
  } else {
    match role {
      "rd" => "Work on this Board ticket as RD. Produce the product change.\n\n"
      "set" =>
        "Work on this Board ticket as SET. Build independent verification against the user story.\n\n"
      _ =>
        "Work on this Board ticket as TE. Verify RD using SET's independent evidence.\n\n"
    }
  }
  opening +
  "Title: " +
  title +
  "\n\nDescription:\n" +
  description +
  "\n\nDefinition of done:\n" +
  (if done.is_empty() {
    "(none recorded)"
  } else {
    done.map(item => "- " + item).join("\n")
  }) +
  feedback +
  evidence +
  "\n\nReporting contract:\n" +
  "- Call report_progress when you start, after each significant milestone, when you investigate a problem, and before your final answer.\n" +
  "- Call submit_work_report with outcome, summary, changes, verification, risks, notes, open questions and artifacts before your final answer.\n" +
  "- Use ask_question_child with audience=\"po\" for requirement/design questions and audience=\"customer\" for business trade-offs; never use report_progress for questions.\n\n" +
  "Do not mutate the Board. End with a concise result and the evidence you verified."
}
