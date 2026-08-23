///|
/// CLI timeout for `nmem_status` — a health check should fail fast.
const NMEM_STATUS_TIMEOUT_MS : Int = 15000

///|
/// CLI timeout for every other tool invocation.
const NMEM_TOOL_TIMEOUT_MS : Int = 30000

///|
/// Cap on the stderr/stdout excerpt surfaced in a tool error.
const NMEM_TOOL_ERROR_CHARS : Int = 500

///|
/// Unit types the upstream distill-memory skill documents for
/// `--unit-type`.
let nmem_unit_types : Array[String] = [
  "fact", "preference", "decision", "plan", "procedure", "learning", "context", "event",
]

///|
/// Argument-shape rejection: the payload parsed but a field was missing,
/// mistyped, or out of enum. Raised while parsing, surfaced to the model as
/// a ToolReportedError it can correct.
priv suberror ToolArgError {
  ToolArgError(String)
}

///|
/// One tool's ToolDef with the placeholder owner and safe default policy the
/// ToolProvider contract prescribes — the catalog builder overwrites both.
fn nmem_tool_def(
  name~ : String,
  description~ : String,
  properties~ : Map[String, Json],
  required~ : Array[String],
) -> @posoco.ToolDef {
  @posoco.ToolDef::{
    name: @posoco.ToolName::unchecked(name),
    description,
    input_schema: Json::object({
      "type": Json::string("object"),
      "properties": Json::object(properties),
      "required": Json::array(required.map(item => Json::string(item))),
    }),
    owner: @posoco.OwnerId::unchecked("placeholder"),
    policy: @posoco.ExecutionPolicy::Parallel,
    provenance: Some(NMEM_EXTENSION_ID),
  }
}

///|
/// `{ "type": ..., "description": ... }` schema property shorthand.
fn schema_prop(type_ : String, description : String) -> Json {
  Json::object({
    "type": Json::string(type_),
    "description": Json::string(description),
  })
}

///|
/// String-typed schema property restricted to an enum of values.
fn schema_enum_prop(values : Array[String], description : String) -> Json {
  Json::object({
    "type": Json::string("string"),
    "enum": Json::array(values.map(item => Json::string(item))),
    "description": Json::string(description),
  })
}

///|
/// Declare the §5 tool surface: nine tools by default — the five official
/// MCP names (read_context_bundle, read_working_memory, memory_search,
/// thread_search, memory_add) plus posoco-native additions; the destructive
/// `memory_delete` is advertised only when the host constructed the
/// extension with `expose_delete_tool=true`.
pub impl @posoco.ToolProvider for NowledgeMem with fn list_tools(
  self : NowledgeMem,
) -> Array[@posoco.ToolDef] {
  let tools : Array[@posoco.ToolDef] = [
    nmem_tool_def(
      name="nmem_status",
      description="Check the Nowledge Mem service connection: mode (local/remote), server and CLI versions. Use this first when memory or thread tools misbehave.",
      properties=Map::from_array([]),
      required=[],
    ),
    nmem_tool_def(
      name="read_context_bundle",
      description="Read the Nowledge Mem context bundle: working memory plus related distilled knowledge rendered as markdown. Usually already injected into the system prompt by this extension — call only to re-read after major context changes, not routinely.",
      properties=Map::from_array([]),
      required=[],
    ),
    nmem_tool_def(
      name="read_working_memory",
      description="Read the Nowledge Mem working memory for the current scope. Usually already injected into the system prompt by this extension — call only to re-read after major context changes, not routinely.",
      properties=Map::from_array([]),
      required=[],
    ),
    nmem_tool_def(
      name="memory_search",
      description="Semantic search over distilled Nowledge Mem memories (server-side; deep mode trades speed for recall). Search before answering questions prior sessions may have settled, and before saving anything new.",
      properties=Map::from_array([
        (
          "query",
          schema_prop(
            "string", "What to look for; a phrase works better than a keyword bag.",
          ),
        ),
        (
          "mode",
          schema_enum_prop(
            ["normal", "deep"],
            "Recall mode; omit for the default normal mode.",
          ),
        ),
        ("limit", schema_prop("integer", "Maximum memories to return.")),
        (
          "importance_min",
          schema_prop(
            "number", "Only return memories with at least this importance (0.0-1.0).",
          ),
        ),
        (
          "labels",
          schema_prop(
            "array", "Restrict the search to memories carrying any of these labels.",
          ),
        ),
      ]),
      required=["query"],
    ),
    nmem_tool_def(
      name="memory_add",
      description="Queue a distilled memory for Nowledge Mem: durable decisions, preferences, workflows, project facts. Search first to avoid duplicates; prefer fewer, high-quality memories.",
      properties=Map::from_array([
        (
          "content",
          schema_prop(
            "string", "Atomic, standalone memory text; future sessions read it verbatim.",
          ),
        ),
        ("title", schema_prop("string", "Searchable title, max 60 characters.")),
        (
          "unit_type",
          schema_enum_prop(
            nmem_unit_types.copy(),
            "Classification of the memory.",
          ),
        ),
        (
          "importance",
          schema_prop(
            "number", "0.8-1.0 major decisions, 0.5-0.7 useful patterns, 0.3-0.4 minor notes.",
          ),
        ),
        (
          "labels",
          schema_prop(
            "array", "0-3 retrieval labels; only when they improve retrieval.",
          ),
        ),
      ]),
      required=["content"],
    ),
    nmem_tool_def(
      name="memory_update",
      description="Update an existing Nowledge Mem memory in place when new information refines it (instead of saving a near-copy).",
      properties=Map::from_array([
        ("id", schema_prop("string", "Id of the memory to update.")),
        ("content", schema_prop("string", "Replacement content.")),
        ("title", schema_prop("string", "Replacement title.")),
      ]),
      required=["id"],
    ),
    nmem_tool_def(
      name="thread_search",
      description="Search past conversation threads (including sessions from other tools) for history and context the current transcript lacks.",
      properties=Map::from_array([
        (
          "query",
          schema_prop("string", "What to look for in past conversations."),
        ),
        ("limit", schema_prop("integer", "Maximum threads to return.")),
      ]),
      required=["query"],
    ),
    nmem_tool_def(
      name="thread_show",
      description="Load one past conversation thread with progressive detail: page through messages and cap per-message content length as needed.",
      properties=Map::from_array([
        ("thread_id", schema_prop("string", "Id of the thread to show.")),
        ("limit", schema_prop("integer", "Messages per page (default 8).")),
        (
          "offset",
          schema_prop("integer", "Message offset into the thread (default 0)."),
        ),
        (
          "content_limit",
          schema_prop(
            "integer", "Per-message content cap in characters (default 1200).",
          ),
        ),
      ]),
      required=["thread_id"],
    ),
    nmem_tool_def(
      name="thread_create",
      description="Create a curated handoff thread summarizing the current session for future continuity.",
      properties=Map::from_array([
        ("title", schema_prop("string", "Handoff title.")),
        (
          "content",
          schema_prop("string", "Curated summary of what was done and decided."),
        ),
      ]),
      required=["title", "content"],
    ),
  ]
  if self.expose_delete_tool {
    tools.push(
      nmem_tool_def(
        name="memory_delete",
        description="Hard-delete a Nowledge Mem memory by id. Destructive and irreversible; search first and prefer updating instead.",
        properties=Map::from_array([
          ("id", schema_prop("string", "Id of the memory to delete.")),
        ]),
        required=["id"],
      ),
    )
  }
  tools
}

///|
/// Object fields of a tool-call argument payload.
fn arg_fields(args : Json) -> Map[String, Json] raise ToolArgError {
  match args {
    Json::Object(fields) => fields
    _ => raise ToolArgError("arguments must be a JSON object")
  }
}

///|
fn opt_string(
  fields : Map[String, Json],
  key : String,
) -> String? raise ToolArgError {
  match fields.get(key) {
    None => None
    Some(Json::String(value)) => Some(value)
    Some(_) => raise ToolArgError("field '\{key}' must be a string")
  }
}

///|
fn req_string(
  fields : Map[String, Json],
  key : String,
) -> String raise ToolArgError {
  match opt_string(fields, key) {
    Some(value) => value
    None => raise ToolArgError("missing required field '\{key}'")
  }
}

///|
fn opt_double(
  fields : Map[String, Json],
  key : String,
) -> Double? raise ToolArgError {
  match fields.get(key) {
    None => None
    Some(Json::Number(value, ..)) => Some(value)
    Some(_) => raise ToolArgError("field '\{key}' must be a number")
  }
}

///|
fn opt_int(fields : Map[String, Json], key : String) -> Int? raise ToolArgError {
  match opt_double(fields, key) {
    Some(value) =>
      if value.floor() == value {
        Some(value.to_int())
      } else {
        raise ToolArgError("field '\{key}' must be an integer")
      }
    None => None
  }
}

///|
fn opt_string_array(
  fields : Map[String, Json],
  key : String,
) -> Array[String]? raise ToolArgError {
  match fields.get(key) {
    None => None
    Some(Json::Array(items)) => {
      let values : Array[String] = []
      for item in items {
        match item {
          Json::String(value) => values.push(value)
          _ => raise ToolArgError("field '\{key}' must be an array of strings")
        }
      }
      Some(values)
    }
    Some(_) => raise ToolArgError("field '\{key}' must be an array of strings")
  }
}

///|
/// ToolReportedError with the tool name prefixed so the model can correlate
/// the failure with its call.
fn tool_error(tool : String, message : String) -> @posoco.ToolOutcome {
  @posoco.ToolOutcome::ToolReportedError(
    content="\{tool}: \{message}",
    structured=None,
  )
}

///|
/// Map a failed CLI run to a ToolReportedError: the stderr excerpt (stdout
/// when stderr is empty; "nmem unavailable" when both are, e.g. a missing
/// CLI), capped at NMEM_TOOL_ERROR_CHARS.
fn cli_tool_error(tool : String, outcome : CliOutcome) -> @posoco.ToolOutcome {
  let detail = if outcome.stderr != "" {
    outcome.stderr
  } else if outcome.stdout != "" {
    outcome.stdout
  } else {
    "nmem unavailable"
  }
  tool_error(
    tool,
    "nmem exited with code \{outcome.exit}: \{take_prefix(detail, NMEM_TOOL_ERROR_CHARS)}",
  )
}

///|
/// Success carrying the CLI's stdout verbatim — the tools return the
/// server's own --json payload for the model to read.
fn cli_tool_success(outcome : CliOutcome) -> @posoco.ToolOutcome {
  @posoco.ToolOutcome::Success(content=outcome.stdout, structured=None)
}

///|
/// Parsed CLI stdout for the structured channel: a JSON object or array
/// passes through verbatim; anything else stays `None`.
fn cli_structured(stdout : String) -> Json? {
  let parsed = @json.parse(stdout) catch { _ => return None }
  match parsed {
    Json::Object(_) | Json::Array(_) => Some(parsed)
    _ => None
  }
}

///|
/// Success carrying the CLI's stdout verbatim plus the parsed payload in
/// the structured channel (official-surface tools: nmem_status,
/// memory_search, thread_search).
fn cli_tool_success_structured(outcome : CliOutcome) -> @posoco.ToolOutcome {
  @posoco.ToolOutcome::Success(
    content=outcome.stdout,
    structured=cli_structured(outcome.stdout),
  )
}

///|
/// Hint returned by `read_working_memory` when the payload reports
/// `exists: false` or carries no usable content — an empty working memory
/// is a clean state, not an error.
const NMEM_WM_EMPTY_HINT : String = "No working memory yet — use memory_add to save knowledge first."

///|
/// Body of a `read_working_memory` hit: the payload's `content` when the
/// working memory exists, a hint when the payload reports `exists: false`
/// (or carries no usable content), and the raw stdout when nothing parsed.
fn wm_tool_text(stdout : String) -> String {
  match parse_wm_payload(stdout) {
    Some(content) => content
    None =>
      if clean_json_object(stdout) is Some(_) {
        NMEM_WM_EMPTY_HINT
      } else {
        stdout
      }
  }
}

///|
/// `nmem_status`: `nmem --json status` under the short health-check budget.
async fn NowledgeMem::run_nmem_status(
  self : NowledgeMem,
) -> @posoco.ToolOutcome {
  let outcome = NmemRunner::run_cli(
    self.runner,
    ["--json", "status"],
    timeout_ms=NMEM_STATUS_TIMEOUT_MS,
  )
  if outcome.exit == 0 {
    cli_tool_success_structured(outcome)
  } else {
    cli_tool_error("nmem_status", outcome)
  }
}

///|
/// `read_working_memory` (official MCP surface): `--json wm read` scoped by
/// the ambient space. The stdout object's `content` field is the body;
/// `exists === false` degrades to a hint instead of an error.
async fn NowledgeMem::run_read_working_memory(
  self : NowledgeMem,
) -> @posoco.ToolOutcome {
  let outcome = NmemRunner::run_cli(
    self.runner,
    with_ambient_space(["--json", "wm", "read"], self.config),
    timeout_ms=NMEM_TOOL_TIMEOUT_MS,
  )
  if outcome.exit != 0 {
    return cli_tool_error("read_working_memory", outcome)
  }
  @posoco.ToolOutcome::Success(
    content=wm_tool_text(outcome.stdout),
    structured=cli_structured(outcome.stdout),
  )
}

///|
/// `read_context_bundle` (official MCP surface): `--json context
/// --source-app <app>` scoped by the ambient space. The payload's
/// rendered_markdown, markdown, or content field (in that order) is the
/// body; the raw stdout serves as a last-resort fallback.
async fn NowledgeMem::run_read_context_bundle(
  self : NowledgeMem,
) -> @posoco.ToolOutcome {
  let source_app = match self.config {
    Some(config) => config.source_app
    None => self.source_app
  }
  let outcome = NmemRunner::run_cli(
    self.runner,
    with_ambient_space(
      ["--json", "context", "--source-app", source_app],
      self.config,
    ),
    timeout_ms=NMEM_TOOL_TIMEOUT_MS,
  )
  if outcome.exit != 0 {
    return cli_tool_error("read_context_bundle", outcome)
  }
  let content = match parse_context_payload(outcome.stdout) {
    Some(content) => content
    None => outcome.stdout
  }
  @posoco.ToolOutcome::Success(
    content~,
    structured=cli_structured(outcome.stdout),
  )
}

///|
priv struct MemorySearchArgs {
  query : String
  mode : String?
  limit : Int?
  importance_min : Double?
  labels : Array[String]?
}

///|
fn parse_memory_search_args(args : Json) -> MemorySearchArgs raise ToolArgError {
  let fields = arg_fields(args)
  let mode = match opt_string(fields, "mode") {
    Some(mode) =>
      if mode == "normal" || mode == "deep" {
        mode
      } else {
        raise ToolArgError("field 'mode' must be \"normal\" or \"deep\"")
      }
    None => ""
  }
  {
    query: req_string(fields, "query"),
    mode: if mode == "" {
      None
    } else {
      Some(mode)
    },
    limit: opt_int(fields, "limit"),
    importance_min: opt_double(fields, "importance_min"),
    labels: opt_string_array(fields, "labels"),
  }
}

///|
/// `memory_search`: server-side semantic retrieval — deliberately NOT the
/// local index the passive MemoryPort surface scores (D8: the passive path
/// favors speed, the active path favors accuracy).
async fn NowledgeMem::run_memory_search(
  self : NowledgeMem,
  args : Json,
) -> @posoco.ToolOutcome {
  let parsed = parse_memory_search_args(args) catch {
    ToolArgError(message) => return tool_error("memory_search", message)
  }
  let cli_args : Array[String] = ["--json", "m", "search", parsed.query]
  match parsed.mode {
    Some(mode) => {
      cli_args.push("--mode")
      cli_args.push(mode)
    }
    None => ()
  }
  match parsed.limit {
    Some(limit) => {
      cli_args.push("-n")
      cli_args.push("\{limit}")
    }
    None => ()
  }
  match parsed.importance_min {
    Some(importance) => {
      cli_args.push("--importance")
      cli_args.push("\{importance}")
    }
    None => ()
  }
  match parsed.labels {
    Some(labels) =>
      for label in labels {
        cli_args.push("-l")
        cli_args.push(label)
      }
    None => ()
  }
  let outcome = NmemRunner::run_cli(
    self.runner,
    with_ambient_space(cli_args, self.config),
    timeout_ms=NMEM_TOOL_TIMEOUT_MS,
  )
  if outcome.exit == 0 {
    cli_tool_success_structured(outcome)
  } else {
    cli_tool_error("memory_search", outcome)
  }
}

///|
priv struct MemoryAddArgs {
  content : String
  title : String?
  unit_type : String?
  importance : Double?
  labels : Array[String]?
}

///|
fn parse_memory_add_args(args : Json) -> MemoryAddArgs raise ToolArgError {
  let fields = arg_fields(args)
  let unit_type = match opt_string(fields, "unit_type") {
    Some(unit_type) =>
      if nmem_unit_types.contains(unit_type) {
        Some(unit_type)
      } else {
        raise ToolArgError(
          "field 'unit_type' must be one of \{nmem_unit_types.join("|")}",
        )
      }
    None => None
  }
  {
    content: req_string(fields, "content"),
    title: opt_string(fields, "title"),
    unit_type,
    importance: opt_double(fields, "importance"),
    labels: opt_string_array(fields, "labels"),
  }
}

///|
/// `memory_add`: the single write path is MemoryPort::store — the entry
/// lands in the local copy synchronously and reaches the server via the
/// write-after queue, exactly like passive stores.
fn NowledgeMem::run_memory_add(
  self : NowledgeMem,
  args : Json,
) -> @posoco.ToolOutcome {
  let parsed = parse_memory_add_args(args) catch {
    ToolArgError(message) => return tool_error("memory_add", message)
  }
  let metadata : Map[String, Json] = Map::from_array([])
  match parsed.title {
    Some(title) => metadata["title"] = Json::string(title)
    None => ()
  }
  match parsed.unit_type {
    Some(unit_type) => metadata["unit_type"] = Json::string(unit_type)
    None => ()
  }
  match parsed.importance {
    Some(importance) => metadata["importance"] = Json::number(importance)
    None => ()
  }
  match parsed.labels {
    Some(labels) =>
      metadata["labels"] = Json::array(labels.map(label => Json::string(label)))
    None => ()
  }
  let entry : @posoco.MemoryEntry = {
    id: "",
    content: parsed.content,
    metadata,
    score: None,
  }
  let pending_id = @posoco.MemoryPort::store(self, entry) catch {
    err => return tool_error("memory_add", err.to_string())
  }
  @posoco.ToolOutcome::Success(
    content="queued as \{pending_id}; will sync to Nowledge Mem",
    structured=Some(
      Json::object({
        "queued": Json::boolean(true),
        "pending_id": Json::string(pending_id),
        "summary": Json::string("queued as \{pending_id}"),
      }),
    ),
  )
}

///|
fn parse_memory_update_args(
  args : Json,
) -> (String, String?, String?) raise ToolArgError {
  let fields = arg_fields(args)
  let id = req_string(fields, "id")
  let content = opt_string(fields, "content")
  let title = opt_string(fields, "title")
  if content is None && title is None {
    raise ToolArgError("provide at least one of 'content' or 'title'")
  }
  (id, content, title)
}

///|
/// `memory_update`: straight to the CLI (update semantics are not on the
/// MemoryPort surface); a success also refreshes the local index entry so
/// passive search stops serving the stale text.
async fn NowledgeMem::run_memory_update(
  self : NowledgeMem,
  args : Json,
) -> @posoco.ToolOutcome {
  let (id, content, title) = parse_memory_update_args(args) catch {
    ToolArgError(message) => return tool_error("memory_update", message)
  }
  let cli_args : Array[String] = ["--json", "m", "update", id]
  match content {
    Some(content) => {
      cli_args.push("-c")
      cli_args.push(content)
    }
    None => ()
  }
  match title {
    Some(title) => {
      cli_args.push("-t")
      cli_args.push(title)
    }
    None => ()
  }
  let outcome = NmemRunner::run_cli(
    self.runner,
    with_ambient_space(cli_args, self.config),
    timeout_ms=NMEM_TOOL_TIMEOUT_MS,
  )
  if outcome.exit != 0 {
    return cli_tool_error("memory_update", outcome)
  }
  for i, entry in self.mem.index {
    if entry.id == id {
      let updated : @posoco.MemoryEntry = {
        ..entry,
        content: match content {
          Some(content) => content
          None => entry.content
        },
      }
      match title {
        Some(title) => updated.metadata["title"] = Json::string(title)
        None => ()
      }
      self.mem.index[i] = updated
      break
    }
  }
  cli_tool_success(outcome)
}

///|
/// `memory_delete`: straight to `m delete -f` (the -f flag is mandatory —
/// without it the CLI blocks interactively). Only registered when the host
/// opts in. The local index drops the entry on success so passive search
/// stops serving it.
async fn NowledgeMem::run_memory_delete(
  self : NowledgeMem,
  args : Json,
) -> @posoco.ToolOutcome {
  let id = req_string(arg_fields(args), "id") catch {
    ToolArgError(message) => return tool_error("memory_delete", message)
  }
  let outcome = NmemRunner::run_cli(
    self.runner,
    with_ambient_space(["--json", "m", "delete", id, "-f"], self.config),
    timeout_ms=NMEM_TOOL_TIMEOUT_MS,
  )
  if outcome.exit != 0 {
    return cli_tool_error("memory_delete", outcome)
  }
  remove_index_entry(self.mem, id)
  cli_tool_success(outcome)
}

///|
/// `thread_search`.
async fn NowledgeMem::run_thread_search(
  self : NowledgeMem,
  args : Json,
) -> @posoco.ToolOutcome {
  let fields = arg_fields(args) catch {
    ToolArgError(message) => return tool_error("thread_search", message)
  }
  let query = req_string(fields, "query") catch {
    ToolArgError(message) => return tool_error("thread_search", message)
  }
  let limit = opt_int(fields, "limit") catch {
    ToolArgError(message) => return tool_error("thread_search", message)
  }
  let cli_args : Array[String] = ["--json", "t", "search", query]
  match limit {
    Some(limit) => {
      cli_args.push("--limit")
      cli_args.push("\{limit}")
    }
    None => ()
  }
  let outcome = NmemRunner::run_cli(
    self.runner,
    with_ambient_space(cli_args, self.config),
    timeout_ms=NMEM_TOOL_TIMEOUT_MS,
  )
  if outcome.exit == 0 {
    cli_tool_success_structured(outcome)
  } else {
    cli_tool_error("thread_search", outcome)
  }
}

///|
/// `thread_show` with the upstream progressive-loading defaults (limit 8,
/// offset 0, content cap 1200).
async fn NowledgeMem::run_thread_show(
  self : NowledgeMem,
  args : Json,
) -> @posoco.ToolOutcome {
  let fields = arg_fields(args) catch {
    ToolArgError(message) => return tool_error("thread_show", message)
  }
  let thread_id = req_string(fields, "thread_id") catch {
    ToolArgError(message) => return tool_error("thread_show", message)
  }
  let limit_opt = opt_int(fields, "limit") catch {
    ToolArgError(message) => return tool_error("thread_show", message)
  }
  let offset_opt = opt_int(fields, "offset") catch {
    ToolArgError(message) => return tool_error("thread_show", message)
  }
  let content_limit_opt = opt_int(fields, "content_limit") catch {
    ToolArgError(message) => return tool_error("thread_show", message)
  }
  let limit = match limit_opt {
    Some(limit) => limit
    None => 8
  }
  let offset = match offset_opt {
    Some(offset) => offset
    None => 0
  }
  let content_limit = match content_limit_opt {
    Some(content_limit) => content_limit
    None => 1200
  }
  let outcome = NmemRunner::run_cli(
    self.runner,
    with_ambient_space(
      [
        "--json",
        "t",
        "show",
        thread_id,
        "--limit",
        "\{limit}",
        "--offset",
        "\{offset}",
        "--content-limit",
        "\{content_limit}",
      ],
      self.config,
    ),
    timeout_ms=NMEM_TOOL_TIMEOUT_MS,
  )
  if outcome.exit == 0 {
    cli_tool_success(outcome)
  } else {
    cli_tool_error("thread_show", outcome)
  }
}

///|
/// `thread_create`: an explicit handoff thread (`t create -t .. -c ..
/// -s generic-agent`, per the upstream save-thread skill).
async fn NowledgeMem::run_thread_create(
  self : NowledgeMem,
  args : Json,
) -> @posoco.ToolOutcome {
  let fields = arg_fields(args) catch {
    ToolArgError(message) => return tool_error("thread_create", message)
  }
  let title = req_string(fields, "title") catch {
    ToolArgError(message) => return tool_error("thread_create", message)
  }
  let content = req_string(fields, "content") catch {
    ToolArgError(message) => return tool_error("thread_create", message)
  }
  let outcome = NmemRunner::run_cli(
    self.runner,
    with_ambient_space(
      [
        "--json", "t", "create", "-t", title, "-c", content, "-s", "generic-agent",
      ],
      self.config,
    ),
    timeout_ms=NMEM_TOOL_TIMEOUT_MS,
  )
  if outcome.exit == 0 {
    cli_tool_success(outcome)
  } else {
    cli_tool_error("thread_create", outcome)
  }
}

///|
/// Named dispatch for a validated tool name. Raising slot: an error
/// escaping a helper (the async general error) is converted by `execute`.
async fn NowledgeMem::dispatch_tool(
  self : NowledgeMem,
  name : String,
  args : Json,
) -> @posoco.ToolOutcome {
  match name {
    "nmem_status" => self.run_nmem_status()
    "read_context_bundle" => self.run_read_context_bundle()
    "read_working_memory" => self.run_read_working_memory()
    "memory_search" => self.run_memory_search(args)
    "memory_add" => self.run_memory_add(args)
    "memory_update" => self.run_memory_update(args)
    "memory_delete" => self.run_memory_delete(args)
    "thread_search" => self.run_thread_search(args)
    "thread_show" => self.run_thread_show(args)
    "thread_create" => self.run_thread_create(args)
    _ =>
      @posoco.ToolOutcome::RuntimeFailure(
        error_category=NMEM_EXTENSION_ID,
        message="unreachable: name checked by execute",
      )
  }
}

///|
/// Dispatch one tool call. Argument-shape problems (missing required
/// fields, wrong types, non-enum unit_type) are ToolReportedError the model
/// can correct; an unknown name raises RuntimeError for the runtime's
/// catch-all; an error escaping a CLI helper (the async slots' general
/// error) surfaces as RuntimeFailure so the run continues.
pub impl @posoco.ToolProvider for NowledgeMem with fn execute(
  self : NowledgeMem,
  name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  match name {
    "nmem_status"
    | "read_context_bundle"
    | "read_working_memory"
    | "memory_search"
    | "memory_add"
    | "memory_update"
    | "memory_delete"
    | "thread_search"
    | "thread_show"
    | "thread_create" => ()
    _ =>
      raise @posoco.RuntimeError::UnknownTool(
        "\{NMEM_EXTENSION_ID}: unknown tool '\{name}'",
      )
  }
  self.dispatch_tool(name, call.arguments) catch {
    err =>
      @posoco.ToolOutcome::RuntimeFailure(
        error_category=NMEM_EXTENSION_ID,
        message=err.to_string(),
      )
  }
}

///|
pub extend NowledgeMem with @posoco.ToolProvider::{list_tools, execute}
