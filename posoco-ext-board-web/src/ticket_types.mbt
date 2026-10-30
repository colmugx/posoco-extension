///|
priv struct TicketQuestion {
  id : String
  task_id : String
  question : String
  kind : String
  options : Array[String]
  asked_at : Int64
  asked_by : String
  audience : String
  status : String
} derive(Eq)

///|
priv struct TicketActivity {
  at_ms : Int64
  kind : String
  text : String
} derive(Eq)

///|
priv struct TicketRun {
  task_id : String
  session_id : String
  phase : String
  role : String
  status : String
  error : String?
  result : String?
  steps : Int32
  current_tool : String?
  preview : String
  reasoning : String
  activities : Array[TicketActivity]
} derive(Eq)

///|
/// One non-blocking worker update from `ticket_state.progress`. It is
/// information only: it carries no question, no answer and no stage, so the
/// inbox renders it and never offers a reply, a resolve or a move.
priv struct TicketProgress {
  task_id : String
  /// Bounded tone: `normal`, `milestone`, `attention` or `blocked`. Anything
  /// outside that set reads as `normal` rather than inventing a tone the
  /// stylesheet cannot colour.
  kind : String
  message : String
  at_ms : Int64
} derive(Eq)

///|
/// One selectable model as the host advertises it in `ticket_state`. The
/// catalog is runtime state: it is never persisted with the ticket journal,
/// and every field except the stable slot id may be missing.
priv struct ModelOption {
  id : String
  label : String
  provider : String
  model : String
  efforts : Array[String]
  default_effort : String?
  context_window : Int64?
  capabilities : Array[String]
} derive(Eq)

///|
/// The host's per-ticket model catalog. An absent catalog and
/// `selectable=false` both mean the picker stays read-only, so a pinned
/// ticket keeps the model it already has instead of silently falling back.
priv struct ModelCatalog {
  selectable : Bool
  kind : String
  models : Array[ModelOption]
} derive(Eq)

///|
fn ModelCatalog::unavailable() -> ModelCatalog {
  { selectable: false, kind: "", models: [], }
}

///|
fn ModelCatalog::find(self : ModelCatalog, slot : String) -> ModelOption? {
  self.models.filter(model => model.id == slot).get(0)
}

///|
/// One ticket's model choice: the stable slot id plus an optional effort.
/// `None` in `Msg::TicketSetModel` (and on the wire) means inherit the
/// current Cetas model and keep following `/model`.
priv struct ModelChoice {
  slot : String
  effort : String?
}

///|
/// Host runtime facts for the Live popover. Quota is optional: a manager that
/// does not expose it renders "not exposed", never a made-up number.
priv struct TicketLiveInfo {
  manager : String
  active_model : String
  active_effort : String?
  provider : String
  context_window : Int64?
  model_count : Int32
  quota_lines : Array[String]
} derive(Eq)

///|
/// One host-configured MCP server. `tools` is display metadata; execution
/// still goes through the host bridge and its per-role allowlist.
priv struct McpServer {
  name : String
  connected : Bool
  tools : Array[String]
} derive(Eq)

///|
priv struct TeamMcp {
  enabled : Bool
  all : Bool
  servers : Array[String]
  tools : Array[String]
} derive(Eq)

///|
fn TeamMcp::defaults() -> TeamMcp {
  { enabled: false, all: true, servers: [], tools: [] }
}

///|
fn default_team_mcp() -> Map[String, TeamMcp] {
  Map::from_array([
    ("po", TeamMcp::defaults()),
    ("sm", TeamMcp::defaults()),
    ("rd", TeamMcp::defaults()),
    ("set", TeamMcp::defaults()),
    ("te", TeamMcp::defaults()),
  ])
}

///|
priv struct SkillInfo {
  name : String
  description : String
} derive(Eq)

///|
priv struct TeamSkills {
  enabled : Bool
  all : Bool
  skills : Array[String]
} derive(Eq)

///|
fn TeamSkills::defaults() -> TeamSkills {
  { enabled: false, all: true, skills: [] }
}

///|
fn default_team_skills() -> Map[String, TeamSkills] {
  Map::from_array([
    ("po", TeamSkills::defaults()),
    ("sm", TeamSkills::defaults()),
    ("rd", TeamSkills::defaults()),
    ("set", TeamSkills::defaults()),
    ("te", TeamSkills::defaults()),
  ])
}

///|
/// Lightweight names shown in prompts and on the Board. Defaults are used
/// when the host frame has no team field.
priv struct TeamNames {
  po : String
  sm : String
  rd : String
  set : String
  te : String
  mcp : Map[String, TeamMcp]
  skills : Map[String, TeamSkills]
} derive(Eq)

///|
fn TeamNames::defaults() -> TeamNames {
  {
    po: "Product Owner",
    sm: "Scrum Master",
    rd: "RD",
    set: "SET",
    te: "TE",
    mcp: default_team_mcp(),
    skills: default_team_skills(),
  }
}

///|
priv struct WorkProfile {
  id : String
  label : String
} derive(Eq)

///|
fn WorkProfile::software() -> WorkProfile {
  { id: "software", label: "Software" }
}

///|
fn work_profiles() -> Array[WorkProfile] {
  [
    WorkProfile::software(),
    { id: "document", label: "Document" },
    { id: "analysis", label: "Analysis" },
  ]
}

///|
priv struct TicketState {
  project : String
  team : TeamNames?
  /// Host-configured MCP servers, including connected tools for the picker.
  mcp_servers : Array[McpServer]
  /// Host-discovered skills available to Board roles.
  skills : Array[SkillInfo]
  profile : WorkProfile
  questions : Array[TicketQuestion]
  runs : Array[TicketRun]
  /// Non-blocking worker updates. They are shown in the inbox and never own a
  /// question, an answer or a stage move of their own.
  progress : Array[TicketProgress]
  live : TicketLiveInfo?
  /// Absent when this frame did not carry a catalog; the previous catalog is
  /// retained so a `ticket_result` cannot blank the picker mid-edit.
  model_selection : ModelCatalog?
} derive(Eq)

///|
fn TicketState::empty() -> TicketState {
  {
    project: "",
    team: None,
    mcp_servers: [],
    skills: [],
    profile: WorkProfile::software(),
    questions: [],
    runs: [],
    progress: [],
    live: None,
    model_selection: None,
  }
}

