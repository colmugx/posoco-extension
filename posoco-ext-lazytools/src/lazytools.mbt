///|
/// posoco-ext-lazytools — tool lazy-loading gateway for Posoco agents.
///
/// A host with many tools (70+) pays for every definition on every model
/// request. LazyTools collapses N wrapped `ToolProvider`s into exactly two
/// model-visible meta tools — `tool_list` (browse or keyword-search the
/// folded catalog) and `tool_execute` (route a deferred call to its owning
/// provider) — and records usage so a recent-tools hint can ride the next
/// prompt. Providers that should stay fully loaded are registered directly
/// on the Agent, not wrapped here.

///|
/// One deferred tool: its definition and the position of the wrapped
/// provider that owns it.
priv struct LazyEntry {
  def : @posoco.ToolDef
  provider : Int
}

///|
/// The lazy-loading gateway. Opaque: compose via `LazyTools::build`.
pub struct LazyTools {
  priv providers : Array[&@posoco.ToolProvider]
  priv entries : Array[LazyEntry]
  priv by_name : Map[String, Int]
  /// Recently executed deferred tools, most recent last, deduplicated,
  /// bounded by RECENT_TOOLS_CAP. Drives the before_model hint.
  priv recent : Array[String]
}

///|
/// Build the gateway over deferred providers. Each provider's `list_tools()`
/// is called once here; the returned definitions are indexed for
/// `tool_list`/`tool_execute` and are NEVER added to the agent's catalog.
///
/// Fails with `Err` when two deferred providers declare the same tool name
/// (the agent-level collision check cannot see behind the gateway).
///
/// # Example
/// ```mbt check
/// test "lazytools exposes exactly the two meta tools" {
///   let child_def : @posoco.ToolDef = {
///     name: @posoco.ToolName::unchecked("github_create_issue"),
///     description: "Create a GitHub issue",
///     input_schema: Json::object({ "type": Json::string("object") }),
///     owner: @posoco.OwnerId::unchecked("test_child"),
///     policy: @posoco.ExecutionPolicy::Parallel,
///     provenance: Some("test_child"),
///   }
///   let child = @posoco.RecordingToolProvider([child_def], Map::from_array([]))
///   let ext = match LazyTools::build(providers=[child]) {
///     Ok(ext) => ext
///     Err(msg) => fail("unexpected build error: \{msg}")
///   }
///   let names = ext.list_tools().map(fn(def) { def.name.to_string() })
///   assert_eq(names.length(), 2)
///   assert_true(names.contains("tool_list"))
///   assert_true(names.contains("tool_execute"))
///   assert_eq(ext.deferred_count(), 1)
/// }
/// ```
pub fn LazyTools::build(
  providers~ : Array[&@posoco.ToolProvider],
) -> Result[LazyTools, String] {
  let entries : Array[LazyEntry] = []
  let by_name : Map[String, Int] = Map::from_array([])
  for i, provider in providers {
    for def in provider.list_tools() {
      let name = def.name.to_string()
      if name == "" {
        return Err("lazytools: a deferred tool declared an empty name")
      }
      match by_name.get(name) {
        Some(pos) => {
          let first = entries[pos].def
          let first_source = match first.provenance {
            Some(p) => p
            None => "(unlabeled)"
          }
          let other_source = match def.provenance {
            Some(p) => p
            None => "(unlabeled)"
          }
          return Err(
            "lazytools: deferred tool name collision '\{name}' between provenance '\{first_source}' and '\{other_source}'",
          )
        }
        None => {
          by_name[name] = entries.length()
          entries.push({ def, provider: i, })
        }
      }
    }
  }
  Ok({ providers, entries, by_name, recent: [], })
}

///|
/// Number of deferred tools hidden behind the gateway.
pub fn LazyTools::deferred_count(self : LazyTools) -> Int {
  self.entries.length()
}

///|
/// Deferred tool names in declaration order (diagnostic aid for hosts; the
/// model sees them only via `tool_list`).
pub fn LazyTools::deferred_names(self : LazyTools) -> Array[String] {
  self.entries.map(fn(entry) { entry.def.name.to_string() })
}

///|
/// Port contribution: exactly the two meta tools. Deferred definitions do
/// not pass through here — the agent catalog stays flat and small. The
/// resident catalog index lives in the system prompt (prompt_section.mbt).
pub impl @posoco.ToolProvider for LazyTools with fn list_tools(
  _self : LazyTools,
) -> Array[@posoco.ToolDef] {
  meta_tool_defs()
}

///|
/// Route a meta-tool call. `tool_list` answers from the index; `tool_execute`
/// rebuilds an inner `ToolCall` (same call id, inner name and arguments) and
/// hands it to the owning provider. The child's outcome is returned
/// verbatim; a raised `RuntimeError` propagates so the kernel's catch-all
/// maps it exactly as if the child had been called directly.
pub impl @posoco.ToolProvider for LazyTools with fn execute(
  self : LazyTools,
  name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  match name {
    "tool_list" => self.execute_list(call)
    "tool_execute" => self.execute_deferred(call)
    _ =>
      raise @posoco.RuntimeError::UnknownTool(
        "lazytools: no tool named '\{name}'",
      )
  }
}
