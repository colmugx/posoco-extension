///|
/// The `tool_list` handler: browse or keyword-search the deferred face of the
/// CURRENT operation. The face comes from `ToolCallContext::tools`, which the
/// kernel computes from this extension's `tool_call_owners` plus the catalog
/// captured at operation admission — so a group published after composition
/// (an MCP connection, a runtime toolkit) is listed as soon as it is live,
/// with no composition-time snapshot to refresh.

///|
/// Strip the packaging prefix from an owner id for display: extensions stamp
/// `posoco_ext_<name>` as their manifest id, but the readable name is just
/// `<name>`.
fn display_id(owner : String) -> String {
  if owner.has_prefix("posoco_ext_") {
    owner["posoco_ext_".length():].to_owned()
  } else {
    owner
  }
}

///|
fn truncate_oneline(s : String, max_len : Int32) -> String {
  let flat = s.replace(old="\n", new=" ")
  if flat.length() > max_len {
    flat[0:max_len].to_owned() + "…"
  } else {
    flat
  }
}

///|
/// One deferred owner group as this operation sees it: the raw owner key used
/// for provider-neutral DecisionPort choices, its display id, the resident
/// hint, and every live definition it owns in this operation.
priv struct ToolGroup {
  key : String
  id : String
  hint : String
  tools : Array[@posoco.ToolDef]
}

///|
/// Project the live face onto the declared groups, in declaration order.
/// Owners with no live definition keep an empty `tools` array so a group that
/// exists but has not published yet stays visible instead of vanishing.
fn LazyTools::live_groups(
  self : LazyTools,
  face : Array[@posoco.ToolDef],
) -> Array[ToolGroup] {
  let groups : Array[ToolGroup] = []
  for group in self.groups {
    let owned = face.filter(fn(def) { def.owner.to_string() == group.owner })
    groups.push({
      key: group.owner,
      id: display_id(group.owner),
      hint: group.hint,
      tools: owned,
    })
  }
  groups
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
/// A group matches when EVERY keyword appears in its id, its hint, or in any
/// of its tools' names or descriptions — one hit promotes the whole group.
fn group_matches(group : ToolGroup, tokens : Array[String]) -> Bool {
  let haystacks : Array[String] = [group.id.to_lower(), group.hint.to_lower()]
  for def in group.tools {
    haystacks.push(def.name.to_string().to_lower())
    haystacks.push(def.description.to_lower())
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
/// Render one group as compact JSON: display id plus every live tool with
/// name and input schema. Descriptions are intentionally omitted from
/// model-visible list results because the resident prompt carries capability
/// hints and the definition itself is one `tool_execute` away.
fn group_json(group : ToolGroup) -> Json {
  let tools : Array[Json] = []
  for def in group.tools {
    tools.push(
      Json::object({
        "name": Json::string(def.name.to_string()),
        "input_schema": def.input_schema,
      }),
    )
  }
  let fields : Map[String, Json] = Map::from_array([
    ("ext", Json::string(group.id)),
    ("tools", Json::array(tools)),
  ])
  if group.tools.is_empty() {
    fields["status"] = Json::string("no tools are live in this operation yet")
  }
  Json::object(fields)
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
const SEMANTIC_GROUP_MIN_PROBABILITY = 0.6

///|
fn semantic_group_description(group : ToolGroup) -> Json {
  let tools : Array[Json] = []
  for def in group.tools {
    tools.push(
      Json::object({
        "name": Json::string(def.name.to_string()),
        "description": Json::string(def.description),
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
/// DecisionPort errors all preserve the historical "no match" result. Groups
/// with no live tool are never offered: there is nothing to judge.
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
            "Is this deferred tool group semantically relevant to the user's search query? Judge relevance only; do not decide whether any tool should be executed.",
          ),
          true_criteria=None,
          false_criteria=None,
        ),
      ],
    }
    let result = decision.evaluate(
      request,
      context=@posoco.DecisionCallContext::make(
        purpose="lazytools.semantic_discovery",
      ),
    ) catch {
      _ => return None
    }
    result.validate_for(request) catch {
      _ => return None
    }
    for answer in result.answers {
      match answer {
        @posoco.DecisionAnswer::BooleanAnswer(
          id="lazytools.group_relevance",
          probability_true~,
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
          "Choose the single deferred tool group most semantically relevant to the user's search query. Judge relevance only; do not decide whether the tool should be executed.",
        ),
        options~,
      ),
    ],
  }
  let result = decision.evaluate(
    request,
    context=@posoco.DecisionCallContext::make(
      purpose="lazytools.semantic_discovery",
    ),
  ) catch {
    _ => return None
  }
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
/// `tool_list`: without `keyword`, every declared group; with `keyword`, only
/// the groups whose id, hint or tools match — each rendered whole, with full
/// schemas.
async fn LazyTools::execute_list(
  self : LazyTools,
  ctx : @posoco.ToolCallContext,
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
  let groups = self.live_groups(ctx.tools())
  if groups.is_empty() {
    return @posoco.ToolOutcome::Success(
      content="No deferred tool groups are declared behind this gateway.",
      structured=None,
    )
  }
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
          "tool_list: 'keyword' must contain at least one keyword; omit it to browse all deferred groups",
        )
      }
      let hit = groups.filter(fn(group) { group_matches(group, tokens) })
      if hit.is_empty() {
        let populated = groups.filter(fn(group) { !group.tools.is_empty() })
        match self.semantic_group_match(k, populated) {
          Some(group) => [group]
          None =>
            return @posoco.ToolOutcome::Success(
              content="No deferred tool group matches '\{k}'. Try different keywords, or call tool_list without arguments to browse every deferred group.",
              structured=None,
            )
        }
      } else {
        hit
      }
    }
  }
  let scope = match (matched.length(), groups.length()) {
    (n, total) if n == total =>
      "all \{n} deferred group\{if n == 1 { "" } else { "s" }}:"
    (n, total) => "\{n} of \{total} deferred groups matched '\{keyword_text}':"
  }
  let payload = matched.map(fn(group) { group_json(group) })
  let content = "\{scope}\n\{Json::array(payload).stringify()}"
  @posoco.ToolOutcome::Success(content~, structured=None)
}
