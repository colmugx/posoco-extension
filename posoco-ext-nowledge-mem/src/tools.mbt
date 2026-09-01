///|
/// MCP timeout for `nmem_status` — a health check should fail fast.
const NMEM_STATUS_TIMEOUT_MS : Int = 15000

///|
/// MCP timeout for every other tool invocation.
const NMEM_TOOL_TIMEOUT_MS : Int = 30000

///|
/// Cap on the error-text excerpt surfaced in a tool error.
const NMEM_TOOL_ERROR_CHARS : Int = 500

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
/// Declare the tool surface: five tools by default — nmem_status,
/// read_context_bundle, memory_update, thread_search, and
/// thread_fetch_messages. Retrieval and saving ride core's built-in
/// `memory_search` / `memory_add` (a provider declaring its own tools under
/// those names would fail composition with a ToolCollision). The destructive
/// `memory_delete` is advertised only when the host constructed the
/// extension with `expose_delete_tool=true`. Every tool dispatches through
/// the extension's lazy MCP client; `thread_create` was dropped when the
/// CLI runner retired — the server's MCP surface has no counterpart.
pub impl @posoco.ToolProvider for NowledgeMem with fn list_tools(
  self : NowledgeMem,
) -> Array[@posoco.ToolDef] {
  let tools : Array[@posoco.ToolDef] = [
    nmem_tool_def(
      name="nmem_status",
      description="Check the Nowledge Mem MCP connection: server identity, version, and tool count. Use this first when memory or thread tools misbehave.",
      properties=Map::from_array([]),
      required=[],
    ),
    nmem_tool_def(
      name="read_context_bundle",
      description="Read the Nowledge Mem context bundle: working memory plus related distilled knowledge rendered as markdown. The working-memory part is injected once at the session's opening — call this to re-read the combined bundle on demand after major context changes, not routinely.",
      properties=Map::from_array([]),
      required=[],
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
      name="thread_fetch_messages",
      description="Load one past conversation thread with progressive detail: page through messages as needed.",
      properties=Map::from_array([
        ("thread_id", schema_prop("string", "Id of the thread to show.")),
        (
          "limit",
          schema_prop("integer", "Messages per page (server default 8)."),
        ),
        (
          "offset",
          schema_prop("integer", "Message offset into the thread (default 0)."),
        ),
      ]),
      required=["thread_id"],
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
fn opt_int(fields : Map[String, Json], key : String) -> Int? raise ToolArgError {
  match fields.get(key) {
    None => None
    Some(Json::Number(value, ..)) =>
      if value.floor() == value {
        Some(value.to_int())
      } else {
        raise ToolArgError("field '\{key}' must be an integer")
      }
    Some(_) => raise ToolArgError("field '\{key}' must be an integer")
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
/// Tool-call arguments with the ambient scope injected. The SDK transport
/// carries only the auth token, so scope rides the arguments (the upstream
/// header-scoping equivalent): `identity=true` adds source_app and the
/// agent ids on the tools whose server schema accepts them; every tool gets
/// space_id when a space is configured.
fn mcp_args(
  config : NmemConfig?,
  fields : Map[String, Json],
  identity? : Bool = false,
) -> Json {
  match config {
    Some(config) => {
      match config.space {
        Some(space) => fields["space_id"] = Json::string(space)
        None => ()
      }
      if identity {
        fields["source_app"] = Json::string(config.source_app)
        match config.agent_id {
          Some(agent_id) => fields["agent_id"] = Json::string(agent_id)
          None => ()
        }
        match config.host_agent_id {
          Some(host_agent_id) =>
            fields["host_agent_id"] = Json::string(host_agent_id)
          None => ()
        }
      }
    }
    None => ()
  }
  Json::object(fields)
}

///|
/// Parsed reply text for the structured channel: a JSON object or array
/// passes through verbatim; anything else stays `None`.
fn parsed_structured(text : String) -> Json? {
  let parsed = @json.parse(text) catch { _ => return None }
  match parsed {
    Json::Object(_) | Json::Array(_) => Some(parsed)
    _ => None
  }
}

///|
/// One MCP tool call mapped onto a ToolOutcome. A transport-level failure
/// or the server's own error flag is a ToolReportedError the model can
/// react to (the CLI's nonzero-exit mapping carries over); a clean reply
/// returns the text content verbatim plus its parsed JSON in the structured
/// channel when it is an object or array.
async fn NowledgeMem::call_mcp_tool(
  self : NowledgeMem,
  tool : String,
  args : Json,
  timeout_ms~ : Int,
) -> @posoco.ToolOutcome {
  let outcome = self.mcp.call_tool(tool, args, timeout_ms~) catch {
    err => return tool_error(tool, err.to_string())
  }
  match outcome {
    Err(message) => tool_error(tool, message)
    Ok({ is_error: true, text, }) =>
      tool_error(tool, "mcp error: \{take_prefix(text, NMEM_TOOL_ERROR_CHARS)}")
    Ok({ text, .. }) =>
      @posoco.ToolOutcome::Success(
        content=text,
        structured=parsed_structured(text),
      )
  }
}

///|
/// `nmem_status`: MCP connectivity probe — server identity plus tool count
/// — under the short health-check budget.
async fn NowledgeMem::run_nmem_status(
  self : NowledgeMem,
) -> @posoco.ToolOutcome {
  let probe = self.mcp.probe(timeout_ms=NMEM_STATUS_TIMEOUT_MS) catch {
    err => return tool_error("nmem_status", err.to_string())
  }
  match probe {
    Ok(report) =>
      @posoco.ToolOutcome::Success(
        content=report,
        structured=Some(
          Json::object({
            "connected": Json::boolean(true),
            "report": Json::string(report),
          }),
        ),
      )
    Err(message) => tool_error("nmem_status", message)
  }
}

///|
/// `read_context_bundle` (official MCP surface): the payload's
/// rendered_markdown, markdown, or content field (in that order) is the
/// body; the raw reply serves as a last-resort fallback.
async fn NowledgeMem::run_read_context_bundle(
  self : NowledgeMem,
) -> @posoco.ToolOutcome {
  let fields : Map[String, Json] = Map([])
  let outcome = self.call_mcp_tool(
    "read_context_bundle",
    mcp_args(self.config, fields, identity=true),
    timeout_ms=NMEM_TOOL_TIMEOUT_MS,
  )
  match outcome {
    @posoco.ToolOutcome::Success(content=raw, structured~) => {
      let content = match parse_context_payload(raw) {
        Some(content) => content
        None => raw
      }
      @posoco.ToolOutcome::Success(content~, structured~)
    }
    other => other
  }
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
/// `memory_update`: straight to the server (update semantics are not on the
/// MemoryPort surface). The posoco `id` argument maps to the server's
/// `memory_id` property.
async fn NowledgeMem::run_memory_update(
  self : NowledgeMem,
  args : Json,
) -> @posoco.ToolOutcome {
  let (id, content, title) = parse_memory_update_args(args) catch {
    ToolArgError(message) => return tool_error("memory_update", message)
  }
  let fields : Map[String, Json] = { "memory_id": Json::string(id) }
  match content {
    Some(content) => fields["content"] = Json::string(content)
    None => ()
  }
  match title {
    Some(title) => fields["title"] = Json::string(title)
    None => ()
  }
  self.call_mcp_tool(
    "memory_update",
    mcp_args(self.config, fields),
    timeout_ms=NMEM_TOOL_TIMEOUT_MS,
  )
}

///|
/// `memory_delete`: the `MemoryPort` `delete` slot — the same write-after
/// queue as adds (D8). A pending ticket is dropped locally (it never
/// reached the server); a real id queues the remote delete for the drain
/// (`/memory flush` forces it). Only registered when the host opts in.
async fn NowledgeMem::run_memory_delete(
  self : NowledgeMem,
  args : Json,
) -> @posoco.ToolOutcome {
  let id = req_string(arg_fields(args), "id") catch {
    ToolArgError(message) => return tool_error("memory_delete", message)
  }
  @posoco.MemoryPort::delete(self, id) catch {
    err => return tool_error("memory_delete", err.to_string())
  }
  @posoco.ToolOutcome::Success(
    content="delete queued for \{id}; will sync to Nowledge Mem",
    structured=Some(
      Json::object({ "queued": Json::boolean(true), "id": Json::string(id) }),
    ),
  )
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
  let mcp_fields : Map[String, Json] = { "query": Json::string(query) }
  match limit {
    Some(limit) => mcp_fields["limit"] = Json::number(limit.to_double())
    None => ()
  }
  self.call_mcp_tool(
    "thread_search",
    mcp_args(self.config, mcp_fields, identity=true),
    timeout_ms=NMEM_TOOL_TIMEOUT_MS,
  )
}

///|
/// `thread_fetch_messages`: one past conversation thread with progressive
/// paging (server defaults apply when limit/offset are omitted).
async fn NowledgeMem::run_thread_fetch_messages(
  self : NowledgeMem,
  args : Json,
) -> @posoco.ToolOutcome {
  let fields = arg_fields(args) catch {
    ToolArgError(message) => return tool_error("thread_fetch_messages", message)
  }
  let thread_id = req_string(fields, "thread_id") catch {
    ToolArgError(message) => return tool_error("thread_fetch_messages", message)
  }
  let limit = opt_int(fields, "limit") catch {
    ToolArgError(message) => return tool_error("thread_fetch_messages", message)
  }
  let offset = opt_int(fields, "offset") catch {
    ToolArgError(message) => return tool_error("thread_fetch_messages", message)
  }
  let mcp_fields : Map[String, Json] = { "thread_id": Json::string(thread_id) }
  match limit {
    Some(limit) => mcp_fields["limit"] = Json::number(limit.to_double())
    None => ()
  }
  match offset {
    Some(offset) => mcp_fields["offset"] = Json::number(offset.to_double())
    None => ()
  }
  self.call_mcp_tool(
    "thread_fetch_messages",
    mcp_args(self.config, mcp_fields),
    timeout_ms=NMEM_TOOL_TIMEOUT_MS,
  )
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
    "memory_update" => self.run_memory_update(args)
    "memory_delete" => self.run_memory_delete(args)
    "thread_search" => self.run_thread_search(args)
    "thread_fetch_messages" => self.run_thread_fetch_messages(args)
    _ =>
      @posoco.ToolOutcome::RuntimeFailure(
        error_category=NMEM_EXTENSION_ID,
        message="unreachable: name checked by execute",
      )
  }
}

///|
/// Dispatch one tool call. Argument-shape problems (missing required
/// fields, wrong types) are ToolReportedError the model can correct; an
/// unknown name raises RuntimeError for the runtime's catch-all; an error
/// escaping an MCP helper (the async slots' general error) surfaces as
/// RuntimeFailure so the run continues.
pub impl @posoco.ToolProvider for NowledgeMem with fn execute(
  self : NowledgeMem,
  name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  match name {
    "nmem_status"
    | "read_context_bundle"
    | "memory_update"
    | "memory_delete"
    | "thread_search"
    | "thread_fetch_messages" => ()
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
