///|
/// Provider-local response handling for OpenAI's native hosted Web Search.
///
/// The shared `posoco-kit-responses` codec stays pure wire decoding. What a
/// hosted-search response needs beyond that is provider-specific, and lives
/// here:
///
/// * capture of the raw output items — hosted `web_search_call` items, reasoning
///   items, the answer message and function calls — in wire order,
///   deduplicated across `added`/`done`/`completed` snapshots, so the exact
///   provider payload survives into the next request;
/// * the versioned private `Reasoning.raw` envelope carrying that payload, plus
///   the display-only projection that turns `url_citation` annotations into
///   inline Markdown links;
/// * the search activity published on the status bar under a turn-scoped
///   segment.
///
/// The projection is UI state only. `Content::Text` may hold rewritten text
/// (escaped labels, inserted links); the wire always replays the stored raw
/// items, never the projection.

///|
/// Marker key of the provider-private hosted-search envelope. Never serialized
/// as a wire item: the encoder strips it by replaying the stored output.
fn web_search_envelope_key() -> String {
  "posoco.openai.web_search_raw_output"
}

///|
/// Envelope version understood by this decoder.
fn web_search_envelope_version() -> Int32 {
  1
}

///|
/// The publisher identity this provider owns its status segments with.
fn web_search_status_source() -> String {
  "posoco_ext_openai"
}

///|
/// Status bar position of the search activity: between the router's model
/// segments and the quota windows.
fn web_search_status_priority() -> Int32 {
  44
}

///|
/// Per-turn segment serial. Two turns in one session (parallel subagents, a
/// re-run) must not share a segment: the second turn's cleanup would otherwise
/// clear the first one's live activity. A process counter is enough — the
/// segment is display state, not durable identity.
let web_search_segment_serial : Ref[Int32] = Ref::{ val: 0, }

///|
/// A session-and-turn scoped status segment.
fn web_search_segment(session_id : String) -> String {
  web_search_segment_serial.val += 1
  "web_search:\{session_id}:\{web_search_segment_serial.val}"
}

///|
/// The one hosted tool this provider captures today. Keeping the set this
/// narrow is deliberate: capturing a type this file cannot project or replay
/// would claim support it does not have. A hosted item of any other type stays
/// an opaque provider item that the shared codec ignores, exactly as it did
/// before hosted search existed.
fn web_search_hosted_type(item_type : String) -> Bool {
  item_type == "web_search_call"
}

///|
/// Parse-level failure of a *known* hosted-search payload. Malformed payloads
/// are loud: the raw output is what the next turn replays, so a silently
/// dropped item corrupts the conversation instead of failing it.
fn web_search_response_failure(
  stage : String,
  category : String,
) -> @posoco.ModelError {
  @posoco.ModelError::ResponseParse(
    "OpenAI hosted search response failure (stage=\{stage}, category=\{category})",
  )
}

///|
/// Failure to replay a stored envelope. A rewritten visible projection or a
/// corrupted envelope is an explicit error, never a lossy fallback replay.
fn web_search_replay_failure(
  stage : String,
  category : String,
) -> @posoco.ModelError {
  @posoco.ModelError::ResponseParse(
    "OpenAI hosted search replay failure (stage=\{stage}, category=\{category})",
  )
}

///|
/// One captured output item: the raw payload, the wire `output_index` it was
/// announced at, and its provider item id.
priv struct WebSearchItem {
  order : Int32
  id : String
  item : Json
}

///|
/// One inline citation. Kept beside the items rather than merged into them so
/// the raw payload stays byte-identical to the provider's.
///
/// A citation is addressed by the item it annotates, the output item coordinate
/// and the content part. The provider item id is the strongest of the three: a
/// `done` snapshot may omit `output_index`, so an item's array position is not
/// its wire index, while the annotation event still names the item it belongs
/// to. The content coordinate matters because one message item may carry
/// several `output_text` parts with independent annotation indexes.
priv struct WebSearchCitation {
  /// Provider `item_id` of the annotated item (`""` when the event omitted it).
  item_id : String
  output_index : Int32?
  content_index : Int32?
  annotation : Json
}

///|
/// Provider-local state for one model call: the shared SSE accumulator state
/// (reasoning capture, tool-call slot remap) plus the hosted-search capture and
/// the status segment this turn owns.
priv struct OpenAIResponseState {
  sse : @responses.SseStreamState
  session_id : String
  segment : String
  items : Array[WebSearchItem]
  citations : Array[WebSearchCitation]
  mut next_synthetic_order : Int32
  /// True once the server executed (or announced) a hosted tool. A transport
  /// fallback after this point would run the search a second time, so the
  /// WebSocket path must fail instead of falling back.
  mut has_activity : Bool
  mut completed : Bool
  mut announced : Bool
  mut announced_value : String
  mut closed : Bool
}

///|
fn OpenAIResponseState::OpenAIResponseState(
  session_id : String,
) -> OpenAIResponseState {
  {
    sse: @responses.SseStreamState::SseStreamState(),
    session_id,
    segment: web_search_segment(session_id),
    items: [],
    citations: [],
    next_synthetic_order: 1_000_000,
    has_activity: false,
    completed: false,
    announced: false,
    announced_value: "",
    closed: false,
  }
}

///|
/// Release this turn's status segment and drop the capture. Idempotent: the
/// finisher calls it on success, and failure/cancellation reach it through the
/// caller's cleanup. `has_activity` is a fact about the turn and is kept.
fn OpenAIResponseState::cleanup(self : OpenAIResponseState) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  if self.announced {
    @devkit.publish_status_unregister(
      source=web_search_status_source(),
      segment=self.segment,
    )
  }
  self.announced = false
  self.announced_value = ""
  self.items.clear()
  self.citations.clear()
}

///|
/// The captured output items in wire order.
fn OpenAIResponseState::ordered_output(
  self : OpenAIResponseState,
) -> Array[Json] {
  self.items.map(fn(slot) { slot.item })
}

///|
/// Insert or refresh one captured item. Identity is the provider item id, so
/// `done` replaces `added` in place and `response.completed` cannot duplicate a
/// streamed item; an id-less snapshot is identified by its wire index instead.
/// New items take their wire index as the order; an index-less arrival is
/// appended after every indexed one, keeping arrival order among those.
fn OpenAIResponseState::upsert_item(
  self : OpenAIResponseState,
  id : String,
  order : Int32?,
  item : Json,
) -> Unit {
  if id != "" {
    for index, slot in self.items {
      if slot.id == id {
        self.items[index] = { ..slot, item, }
        return
      }
    }
  }
  match order {
    Some(wire_index) =>
      // Only an id-less slot may be replaced by position: a different, id-
      // bearing item that happens to share the index indicates something
      // stranger than a duplicate snapshot, and clobbering it would lose it.
      for index, slot in self.items {
        if slot.id == "" && slot.order == wire_index {
          self.items[index] = { order: wire_index, id, item, }
          return
        }
      }
    None => ()
  }
  let resolved = match order {
    Some(wire_index) => wire_index
    None => {
      self.next_synthetic_order += 1
      self.next_synthetic_order
    }
  }
  let mut at = self.items.length()
  for index, slot in self.items {
    if slot.order > resolved {
      at = index
      break
    }
  }
  self.items.insert(at, { order: resolved, id, item, })
}

///|
/// Announce search activity. The first announcement registers the turn's
/// segment; later ones only update its value, so a host never sees churn for
/// repeated events of the same kind.
fn OpenAIResponseState::note_activity(
  self : OpenAIResponseState,
  value : String,
) -> Unit {
  self.has_activity = true
  if self.closed || self.announced_value == value {
    return
  }
  if self.announced {
    @devkit.publish_status_update(
      source=web_search_status_source(),
      segment=self.segment,
      value~,
    )
  } else {
    @devkit.publish_status_register(
      source=web_search_status_source(),
      segment=self.segment,
      label="web_search",
      priority=web_search_status_priority(),
      value~,
      color="info",
    )
    self.announced = true
  }
  self.announced_value = value
}

///|
/// The activity a hosted `web_search_call` item states through its action.
fn web_search_action_activity(item_fields : Map[String, Json]) -> String? {
  match item_fields.get("action") {
    Some(Json::Object(action)) =>
      match action.get("type") {
        Some(Json::String("search")) => Some("searching")
        Some(Json::String("open_page")) => Some("open_page")
        Some(Json::String("find_in_page")) => Some("find_in_page")
        _ => None
      }
    _ => None
  }
}

///|
/// Record what a captured item says about the turn: whether the server ran a
/// hosted tool, and which search activity to show.
fn OpenAIResponseState::note_item(
  self : OpenAIResponseState,
  item_fields : Map[String, Json],
) -> Unit raise @posoco.ModelError {
  match item_fields.get("type") {
    Some(Json::String(item_type)) =>
      if web_search_hosted_type(item_type) {
        self.has_activity = true
        match web_search_action_activity(item_fields) {
          Some(value) => self.note_activity(value)
          None => ()
        }
      }
    Some(_) =>
      raise web_search_response_failure("output_item.type", "wrong_type")
    None => ()
  }
}

///|
/// Capture one `output_item.added`/`done` snapshot. A missing or non-object
/// `item` is the shared decoder's diagnosis — it raises right after this
/// capture pass, so nothing is swallowed by returning here.
fn web_search_capture_output_item(
  state : OpenAIResponseState,
  event_fields : Map[String, Json],
) -> Unit raise @posoco.ModelError {
  let item_fields = match event_fields.get("item") {
    Some(Json::Object(item_fields)) => item_fields
    _ => return
  }
  let id = match item_fields.get("id") {
    Some(Json::String(id)) => id
    Some(Json::Null) | None => ""
    Some(_) => raise web_search_response_failure("item.id", "wrong_type")
  }
  let order = match event_fields.get("output_index") {
    Some(Json::Number(index, ..)) => Some(index.to_int())
    Some(Json::Null) | None => None
    Some(_) => raise web_search_response_failure("output_index", "wrong_type")
  }
  state.upsert_item(id, order, Json::object(item_fields))
  state.note_item(item_fields)
}

///|
/// Capture one `response.output_text.annotation.added` payload, the streaming
/// form of the citations the `done` message item repeats inline. Both
/// coordinates are captured: a message item may hold several text parts, so
/// matching on the output item alone would bind a citation to the wrong part.
fn web_search_capture_annotation(
  state : OpenAIResponseState,
  event_fields : Map[String, Json],
) -> Unit raise @posoco.ModelError {
  let annotation = match event_fields.get("annotation") {
    Some(Json::Object(_) as annotation) => annotation
    Some(_) =>
      raise web_search_response_failure("annotation.added", "wrong_type")
    None => raise web_search_response_failure("annotation.added", "missing")
  }
  let output_index = web_search_event_index(
    event_fields, "output_index", "annotation.added.output_index",
  )
  let content_index = web_search_event_index(
    event_fields, "content_index", "annotation.added.content_index",
  )
  let item_id = match event_fields.get("item_id") {
    Some(Json::String(item_id)) => item_id
    Some(Json::Null) | None => ""
    Some(_) =>
      raise web_search_response_failure(
        "annotation.added.item_id", "wrong_type",
      )
  }
  state.has_activity = true
  for existing in state.citations {
    if existing.item_id == item_id &&
      existing.output_index == output_index &&
      existing.content_index == content_index &&
      existing.annotation == annotation {
      return
    }
  }
  state.citations.push({ item_id, output_index, content_index, annotation, })
}

///|
/// One optional event coordinate (`output_index` / `content_index`): absent is
/// an unattributed citation, a wrong type is a malformed known payload.
fn web_search_event_index(
  event_fields : Map[String, Json],
  field : String,
  stage : String,
) -> Int32? raise @posoco.ModelError {
  match event_fields.get(field) {
    Some(Json::Number(index, ..)) => Some(index.to_int())
    Some(Json::Null) | None => None
    Some(_) => raise web_search_response_failure(stage, "wrong_type")
  }
}

///|
/// Merge a terminal `response.output` array into the capture. Items already
/// seen are refreshed in place; genuinely new ones keep their array position
/// as the wire order.
fn web_search_capture_response_output(
  state : OpenAIResponseState,
  response_fields : Map[String, Json],
) -> Unit raise @posoco.ModelError {
  let items = match response_fields.get("output") {
    Some(Json::Array(items)) => items
    Some(Json::Null) | None => return
    Some(_) => raise web_search_response_failure("output", "wrong_type")
  }
  for position, item in items {
    let item_fields = match item {
      Json::Object(item_fields) => item_fields
      _ => raise web_search_response_failure("output", "not_object")
    }
    let id = match item_fields.get("id") {
      Some(Json::String(id)) => id
      Some(Json::Null) | None => ""
      Some(_) => raise web_search_response_failure("output.id", "wrong_type")
    }
    state.upsert_item(id, Some(position), Json::object(item_fields))
    // The terminal array restates items that already streamed: it still proves
    // the server ran a hosted tool, but its actions are history. Re-announcing
    // them would revive a finished activity — and a non-stream response, which
    // has no progress to show, would publish a segment it never announced.
    match item_fields.get("type") {
      Some(Json::String(item_type)) =>
        if web_search_hosted_type(item_type) {
          state.has_activity = true
        }
      _ => ()
    }
  }
}

///|
/// Capture one Responses stream event before the shared decoder sees it.
/// Everything the shared decoder owns stays there: an unparsable line, a
/// non-object event or a missing `type` returns unchanged, and the shared call
/// that follows raises the canonical diagnostic for it.
fn web_search_capture_event(
  data : String,
  state : OpenAIResponseState,
) -> Unit raise @posoco.ModelError {
  let event = @json.parse(data) catch { _ => return }
  guard event is Json::Object(event_fields) else { return }
  let event_type = match event_fields.get("type") {
    Some(Json::String(event_type)) => event_type
    _ => return
  }
  match event_type {
    "response.output_item.added" | "response.output_item.done" =>
      web_search_capture_output_item(state, event_fields)
    "response.output_text.annotation.added" =>
      web_search_capture_annotation(state, event_fields)
    // Progress events are display-only: the result and the citations ride the
    // items, but the activity they announce is what a host renders while the
    // server is still working.
    "response.web_search_call.in_progress"
    | "response.web_search_call.searching" => state.note_activity("searching")
    "response.completed" =>
      match event_fields.get("response") {
        Some(Json::Object(response_fields)) =>
          web_search_capture_response_output(state, response_fields)
        _ => ()
      }
    _ => ()
  }
}

///|
/// Decode one streamed response event: provider-local capture first, then the
/// shared decoder. Returns true when the shared decoder saw the terminal event.
fn openai_process_response_event(
  data : String,
  acc : @posoco.StreamAccumulator,
  on_chunk : (@posoco.StreamChunk) -> Unit,
  state : OpenAIResponseState,
) -> Bool raise @posoco.ModelError {
  web_search_capture_event(data, state)
  let completed = @responses.process_responses_sse(
    provider="OpenAI",
    data,
    acc,
    on_chunk,
    state=state.sse,
  )
  state.completed = completed
  completed
}

///|
/// Whether any captured item is one the server executed.
fn web_search_has_hosted_output(items : Array[Json]) -> Bool {
  for item in items {
    match item {
      Json::Object(fields) =>
        match fields.get("type") {
          Some(Json::String(item_type)) =>
            if web_search_hosted_type(item_type) {
              return true
            }
          _ => ()
        }
      _ => ()
    }
  }
  false
}

///|
/// Whether a captured citation says where a source came from.
fn web_search_is_url_citation(annotation : Json) -> Bool {
  match annotation {
    Json::Object(fields) =>
      match fields.get("type") {
        Some(Json::String("url_citation")) => true
        _ => false
      }
    _ => false
  }
}

///|
/// Whether the response carries any `url_citation`: captured from its own
/// event, or inline in the message item when the provider sent only the item.
fn web_search_has_citation(
  output : Array[Json],
  citations : Array[WebSearchCitation],
) -> Bool {
  for citation in citations {
    if web_search_is_url_citation(citation.annotation) {
      return true
    }
  }
  for item in output {
    match item {
      Json::Object(fields) =>
        match fields.get("content") {
          Some(Json::Array(parts)) =>
            for part in parts {
              match part {
                Json::Object(part_fields) =>
                  match part_fields.get("annotations") {
                    Some(Json::Array(annotations)) =>
                      for annotation in annotations {
                        if web_search_is_url_citation(annotation) {
                          return true
                        }
                      }
                    _ => ()
                  }
                _ => ()
              }
            }
          _ => ()
        }
      _ => ()
    }
  }
  false
}

///|
/// Only http(s) destinations can become links. URI punctuation safe in a
/// Markdown destination is kept; parentheses and non-ASCII characters are
/// percent-encoded so legitimate source URLs survive without breaking out of
/// the link. Controls and other unsupported characters are not linkified.
fn web_search_safe_url(url : String) -> String? {
  let scheme_length = if url.has_prefix("https://") {
    8
  } else if url.has_prefix("http://") {
    7
  } else {
    return None
  }
  if url.length() <= scheme_length || url.length() > 2048 {
    return None
  }
  let escaped = StringBuilder()
  let hex = "0123456789ABCDEF".to_array()
  for c in url {
    let ok = (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      c == '-' ||
      c == '.' ||
      c == '_' ||
      c == '~' ||
      c == ':' ||
      c == '/' ||
      c == '?' ||
      c == '#' ||
      c == '[' ||
      c == ']' ||
      c == '@' ||
      c == '!' ||
      c == '$' ||
      c == '&' ||
      c == '\'' ||
      c == '*' ||
      c == '+' ||
      c == ',' ||
      c == ';' ||
      c == '=' ||
      c == '%'
    if ok {
      escaped.write_char(c)
    } else if c == '(' || c == ')' || c > '~' {
      for byte in @utf8.encode(c.to_string()) {
        let value = byte.to_int()
        escaped.write_char('%')
        escaped.write_char(hex[value / 16])
        escaped.write_char(hex[value % 16])
      }
    } else {
      return None
    }
  }
  Some(escaped.to_string())
}

///|
/// UTF-16 length of a character array. MoonBit strings are UTF-16: `length()`
/// counts code units while iteration yields Unicode scalars, so every offset
/// the provider states is converted explicitly here instead of mixing the two.
fn web_search_utf16_length(chars : Array[Char]) -> Int32 {
  let mut length = 0
  for c in chars {
    length += c.utf16_len()
  }
  length
}

///|
/// The Unicode scalar position of a UTF-16 offset, or `None` when the offset
/// does not address a character boundary (inside a surrogate pair) or lies
/// outside the text. Only scalars can be sliced, so such an offset cannot be
/// placed truthfully.
fn web_search_scalar_offset(
  chars : Array[Char],
  utf16_offset : Int32,
) -> Int32? {
  let mut units = 0
  for position, c in chars {
    if units == utf16_offset {
      return Some(position)
    }
    let width = c.utf16_len()
    if units + width > utf16_offset {
      return None
    }
    units += width
  }
  if units == utf16_offset {
    Some(chars.length())
  } else {
    None
  }
}

///|
/// One integer field of a known payload; a malformed one is loud.
fn web_search_index_field(
  fields : Map[String, Json],
  stage : String,
) -> Int32 raise @posoco.ModelError {
  match fields.get(stage) {
    Some(Json::Number(value, ..)) => value.to_int()
    Some(_) => raise web_search_response_failure(stage, "wrong_type")
    None => raise web_search_response_failure(stage, "missing")
  }
}

///|
/// One placeable citation: scalar start, scalar end (exclusive), safe URL.
fn web_search_citation_span(
  annotation : Json,
  chars : Array[Char],
  utf16_length : Int32,
) -> (Int32, Int32, String)? raise @posoco.ModelError {
  let fields = match annotation {
    Json::Object(fields) => fields
    _ => raise web_search_response_failure("annotation", "not_object")
  }
  let kind = match fields.get("type") {
    Some(Json::String(kind)) => kind
    Some(_) =>
      raise web_search_response_failure("annotation.type", "wrong_type")
    None => raise web_search_response_failure("annotation.type", "missing")
  }
  if kind != "url_citation" {
    return None
  }
  let start = web_search_index_field(fields, "start_index")
  let end = web_search_index_field(fields, "end_index")
  let url = match fields.get("url") {
    Some(Json::String(url)) => url
    Some(_) => raise web_search_response_failure("annotation.url", "wrong_type")
    None => raise web_search_response_failure("annotation.url", "missing")
  }
  // An offset that cannot address this text, or a span with no visible words,
  // is kept verbatim in the envelope but cannot be linked in the projection.
  if start < 0 || end <= start || end > utf16_length {
    return None
  }
  let start_position = match web_search_scalar_offset(chars, start) {
    Some(position) => position
    None => return None
  }
  let end_position = match web_search_scalar_offset(chars, end) {
    Some(position) => position
    None => return None
  }
  if end_position <= start_position {
    return None
  }
  match web_search_safe_url(url) {
    Some(safe) => Some((start_position, end_position, safe))
    None => None
  }
}

///|
/// Order citation spans by position. A response carries a handful of them, and
/// this package has no sorting import, so a local insertion sort keeps the
/// dependency set of the response path unchanged.
fn web_search_sort_spans(spans : Array[(Int32, Int32, String)]) -> Unit {
  for position in 1..<spans.length() {
    let mut cursor = position
    while cursor > 0 && spans[cursor - 1].0 > spans[cursor].0 {
      let carried = spans[cursor - 1]
      spans[cursor - 1] = spans[cursor]
      spans[cursor] = carried
      cursor -= 1
    }
  }
}

///|
/// Insert the citations as inline Markdown links at their positions. Text
/// outside a cited span is the provider's own and stays untouched; the label is
/// the cited words, with `[`/`]`/`\` escaped so no span can close the link
/// early.
///
/// Several sources may cite the same words. The first span keeps those words as
/// its label; every further source for text that is already rendered is
/// appended beside it as `[source](url)`, so no source is lost and no body text
/// is repeated. An exact `(span, url)` repeat is one citation, not two.
fn web_search_inline_citations(
  chars : Array[Char],
  spans : Array[(Int32, Int32, String)],
) -> String {
  let buffer = StringBuilder::StringBuilder()
  let emitted : Array[(Int32, Int32, String)] = []
  let mut cursor = 0
  for span in spans {
    let (start, end, url) = span
    let mut already_emitted = false
    for rendered in emitted {
      if rendered.0 == start && rendered.1 == end && rendered.2 == url {
        already_emitted = true
      }
    }
    if already_emitted {
      continue
    }
    if start < cursor {
      // A further source for words already shown: cite it next to the first
      // link instead of dropping the source or repeating the words.
      buffer.write_string("[source](")
      buffer.write_string(url)
      buffer.write_char(')')
      emitted.push(span)
      continue
    }
    for position in cursor..<start {
      buffer.write_char(chars[position])
    }
    buffer.write_char('[')
    for position in start..<end {
      let c = chars[position]
      if c == '[' || c == ']' || c == '\\' {
        buffer.write_char('\\')
      }
      buffer.write_char(c)
    }
    buffer.write_string("](")
    buffer.write_string(url)
    buffer.write_char(')')
    cursor = end
    emitted.push(span)
  }
  for position in cursor..<chars.length() {
    buffer.write_char(chars[position])
  }
  buffer.to_string()
}

///|
/// Project one text part: the provider's text with its citations inlined.
fn web_search_inline_text(
  text : String,
  annotations : Array[Json],
) -> String raise @posoco.ModelError {
  if annotations.is_empty() {
    return text
  }
  let chars = text.to_array()
  let utf16_length = web_search_utf16_length(chars)
  let spans : Array[(Int32, Int32, String)] = []
  for annotation in annotations {
    match web_search_citation_span(annotation, chars, utf16_length) {
      Some(span) => spans.push(span)
      None => ()
    }
  }
  if spans.is_empty() {
    return text
  }
  web_search_sort_spans(spans)
  web_search_inline_citations(chars, spans)
}

///|
/// The annotations that apply to one content part: the item's own array when it
/// carries one (the `done` snapshot is authoritative), otherwise the
/// `annotation.added` payloads captured for that output **and** content index —
/// a message item may hold several text parts with independent indexes.
fn web_search_part_citations(
  part_fields : Map[String, Json],
  item_id : String,
  output_index : Int32,
  content_index : Int32,
  captured : Array[WebSearchCitation],
) -> Array[Json] raise @posoco.ModelError {
  match part_fields.get("annotations") {
    Some(Json::Array(annotations)) => annotations
    Some(Json::Null) | None => {
      let fallback : Array[Json] = []
      for citation in captured {
        // The provider item id is the strongest identity: a `done` snapshot may
        // omit `output_index`, which makes this item's array position differ
        // from the wire index the annotation event states. Coordinates remain
        // the fallback when either side omits the id.
        let item_matches = if citation.item_id != "" && item_id != "" {
          citation.item_id == item_id
        } else {
          match citation.output_index {
            Some(index) => index == output_index
            None => true
          }
        }
        // A missing content index names the first text part — the only part a
        // single-part message can have — and must never bind to later parts.
        let part_matches = match citation.content_index {
          Some(index) => index == content_index
          None => content_index == 0
        }
        if item_matches && part_matches {
          fallback.push(citation.annotation)
        }
      }
      fallback
    }
    Some(_) =>
      raise web_search_response_failure(
        "message.output_text.annotations", "wrong_type",
      )
  }
}

///|
/// Append the visible content of one message item to `content`.
fn web_search_project_message(
  fields : Map[String, Json],
  output_index : Int32,
  citations : Array[WebSearchCitation],
  content : Array[@posoco.Content],
) -> Unit raise @posoco.ModelError {
  let parts = match fields.get("content") {
    Some(Json::Array(parts)) => parts
    Some(Json::String(text)) => {
      // The plain-string shorthand carries no annotations.
      content.push(@posoco.Content::Text(text))
      return
    }
    Some(Json::Null) | None => return
    Some(_) =>
      raise web_search_response_failure("message.content", "wrong_type")
  }
  for content_index, part in parts {
    let part_fields = match part {
      Json::Object(part_fields) => part_fields
      _ =>
        raise web_search_response_failure("message.content_item", "not_object")
    }
    match part_fields.get("type") {
      Some(Json::String("output_text" | "input_text" | "text")) => {
        let text = match part_fields.get("text") {
          Some(Json::String(text)) => text
          Some(_) =>
            raise web_search_response_failure(
              "message.output_text.text", "wrong_type",
            )
          None =>
            raise web_search_response_failure(
              "message.output_text.text", "missing",
            )
        }
        let item_id = match fields.get("id") {
          Some(Json::String(id)) => id
          Some(Json::Null) | None => ""
          Some(_) =>
            raise web_search_response_failure("message.id", "wrong_type")
        }
        let annotations = web_search_part_citations(
          part_fields, item_id, output_index, content_index, citations,
        )
        content.push(
          @posoco.Content::Text(web_search_inline_text(text, annotations)),
        )
      }
      // Non-text parts (refusals, images) carry no visible text projection.
      Some(Json::String(_)) => ()
      Some(_) =>
        raise web_search_response_failure(
          "message.content_item.type", "wrong_type",
        )
      None =>
        raise web_search_response_failure(
          "message.content_item.type", "missing",
        )
    }
  }
}

///|
/// The display projection of the captured output: one `Content::Text` per
/// visible text part, citations inlined at their positions. Empty when the
/// response carries no message item, in which case the streamed text stands.
fn web_search_projected_content(
  output : Array[Json],
  citations : Array[WebSearchCitation],
) -> Array[@posoco.Content] raise @posoco.ModelError {
  let content : Array[@posoco.Content] = []
  for output_index, item in output {
    match item {
      Json::Object(fields) =>
        match fields.get("type") {
          Some(Json::String("message")) =>
            web_search_project_message(fields, output_index, citations, content)
          _ => ()
        }
      _ => ()
    }
  }
  content
}

///|
/// The versioned envelope payload: the raw output verbatim plus the captured
/// citations, both deep-copied so the envelope never aliases the response tree
/// the caller still holds.
fn web_search_envelope_payload(
  output : Array[Json],
  citations : Array[WebSearchCitation],
) -> Json {
  let fields : Array[(String, Json)] = [
    ("version", Json::number(web_search_envelope_version().to_double())),
    ("output", Json::array(output.map(json_deep_copy))),
  ]
  if !citations.is_empty() {
    let encoded = citations.map(fn(citation) {
      let entry : Array[(String, Json)] = []
      match citation.output_index {
        Some(index) =>
          entry.push(("output_index", Json::number(index.to_double())))
        None => ()
      }
      match citation.content_index {
        Some(index) =>
          entry.push(("content_index", Json::number(index.to_double())))
        None => ()
      }
      if citation.item_id != "" {
        entry.push(("item_id", Json::string(citation.item_id)))
      }
      entry.push(("annotation", json_deep_copy(citation.annotation)))
      Json::object(Map::from_array(entry))
    })
    fields.push(("citations", Json::array(encoded)))
  }
  Json::object(Map::from_array(fields))
}

///|
/// Decode the envelope's citation list. A missing list means the message item
/// carried its annotations inline, which is the common case.
fn web_search_envelope_citations(
  payload : Map[String, Json],
) -> Array[WebSearchCitation] raise @posoco.ModelError {
  let citations : Array[WebSearchCitation] = []
  let entries = match payload.get("citations") {
    Some(Json::Array(entries)) => entries
    Some(Json::Null) | None => return citations
    Some(_) =>
      raise web_search_replay_failure("envelope.citations", "wrong_type")
  }
  for entry in entries {
    let fields = match entry {
      Json::Object(fields) => fields
      _ => raise web_search_replay_failure("envelope.citations", "not_object")
    }
    let annotation = match fields.get("annotation") {
      Some(Json::Object(_) as annotation) => annotation
      Some(_) =>
        raise web_search_replay_failure("envelope.annotation", "wrong_type")
      None => raise web_search_replay_failure("envelope.annotation", "missing")
    }
    let output_index = match fields.get("output_index") {
      Some(Json::Number(index, ..)) => Some(index.to_int())
      Some(Json::Null) | None => None
      Some(_) =>
        raise web_search_replay_failure("envelope.output_index", "wrong_type")
    }
    // A stored envelope written before content indexes were captured simply
    // has no `content_index`: it stays an unattributed citation.
    let content_index = match fields.get("content_index") {
      Some(Json::Number(index, ..)) => Some(index.to_int())
      Some(Json::Null) | None => None
      Some(_) =>
        raise web_search_replay_failure("envelope.content_index", "wrong_type")
    }
    let item_id = match fields.get("item_id") {
      Some(Json::String(item_id)) => item_id
      Some(Json::Null) | None => ""
      Some(_) =>
        raise web_search_replay_failure("envelope.item_id", "wrong_type")
    }
    citations.push({ item_id, output_index, content_index, annotation, })
  }
  citations
}

///|
/// The concatenated reasoning summary of the captured items, the only visible
/// reasoning text an item exposes when the stream sent no summary deltas.
fn web_search_items_summary(
  items : Array[Json],
) -> String raise @posoco.ModelError {
  let (_, summary) = @responses.extract_reasoning_items(
    provider="OpenAI",
    Json::array(items),
  )
  summary
}

///|
/// The hosted completion: the visible projection plus the private envelope that
/// carries the exact raw output for the next request. `Reasoning.content` keeps
/// the summary text the turn already had.
fn openai_hosted_completion(
  completion : @posoco.Completion,
  output : Array[Json],
  citations : Array[WebSearchCitation],
  summary : String,
) -> @posoco.Completion raise @posoco.ModelError {
  for item in output {
    match item {
      Json::Object(fields) if fields.get("type") ==
        Some(Json::string("web_search_call")) =>
        match fields.get("status") {
          Some(Json::String("completed" | "failed")) => ()
          _ =>
            raise web_search_response_failure(
              "web_search_call.status", "not_terminal",
            )
        }
      _ => ()
    }
  }
  let projected = web_search_projected_content(output, citations)
  // A hosted turn may produce no message item at all (a bare tool call). The
  // streamed text then stands as the visible content.
  let content = if projected.is_empty() {
    completion.message.content
  } else {
    projected
  }
  // Visible reasoning text: the streamed summary wins, then whatever the
  // completion already carried, then the summary the raw items state (the
  // non-stream shape, where no summary delta ever arrives).
  let reason_text = if summary != "" {
    summary
  } else {
    match completion.message.reasoning {
      Some(reasoning) =>
        if reasoning.content != "" {
          reasoning.content
        } else {
          web_search_items_summary(output)
        }
      None => web_search_items_summary(output)
    }
  }
  let envelope = Json::object(
    Map::from_array([
      (
        web_search_envelope_key(),
        web_search_envelope_payload(output, citations),
      ),
    ]),
  )
  @posoco.Completion::Completion(
    content~,
    tool_calls=completion.message.tool_calls,
    reasoning=Some(@posoco.Reasoning::{
      content: reason_text,
      raw: Some(envelope),
    }),
    finish_reason=completion.message.finish_reason,
    usage=completion.usage,
  )
}

///|
/// Finish one streamed turn. Without hosted output or citations the pre-existing
/// reasoning-only attachment stands untouched; with them the raw output is
/// preserved in the private envelope and the visible text gains inline
/// citations. Either way this turn's status segment is released.
fn openai_finish_response(
  completion : @posoco.Completion,
  state : OpenAIResponseState,
) -> @posoco.Completion raise @posoco.ModelError {
  defer state.cleanup()
  if state.has_activity && !state.completed {
    raise web_search_response_failure("terminal", "missing_response_completed")
  }
  let output = state.ordered_output()
  let citations = state.citations.copy()
  if !web_search_has_hosted_output(output) &&
    !web_search_has_citation(output, citations) {
    return attach_reasoning_items_responses(completion, state.sse)
  }
  // A text delta alone cannot be persisted as an opaque output item. Reject
  // incomplete/mismatched snapshots now, rather than returning an answer that
  // silently loses text or fails only on the next request's replay check.
  let streamed = completion.message.content
    .map(fn(part) {
      match part {
        Text(text) => text
        _ => ""
      }
    })
    .join("")
  if streamed != "" {
    let original = StringBuilder()
    for item in output {
      match item {
        Json::Object(fields) if fields.get("type") ==
          Some(Json::string("message")) =>
          original.write_string(
            @responses.message_item_text(provider="OpenAI", fields),
          )
        _ => ()
      }
    }
    if original.to_string() != streamed {
      raise web_search_response_failure("output.message", "stream_mismatch")
    }
  }
  openai_hosted_completion(completion, output, citations, state.sse.summary)
}

///|
/// Finish one non-streamed response through the same projection and envelope.
/// A non-streaming response has no incremental activity to announce, so the
/// session-scoped state this helper opens publishes nothing and is released
/// immediately; it exists so both transports decode the output identically.
fn openai_parse_response(
  response : Json,
  session_id : String,
) -> @posoco.Completion raise @posoco.ModelError {
  let completion = @responses.parse_responses_response(
    provider="OpenAI",
    response,
  )
  let state = OpenAIResponseState::OpenAIResponseState(session_id)
  defer state.cleanup()
  match response {
    Json::Object(response_fields) =>
      web_search_capture_response_output(state, response_fields)
    _ => ()
  }
  let output = state.ordered_output()
  let citations = state.citations.copy()
  if !web_search_has_hosted_output(output) &&
    !web_search_has_citation(output, citations) {
    return completion
  }
  let summary = match completion.message.reasoning {
    Some(reasoning) => reasoning.content
    None => ""
  }
  openai_hosted_completion(completion, output, citations, summary)
}

///|
/// The stored raw output of a message carrying the hosted-search envelope, or
/// `None` for an ordinary message (including one carrying the compact raw-window
/// anchor, which owns a different key). A corrupted envelope — unknown version,
/// missing or non-array output, malformed citation list — fails loudly instead
/// of degrading into a lossy replay.
fn web_search_envelope_of(
  msg : @posoco.Message,
) -> (Array[Json], Array[WebSearchCitation])? raise @posoco.ModelError {
  match msg {
    @posoco.Message::AssistantMessage(reasoning~, ..) =>
      match reasoning {
        Some({ raw: Some(Json::Object(fields)), .. }) =>
          match fields.get(web_search_envelope_key()) {
            Some(value) => {
              let payload = match value {
                Json::Object(payload) => payload
                _ => raise web_search_replay_failure("envelope", "wrong_type")
              }
              match payload.get("version") {
                Some(Json::Number(version, ..)) =>
                  // Compare the whole number: truncating would read 1.5 as v1.
                  if version != web_search_envelope_version().to_double() {
                    raise web_search_replay_failure("envelope", "version")
                  }
                Some(_) =>
                  raise web_search_replay_failure("envelope", "version")
                None => raise web_search_replay_failure("envelope", "version")
              }
              let output = match payload.get("output") {
                Some(Json::Array(items)) => items
                Some(Json::Null) | None =>
                  raise web_search_replay_failure("envelope", "missing_output")
                Some(_) =>
                  raise web_search_replay_failure("envelope", "wrong_type")
              }
              let citations = web_search_envelope_citations(payload)
              Some((output, citations))
            }
            None => None
          }
        _ => None
      }
    _ => None
  }
}

///|
/// Prove the visible message is still exactly the projection of the stored
/// output before replaying it: rewritten content or tool calls would otherwise
/// send a window that no longer matches the state the model was given.
fn web_search_validate_projection(
  msg : @posoco.Message,
  output : Array[Json],
  citations : Array[WebSearchCitation],
) -> Unit raise @posoco.ModelError {
  guard msg is @posoco.Message::AssistantMessage(content~, tool_calls~, ..) else {
    raise web_search_replay_failure("message", "not_assistant")
  }
  let projected = web_search_projected_content(output, citations)
  if projected.length() != content.length() {
    raise web_search_replay_failure("projection", "content")
  }
  for position, part in projected {
    if part != content[position] {
      raise web_search_replay_failure("projection", "content")
    }
  }
  let (stored_calls, _) = @responses.extract_tool_calls(
    provider="OpenAI",
    Json::array(output),
  )
  if stored_calls.length() != tool_calls.length() {
    raise web_search_replay_failure("projection", "tool_calls")
  }
  for position, call in stored_calls {
    if call != tool_calls[position] {
      raise web_search_replay_failure("projection", "tool_calls")
    }
  }
}

///|
/// The provider's input encoder for one message. A hosted-search message
/// replays its stored raw output exactly once — the reasoning item, the hosted
/// `web_search_call` items, the message item and its function calls, in wire
/// order — after proving the visible projection still matches. An ordinary
/// message delegates to the shared encoder, so no host of this provider needs a
/// special case.
fn openai_message_to_responses_items(
  msg : @posoco.Message,
) -> Array[Json] raise @posoco.ModelError {
  match web_search_envelope_of(msg) {
    None => @responses.message_to_responses_items(msg)
    Some((output, citations)) => {
      web_search_validate_projection(msg, output, citations)
      output.map(json_deep_copy)
    }
  }
}
