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
      description="Search vault text; returns matching note lines.",
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
      description="Read numbered note lines as `line|text`; offset is 1-based, limit defaults to 400. Records freshness.",
      properties=[
        str_prop(name="path", description="Vault-relative note path"),
        int_prop(name="offset", description="1-based start line"),
        int_prop(name="limit", description="Max lines; default 400"),
      ],
      required=["path"],
      policy=@posoco.ExecutionPolicy::Parallel,
    ),
    tool_def(
      name="obsidian_get_frontmatter",
      description="Read note frontmatter JSON.",
      properties=[str_prop(name="path", description="Vault-relative note path")],
      required=["path"],
      policy=@posoco.ExecutionPolicy::Parallel,
    ),
    tool_def(
      name="obsidian_outline",
      description="List note headings with level and line.",
      properties=[str_prop(name="path", description="Vault-relative note path")],
      required=["path"],
      policy=@posoco.ExecutionPolicy::Parallel,
    ),
    tool_def(
      name="obsidian_list_notes",
      description="List files in the vault or a folder.",
      properties=[
        str_prop(name="dirpath", description="Folder; default whole vault"),
        str_prop(name="ext", description="Filter by extension, e.g. md"),
      ],
      required=[],
      policy=@posoco.ExecutionPolicy::Parallel,
    ),
    tool_def(
      name="obsidian_backlinks",
      description="Get backlinks, unresolved links, or orphan notes.",
      properties=[
        str_prop(
          name="path",
          description="Target note path (required for kind=backlinks)",
        ),
        enum_prop(name="kind", description="Link report kind", [
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
        description="Create a note; overwrite requires consent.",
        properties=[
          str_prop(name="path", description="Vault-relative note path"),
          str_prop(name="content", description="Note content"),
          bool_prop(name="overwrite", description="Overwrite; default false"),
        ],
        required=["path", "content"],
        policy=@posoco.ExecutionPolicy::Exclusive,
      ),
    )
    tools.push(
      tool_def(
        name="obsidian_patch_note",
        description="Patch note content, heading sections, or frontmatter.",
        properties=[
          str_prop(name="path", description="Vault-relative note path"),
          enum_prop(name="operation", description="Edit operation", [
            "append", "prepend", "replace", "delete",
          ]),
          enum_prop(name="target_type", description="Edit target type", [
            "heading", "frontmatter",
          ]),
          str_prop(name="target", description="Heading or property name"),
          str_prop(name="content", description="Replacement/appended content"),
        ],
        required=["path", "operation", "target_type", "target"],
        policy=@posoco.ExecutionPolicy::Exclusive,
      ),
    )
    tools.push(
      tool_def(
        name="obsidian_move_note",
        description="Move/rename a note; Obsidian updates internal links.",
        properties=[
          str_prop(name="path", description="Current note path"),
          str_prop(name="new_path", description="Destination note path"),
        ],
        required=["path", "new_path"],
        policy=@posoco.ExecutionPolicy::Exclusive,
      ),
    )
    if config.allow_delete {
      tools.push(
        tool_def(
          name="obsidian_delete_note",
          description="Delete a note; permanent deletion requires consent and confirm_path.",
          properties=[
            str_prop(name="path", description="Vault-relative note path"),
            str_prop(name="confirm_path", description="Repeat path exactly"),
            bool_prop(
              name="permanent",
              description="Permanent delete; default false",
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
