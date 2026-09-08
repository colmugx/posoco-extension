///|
pub(all) struct ArchivedMessage {
  id : String
  checkpoint_id : String
  ordinal : Int
  message : @posoco.Message
} derive(Eq, Debug)

///|
pub(all) struct SearchHit {
  ref : String
  checkpoint_id : String
  preview : String
  score : Int
} derive(Eq, Debug)

///|
pub(all) struct HistoryPage {
  ref : String
  content : String
  next_cursor : Int?
  done : Bool
} derive(Eq, Debug)

///|
pub struct InMemoryContinuityArchive {
  entries : Map[String, Array[ArchivedMessage]]
}

///|
pub fn InMemoryContinuityArchive::new() -> InMemoryContinuityArchive {
  { entries: Map::from_array([]) }
}

fn content_text(content : Array[@posoco.Content]) -> String {
  let parts : Array[String] = []
  for item in content {
    match item {
      @posoco.Content::Text(text) => parts.push(text)
      @posoco.Content::Image(media_type~, ..) =>
        parts.push("[image:" + media_type + "]")
    }
  }
  parts.join("\n")
}

fn message_text(message : @posoco.Message) -> String {
  match message {
    @posoco.Message::SystemMessage(content~) =>
      "system\n" + content_text(content)
    @posoco.Message::UserMessage(content~) => "user\n" + content_text(content)
    @posoco.Message::AssistantMessage(content~, tool_calls~, ..) => {
      let names : Array[String] = []
      for call in tool_calls { names.push(call.name.to_string()) }
      "assistant\n" + content_text(content) + "\ntools: " + names.join(", ")
    }
    @posoco.Message::ToolMessage(tool_name~, outcome~, ..) => {
      let body = match outcome {
        @posoco.ToolOutcome::Success(content~, ..) => content
        @posoco.ToolOutcome::ToolReportedError(content~, ..) => content
        @posoco.ToolOutcome::RuntimeFailure(error_category~, message~) =>
          error_category + ": " + message
        @posoco.ToolOutcome::NotExecuted(..) => "not executed"
      }
      "tool " + tool_name.to_string() + "\n" + body
    }
  }
}

///|
pub fn InMemoryContinuityArchive::append(
  self : InMemoryContinuityArchive,
  session_id : String,
  new_entries : Array[ArchivedMessage],
) -> Unit {
  let existing = match self.entries.get(session_id) {
    Some(items) => items
    None => []
  }
  for entry in new_entries { existing.push(entry) }
  self.entries[session_id] = existing
}

///|
pub fn InMemoryContinuityArchive::count(
  self : InMemoryContinuityArchive,
  session_id : String,
) -> Int {
  match self.entries.get(session_id) {
    Some(items) => items.length()
    None => 0
  }
}

fn preview_around(text : String, query : String, max_len : Int) -> String {
  if text.length() <= max_len { return text }
  match text.find(query) {
    Some(pos) => {
      let half = max_len / 2
      let start = if pos > half { pos - half } else { 0 }
      let end = if start + max_len < text.length() {
        start + max_len
      } else {
        text.length()
      }
      text[start:end].to_owned()
    }
    None => text[0:max_len].to_owned()
  }
}

///|
/// Lexical v0.1 search. Exact substring matches rank first; the archive keeps
/// session isolation by construction because callers always provide one host-
/// selected session key.
pub fn InMemoryContinuityArchive::search(
  self : InMemoryContinuityArchive,
  session_id : String,
  query : String,
  limit : Int,
) -> Array[SearchHit] {
  if query == "" || limit <= 0 { return [] }
  let hits : Array[SearchHit] = []
  match self.entries.get(session_id) {
    None => ()
    Some(items) => {
      for entry in items {
        let text = message_text(entry.message)
        if text.contains(query) {
          hits.push({
            ref: entry.id,
            checkpoint_id: entry.checkpoint_id,
            preview: preview_around(text, query, 300),
            score: 10,
          })
          if hits.length() >= limit { break }
        }
      }
    }
  }
  hits
}

///|
pub fn InMemoryContinuityArchive::read(
  self : InMemoryContinuityArchive,
  session_id : String,
  ref : String,
  cursor : Int,
  limit : Int,
) -> HistoryPage? {
  if cursor < 0 || limit <= 0 { return None }
  match self.entries.get(session_id) {
    None => None
    Some(items) => {
      for entry in items {
        if entry.id == ref {
          let text = message_text(entry.message)
          if cursor >= text.length() {
            return Some({ ref, content: "", next_cursor: None, done: true })
          }
          let end = if cursor + limit < text.length() {
            cursor + limit
          } else {
            text.length()
          }
          let done = end >= text.length()
          return Some({
            ref,
            content: text[cursor:end].to_owned(),
            next_cursor: if done { None } else { Some(end) },
            done,
          })
        }
      }
      None
    }
  }
}
