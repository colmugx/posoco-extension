///|
/// The `tool_list` handler: browse or keyword-search the folded catalog.
/// Results are grouped by extension — one match returns the whole group —
/// and each tool carries only its name and full JSON input schema. Capability
/// descriptions already live in the resident catalog and semantic discovery
/// path, so repeating them here only spends context.

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
  /// Raw provenance key used for provider-neutral DecisionPort choices.
  key : String
  /// Human-readable display id.
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
        by_source[source] = {
          key: source,
          id: display_id(source),
          entries: [entry],
        }
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
/// Render one group as compact JSON: display id plus every tool with name
/// and input schema. Descriptions are intentionally omitted from model-visible
/// list results because the resident prompt already carries capability hints.
fn group_json(group : ToolGroup) -> Json {
  let tools : Array[Json] = []
  for entry in group.entries {
    tools.push(
      Json::object({
        "name": Json::string(entry.def.name.to_string()),
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
fn truncate_oneline(s : String, max_len : Int) -> String {
  let flat = s.replace(old="\n", new=" ")
  if flat.length() > max_len {
    flat[0:max_len].to_owned() + "…"
  } else {
    flat
  }
}

///|
const SEMANTIC_GROUP_MIN_PROBABILITY = 0.6

///|
fn semantic_group_description(group : ToolGroup) -> Json {
  let tools : Array[Json] = []
  for entry in group.entries {
    tools.push(
      Json::object({
        "name": Json::string(entry.def.name.to_string()),
        "description": Json::string(entry.def.description),
      }),
    )
  }
  Json::object({ "group": Json::string(group.id), "tools": Json::array(tools) })
}

///|
fn selected_probability(
  probabilities : Array[@posoco.DecisionNamedProbability],
  selected : String,
) -> Double? {
  for entry in probabilities {
    if entry.id == selected {
      return Some(entry.probability)
    }
  }
  None
}

///|
/// Semantic discovery is a fallback only. Existing exact/keyword matches stay
/// deterministic; provider absence, malformed answers, low probability, or
/// DecisionPort errors all preserve the historical "no match" result.
async fn LazyTools::semantic_group_match(
  self : LazyTools,
  query : String,
  groups : Array[ToolGroup],
) -> ToolGroup? noraise {
  let decision = match self.decision {
    Some(decision) => decision
    None => return None
  }
  if groups.is_empty() {
    return None
  }
  if groups.length() == 1 {
    let group = groups[0]
    let request : @posoco.DecisionRequest = {
      state: Json::object({
        "query": Json::string(query),
        "group": semantic_group_description(group),
      }),
      questions: [
        @posoco.DecisionQuestion::Boolean(
          id="lazytools.group_relevance",
          instructions=Json::string(
            "Is this folded tool group semantically relevant to the user's search query? Judge relevance only; do not decide whether any tool should be executed.",
          ),
          true_criteria=None,
          false_criteria=None,
        ),
      ],
    }
    let result = decision.evaluate(request) catch { _ => return None }
    result.validate_for(request) catch {
      _ => return None
    }
    for answer in result.answers {
      match answer {
        @posoco.DecisionAnswer::BooleanAnswer(
          id="lazytools.group_relevance",
          probability_true~
        ) if probability_true >= SEMANTIC_GROUP_MIN_PROBABILITY =>
          return Some(group)
        _ => ()
      }
    }
    return None
  }
  let options : Array[@posoco.DecisionOption] = groups.map(fn(group) {
    { id: group.key, description: Some(semantic_group_description(group)), }
  })
  let request : @posoco.DecisionRequest = {
    state: Json::object({ "query": Json::string(query) }),
    questions: [
      @posoco.DecisionQuestion::Choice(
        id="lazytools.group",
        instructions=Json::string(
          "Choose the single folded tool group most semantically relevant to the user's search query. Judge relevance only; do not decide whether the tool should be executed.",
        ),
        options~,
      ),
    ],
  }
  let result = decision.evaluate(request) catch { _ => return None }
  result.validate_for(request) catch {
    _ => return None
  }
  for answer in result.answers {
    match answer {
      @posoco.DecisionAnswer::ChoiceAnswer(
        id="lazytools.group",
        selected~,
        probabilities~,
        ..
      ) =>
        match selected_probability(probabilities, selected) {
          Some(probability) if probability >= SEMANTIC_GROUP_MIN_PROBABILITY =>
            for group in groups {
              if group.key == selected {
                return Some(group)
              }
            }
          _ => ()
        }
      _ => ()
    }
  }
  None
}

///|
/// `tool_list`: without `keyword`, every group; with `keyword`, only the
/// groups whose id or tools match — each rendered whole, with full schemas.
async fn LazyTools::execute_list(
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
        match self.semantic_group_match(k, groups) {
          Some(group) => [group]
          None =>
            return @posoco.ToolOutcome::Success(
              content="No folded tool group matches '\{k}'. Try different keywords, or call tool_list without arguments to browse every folded group.",
              structured=None,
            )
        }
      } else {
        hit
      }
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
  let content = "\{scope}\n\{Json::array(payload).stringify()}"
  @posoco.ToolOutcome::Success(content~, structured=None)
}
