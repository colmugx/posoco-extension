///|
/// The `tool_list` handler: browse or keyword-search the folded catalog.
/// Results are grouped by extension — one match returns the whole group —
/// and each tool carries name, description, and full JSON input schema, so
/// the model can go straight to `tool_execute`.

///|
/// Max description characters shown per tool in listings.
const LIST_DESC_CAP = 200

///|
/// Strip the packaging prefix from a provenance id for display: extensions
/// stamp `posoco_ext_<name>` as provenance, but the declared manifest id is
/// just `<name>` — show that.
fn display_id(provenance : String) -> String {
  if provenance.has_prefix("posoco_ext_") {
    provenance["posoco_ext_".length():].to_owned()
  } else {
    provenance
  }
}

///|
/// One extension group: display id and its deferred entries in declaration
/// order.
priv struct ToolGroup {
  id : String
  entries : Array[LazyEntry]
}

///|
/// Group the deferred index by provenance, first-seen order.
fn LazyTools::groups(self : LazyTools) -> Array[ToolGroup] {
  let order : Array[String] = []
  let by_source : Map[String, ToolGroup] = Map::from_array([])
  for entry in self.entries {
    let source = match entry.def.provenance {
      Some(p) => p
      None => "(unlabeled)"
    }
    match by_source.get(source) {
      Some(group) => group.entries.push(entry)
      None => {
        order.push(source)
        by_source[source] = { id: display_id(source), entries: [entry], }
      }
    }
  }
  order.map(fn(source) { by_source[source] })
}

///|
/// Parse a space-separated query into lowercase keywords. Empty keywords
/// (repeated spaces) are dropped.
fn parse_query_tokens(query : String) -> Array[String] {
  query
  .to_lower()
  .split(" ")
  .filter(fn(view) { view != "" })
  .map(fn(view) { view.to_owned() })
  .to_array()
}

///|
/// A group matches when EVERY keyword appears in its id or in any of its
/// tools' names or descriptions — one hit promotes the whole group.
fn group_matches(group : ToolGroup, tokens : Array[String]) -> Bool {
  let id = group.id.to_lower()
  let haystacks : Array[String] = [id]
  for entry in group.entries {
    haystacks.push(entry.def.name.to_string().to_lower())
    haystacks.push(entry.def.description.to_lower())
  }
  for token in tokens {
    let mut hit = false
    for hay in haystacks {
      if hay.contains(token) {
        hit = true
        break
      }
    }
    if !hit {
      return false
    }
  }
  true
}

///|
/// Render one group as JSON: display id plus every tool with name,
/// description, and input schema.
fn group_json(group : ToolGroup) -> Json {
  let tools : Array[Json] = []
  for entry in group.entries {
    tools.push(
      Json::object({
        "name": Json::string(entry.def.name.to_string()),
        "description": Json::string(entry.def.description),
        "input_schema": entry.def.input_schema,
      }),
    )
  }
  Json::object({ "ext": Json::string(group.id), "tools": Json::array(tools) })
}

///|
fn arguments_object(
  tool : String,
  call : @posoco.ToolCall,
) -> Map[String, Json] raise @posoco.RuntimeError {
  match call.arguments {
    Json::Object(obj) => obj
    _ =>
      raise @posoco.RuntimeError::UnknownTool(
        "\{tool}: arguments must be a JSON object",
      )
  }
}

///|
/// Truncate to max_len characters, appending "…" if cut.
fn truncate_oneline(s : String, max_len : Int) -> String {
  let flat = s.replace(old="\n", new=" ")
  if flat.length() > max_len {
    flat[0:max_len].to_owned() + "…"
  } else {
    flat
  }
}

///|
/// `tool_list`: without `keyword`, every group; with `keyword`, only the
/// groups whose id or tools match — each rendered whole, with full schemas.
fn LazyTools::execute_list(
  self : LazyTools,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let args = arguments_object("tool_list", call)
  let keyword = match args.get("keyword") {
    Some(Json::String(k)) => Some(k)
    Some(Json::Null) | None => None
    Some(_) =>
      raise @posoco.RuntimeError::UnknownTool(
        "tool_list: optional 'keyword' must be a string",
      )
  }
  let groups = self.groups()
  let keyword_text : String = match keyword {
    Some(k) => k
    None => ""
  }
  let matched : Array[ToolGroup] = match keyword {
    None => groups
    Some(k) => {
      let tokens = parse_query_tokens(k)
      if tokens.is_empty() {
        raise @posoco.RuntimeError::UnknownTool(
          "tool_list: 'keyword' must contain at least one keyword; omit it to browse all folded groups",
        )
      }
      let hit = groups.filter(fn(group) { group_matches(group, tokens) })
      if hit.is_empty() {
        return @posoco.ToolOutcome::Success(
          content="No folded tool group matches '\{k}'. Try different keywords, or call tool_list without arguments to browse every folded group.",
          structured=None,
        )
      }
      hit
    }
  }
  if matched.is_empty() {
    return @posoco.ToolOutcome::Success(
      content="No folded tools are registered behind this gateway.",
      structured=None,
    )
  }
  let scope = match (matched.length(), groups.length()) {
    (n, total) if n == total =>
      "all \{n} folded group\{if n == 1 { "" } else { "s" }}:"
    (n, total) => "\{n} of \{total} folded groups matched '\{keyword_text}':"
  }
  let payload = matched.map(fn(group) { group_json(group) })
  let mut content = "\{scope}\n\{Json::array(payload).stringify(indent=2)}"
  // Schema-less fallback: when a group's tools carry long descriptions the
  // JSON above already has everything; the plain-text roster is only a
  // readability aid for the single-group case.
  if matched.length() == 1 {
    let group = matched[0]
    let lines = group.entries.map(fn(entry) {
      "- \{entry.def.name.to_string()}: \{truncate_oneline(entry.def.description, LIST_DESC_CAP)}"
    })
    content = "\{content}\n(\{group.id}: \{lines.join("; ")})"
  }
  @posoco.ToolOutcome::Success(content~, structured=None)
}
