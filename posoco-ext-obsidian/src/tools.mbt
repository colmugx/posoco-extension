///|
/// Tool catalog. Read tools are always listed (native/js); write tools are
/// gated on `write_paths` being non-empty, delete additionally on
/// `allow_delete`. Policies follow the kernel contract: reads Parallel,
/// writes Exclusive.

///|
fn json_str_array(values : Array[String]) -> Json {
  let arr : Array[Json] = []
  for v in values {
    arr.push(Json::string(v))
  }
  Json::array(arr)
}

///|
fn json_map(properties : Array[(String, Json)]) -> Json {
  let map : Map[String, Json] = Map::from_array([])
  for kv in properties {
    map[kv.0] = kv.1
  }
  Json::object(map)
}

///|
fn tool_def(
  name~ : String,
  description~ : String,
  properties~ : Array[(String, Json)],
  required~ : Array[String],
  policy~ : @posoco.ExecutionPolicy,
) -> @posoco.ToolDef {
  @posoco.ToolDef::{
    name: @posoco.ToolName::unchecked(name),
    description,
    input_schema: json_map([
      ("type", Json::string("object")),
      ("properties", json_map(properties)),
      ("required", json_str_array(required)),
    ]),
    owner: @posoco.OwnerId::unchecked(OBSIDIAN_OWNER),
    policy,
    provenance: Some(OBSIDIAN_OWNER),
  }
}

///|
fn str_prop(name~ : String, description~ : String) -> (String, Json) {
  (
    name,
    json_map([
      ("type", Json::string("string")),
      ("description", Json::string(description)),
    ]),
  )
}

///|
fn int_prop(name~ : String, description~ : String) -> (String, Json) {
  (
    name,
    json_map([
      ("type", Json::string("integer")),
      ("description", Json::string(description)),
    ]),
  )
}

///|
fn bool_prop(name~ : String, description~ : String) -> (String, Json) {
  (
    name,
    json_map([
      ("type", Json::string("boolean")),
      ("description", Json::string(description)),
    ]),
  )
}

///|
fn enum_prop(
  name~ : String,
  description~ : String,
  values : Array[String],
) -> (String, Json) {
  (
    name,
    json_map([
      ("type", Json::string("string")),
      ("description", Json::string(description)),
      ("enum", json_str_array(values)),
    ]),
  )
}

///|
fn shared_list_tools(config : ObsidianConfig) -> Array[@posoco.ToolDef] {
  let writable = !config.read_only
  let tools : Array[@posoco.ToolDef] = [
    tool_def(
      name="obsidian_search",
      description="Search the Obsidian vault for text and return matching lines per file. Use this to locate notes before reading them.",
      properties=[
        str_prop(name="query", description="Text to search for"),
        str_prop(name="folder", description="Limit search to this vault folder"),
        int_prop(name="limit", description="Result limit"),
        bool_prop(
          name="case_sensitive",
          description="Case-sensitive; default false",
        ),
      ],
      required=["query"],
      policy=@posoco.ExecutionPolicy::Parallel,
    ),
    tool_def(
      name="obsidian_read_note",
      description="Read a vault note as numbered `line|text` lines. `offset` is the 1-based start line and `limit` defaults to 400. Reading records file freshness so later write tools can reject stale targets.",
      properties=[
        str_prop(
          name="path",
          description="Vault-relative note path",
        ),
        int_prop(name="offset", description="1-based start line"),
        int_prop(
          name="limit",
          description="Max lines; default 400",
        ),
      ],
      required=["path"],
      policy=@posoco.ExecutionPolicy::Parallel,
    ),
    tool_def(
      name="obsidian_get_frontmatter",
      description="Read a note's frontmatter properties as a JSON object.",
      properties=[str_prop(name="path", description="Vault-relative note path")],
      required=["path"],
      policy=@posoco.ExecutionPolicy::Parallel,
    ),
    tool_def(
      name="obsidian_outline",
      description="List a note's headings as {level, heading, line}. Call this before replacing or deleting a heading section so you can use the exact heading text.",
      properties=[str_prop(name="path", description="Vault-relative note path")],
      required=["path"],
      policy=@posoco.ExecutionPolicy::Parallel,
    ),
    tool_def(
      name="obsidian_list_notes",
      description="List files in the vault or a folder.",
      properties=[
        str_prop(
          name="dirpath",
          description="Folder; default whole vault",
        ),
        str_prop(name="ext", description="Filter by extension, e.g. md"),
      ],
      required=[],
      policy=@posoco.ExecutionPolicy::Parallel,
    ),
    tool_def(
      name="obsidian_backlinks",
      description="Read Obsidian's link graph: backlinks to a note, unresolved links, or orphan notes.",
      properties=[
        str_prop(
          name="path",
          description="Target note path (required for kind=backlinks)",
        ),
        enum_prop(name="kind", description="Which link report to run", [
          "backlinks", "unresolved", "orphans",
        ]),
      ],
      required=["kind"],
      policy=@posoco.ExecutionPolicy::Parallel,
    ),
  ]
  if writable {
    tools.push(
      tool_def(
        name="obsidian_create_note",
        description="Create a vault note. Existing notes are not overwritten unless `overwrite=true`, which requires explicit user consent.",
        properties=[
          str_prop(name="path", description="Vault-relative note path"),
          str_prop(
            name="content",
            description="Note content",
          ),
          bool_prop(
            name="overwrite",
            description="Overwrite an existing note (default false)",
          ),
        ],
        required=["path", "content"],
        policy=@posoco.ExecutionPolicy::Exclusive,
      ),
    )
    tools.push(
      tool_def(
        name="obsidian_patch_note",
        description="Edit a note. append/prepend change raw note content; prepend skips frontmatter. replace/delete operate on a heading section located via obsidian_outline. With target_type=frontmatter, target is a property key and content is its new value; delete removes that property.",
        properties=[
          str_prop(name="path", description="Vault-relative note path"),
          enum_prop(name="operation", description="Edit operation", [
            "append", "prepend", "replace", "delete",
          ]),
          enum_prop(name="target_type", description="What the edit targets: heading or frontmatter", [
            "heading", "frontmatter",
          ]),
          str_prop(
            name="target",
            description="Exact heading text (target_type=heading) or property name (target_type=frontmatter)",
          ),
          str_prop(
            name="content",
            description="Content for append/prepend/replace, or the frontmatter property value",
          ),
        ],
        required=["path", "operation", "target_type", "target"],
        policy=@posoco.ExecutionPolicy::Exclusive,
      ),
    )
    tools.push(
      tool_def(
        name="obsidian_move_note",
        description="Move and/or rename a note. Obsidian updates internal links according to the vault's own settings.",
        properties=[
          str_prop(name="path", description="Current note path"),
          str_prop(
            name="new_path",
            description="Destination note path",
          ),
        ],
        required=["path", "new_path"],
        policy=@posoco.ExecutionPolicy::Exclusive,
      ),
    )
    if config.allow_delete {
      tools.push(
        tool_def(
          name="obsidian_delete_note",
          description="Delete a note. By default it moves to vault trash. `permanent=true` skips trash and requires explicit user consent. `confirm_path` must exactly equal `path`.",
          properties=[
            str_prop(name="path", description="Vault-relative note path"),
            str_prop(
              name="confirm_path",
              description="Must repeat `path` exactly",
            ),
            bool_prop(
              name="permanent",
              description="Skip trash and delete permanently (default false)",
            ),
          ],
          required=["path", "confirm_path"],
          policy=@posoco.ExecutionPolicy::Exclusive,
        ),
      )
    }
  }
  tools
}
