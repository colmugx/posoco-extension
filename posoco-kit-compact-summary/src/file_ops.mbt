///|
/// Files touched by tool calls in a transcript span, split into reads and
/// modifications. Deduplicated, in first-occurrence order; empty lists are
/// valid. Feeds the summary's file manifest and the progressive stage's
/// cumulative file tracking.
pub(all) struct FileOps {
  read_files : Array[String]
  modified_files : Array[String]
} derive(Eq, Debug)

///|
/// Extract the file manifest from AssistantMessage tool calls. A tool whose
/// name contains "read" contributes to `read_files`; "write" or "edit" to
/// `modified_files` ("read" wins if a name matches both). Paths are taken
/// from the `path`, `file_path`, `target_file`, `old_file_path`,
/// `new_file_path` string values in the arguments JSON, plus the `path` of
/// each element of a `files` array. Arguments that are not objects, and
/// values that are not strings, are skipped silently.
pub fn extract_file_ops(messages : Array[@posoco.Message]) -> FileOps {
  let read_files : Array[String] = []
  let modified_files : Array[String] = []
  for message in messages {
    match message {
      AssistantMessage(tool_calls~, ..) =>
        for call in tool_calls {
          let name = call.name.to_string().to_lower()
          if name.contains("read") {
            collect_paths(call.arguments, read_files)
          } else if name.contains("write") || name.contains("edit") {
            collect_paths(call.arguments, modified_files)
          }
        }
      _ => ()
    }
  }
  { read_files, modified_files, }
}

///|
fn collect_paths(arguments : Json, out : Array[String]) -> Unit {
  match arguments {
    Object(fields) => {
      for
        key in [
          "path", "file_path", "target_file", "old_file_path", "new_file_path",
        ] {
        match fields.get(key) {
          Some(String(value)) => push_unique(out, value)
          _ => ()
        }
      }
      match fields.get("files") {
        Some(Array(items)) =>
          for item in items {
            match item {
              Object(entry) =>
                match entry.get("path") {
                  Some(String(value)) => push_unique(out, value)
                  _ => ()
                }
              _ => ()
            }
          }
        _ => ()
      }
    }
    _ => ()
  }
}

///|
fn push_unique(out : Array[String], value : String) -> Unit {
  if !out.contains(value) {
    out.push(value)
  }
}
