///|
priv suberror SchemaAbort {
  Fail(ExpansionDecodeError)
}

///|
fn[T] schema_fail(error : ExpansionDecodeError) -> T raise SchemaAbort {
  raise SchemaAbort::Fail(error)
}

///|
fn schema_object(
  value : JsonValue,
  path~ : String,
) -> Array[(String, JsonValue)] raise SchemaAbort {
  match value {
    JsonValue::Obj(entries) => entries
    _ => schema_fail(TypeMismatch(path~, expected="object"))
  }
}

///|
/// Allowlist check plus duplicate detection. Entries keep their original
/// order, so escaped spellings of an already-seen field name are caught by
/// exact string comparison here.
fn schema_fields(
  entries : Array[(String, JsonValue)],
  path~ : String,
  allowed~ : Array[String],
) -> Array[(String, JsonValue)] raise SchemaAbort {
  let seen : Map[String, Unit] = Map([])
  for (key, _) in entries {
    if seen.contains(key) {
      schema_fail(DuplicateField(path~, field=key))
    }
    seen[key] = ()
    if !allowed.contains(key) {
      schema_fail(UnknownField(path~, field=key))
    }
  }
  entries
}

///|
fn schema_require(
  entries : Array[(String, JsonValue)],
  path~ : String,
  field~ : String,
) -> JsonValue raise SchemaAbort {
  for (key, value) in entries {
    if key == field {
      return value
    }
  }
  schema_fail(MissingField(path~, field~))
}

///|
fn schema_string(
  entries : Array[(String, JsonValue)],
  path~ : String,
  field~ : String,
) -> String raise SchemaAbort {
  match schema_require(entries, path~, field~) {
    JsonValue::Str(value) => value
    _ => schema_fail(TypeMismatch(path="\{path}.\{field}", expected="string"))
  }
}

///|
fn schema_string_array(
  entries : Array[(String, JsonValue)],
  path~ : String,
  field~ : String,
) -> Array[String] raise SchemaAbort {
  let items = match schema_require(entries, path~, field~) {
    JsonValue::Arr(items) => items
    _ =>
      schema_fail(
        TypeMismatch(path="\{path}.\{field}", expected="array of strings"),
      )
  }
  let values : Array[String] = []
  for item in items {
    match item {
      JsonValue::Str(value) => values.push(value)
      _ =>
        schema_fail(
          TypeMismatch(path="\{path}.\{field}", expected="array of strings"),
        )
    }
  }
  values
}

///|
fn schema_priority(
  value : String,
  path~ : String,
) -> @domain.BoardPriority raise SchemaAbort {
  match value {
    "low" => @domain.Low
    "normal" => @domain.Normal
    "high" => @domain.High
    "critical" => @domain.Critical
    _ => schema_fail(InvalidPriority(path~, value~))
  }
}

///|
/// Version 1 is accepted only as the exact literal `1`: no other integer, no
/// fraction, no exponent, no sign, no string and no null. A future schema
/// version must be an explicit opt-in of this decoder, never silently
/// lenient parsing.
fn schema_version(value : JsonValue) -> Unit raise SchemaAbort {
  let found = match value {
    JsonValue::Num(token) => token
    JsonValue::Bool(token) => if token { "true" } else { "false" }
    JsonValue::Null => "null"
    _ => "<non-number>"
  }
  if found != "1" {
    // Bound the echoed token; hostile payloads do not get to grow errors.
    let shown = if found.length() > 32 {
      found.exact_view(start=0, end=32).to_owned() + "..."
    } else {
      found
    }
    schema_fail(InvalidVersion(found=shown))
  }
}

///|
/// Keys and dependency references are identifiers: nonempty, no whitespace
/// anywhere, and bounded in length. Blank or padded values are rejected
/// here so reference resolution can never depend on invisible characters.
fn schema_identifier(
  value : String,
  path~ : String,
  max_chars~ : Int32,
) -> Unit raise SchemaAbort {
  if value == "" {
    schema_fail(InvalidString(path~, reason="must not be empty"))
  }
  if value.length() > max_chars {
    schema_fail(ExceedsLimit(path~, limit="at most \{max_chars} code units"))
  }
  for unit in value {
    if unit.is_whitespace() || unit.to_int() < 32 || unit.to_int() == 127 {
      schema_fail(InvalidString(path~, reason="must not contain whitespace"))
    }
  }
}

///|
fn schema_text(
  value : String,
  path~ : String,
  max_chars~ : Int32,
  allow_blank~ : Bool,
) -> Unit raise SchemaAbort {
  if value.length() > max_chars {
    schema_fail(ExceedsLimit(path~, limit="at most \{max_chars} code units"))
  }
  if value
    .iter()
    .any(ch => ch.to_int() < 32 && ch != '\n' && ch != '\r' && ch != '\t') {
    schema_fail(InvalidString(path~, reason="unsupported control character"))
  }
  if value.trim().is_empty() && (!allow_blank || !value.is_empty()) {
    schema_fail(InvalidString(path~, reason="must not be blank"))
  }
  if !allow_blank && value.trim().to_owned() != value {
    schema_fail(InvalidString(path~, reason="must not be padded"))
  }
}

///|
fn schema_task(
  value : JsonValue,
  index : Int32,
  policy : ExpansionPolicy,
) -> DraftTask raise SchemaAbort {
  let path = "tasks[\{index}]"
  let entries = schema_fields(schema_object(value, path~), path~, allowed=[
    "key", "title", "description", "priority", "definition_of_done", "depends_on",
  ])
  let key = schema_string(entries, path~, field="key")
  schema_identifier(key, path="\{path}.key", max_chars=policy.max_key_chars())
  let title = schema_string(entries, path~, field="title")
  schema_text(
    title,
    path="\{path}.title",
    max_chars=policy.max_title_chars(),
    allow_blank=false,
  )
  let description = schema_string(entries, path~, field="description")
  schema_text(
    description,
    path="\{path}.description",
    max_chars=policy.max_description_chars(),
    allow_blank=true,
  )
  let priority = schema_priority(
    schema_string(entries, path~, field="priority"),
    path="\{path}.priority",
  )
  let dod_items = schema_string_array(
    entries,
    path~,
    field="definition_of_done",
  )
  if dod_items.length() > policy.max_dod_items() {
    schema_fail(
      ExceedsLimit(
        path="\{path}.definition_of_done",
        limit="at most \{policy.max_dod_items()} items",
      ),
    )
  }
  for dod_index, item in dod_items {
    schema_text(
      item,
      path="\{path}.definition_of_done[\{dod_index}]",
      max_chars=policy.max_dod_item_chars(),
      allow_blank=false,
    )
  }
  let items = match schema_require(entries, path~, field="depends_on") {
    JsonValue::Arr(items) => items
    _ => schema_fail(TypeMismatch(path~, expected="dependency array"))
  }
  if items.length() > policy.max_deps_per_task() {
    schema_fail(ExceedsLimit(path~, limit="dependencies per task"))
  }
  let deps : Array[ExpansionRefResolution] = []
  for item in items {
    let refs = schema_fields(schema_object(item, path~), path~, allowed=[
      "local", "existing",
    ])
    if refs.length() != 1 {
      schema_fail(
        TypeMismatch(path~, expected="exactly one of local or existing"),
      )
    }
    let (kind, value) = refs[0]
    let id = match value {
      JsonValue::Str(id) => id
      _ => schema_fail(TypeMismatch(path~, expected="reference string"))
    }
    schema_identifier(id, path~, max_chars=policy.max_key_chars())
    deps.push(
      if kind == "local" {
        NewTask(key=id)
      } else {
        ExistingTask(id=@domain.BoardTaskId(id))
      },
    )
  }
  {
    key,
    title,
    description,
    priority,
    definition_of_done: dod_items,
    depends_on: deps,
  }
}

///|
/// Scan and decode one versioned proposal payload under `policy`. The
/// decoder is total: every failure is a typed `ExpansionDecodeError`, the
/// payload is never partially accepted, and nothing but the decoded draft is
/// produced (raw payload bytes are dropped on return).
pub fn decode_expansion_proposal(
  payload~ : String,
  policy~ : ExpansionPolicy,
) -> Result[DraftExpansion, ExpansionDecodeError] {
  let limits : ScanLimits = {
    max_bytes: policy.max_payload_bytes(),
    max_depth: policy.max_depth(),
    max_items: 4096,
    max_string_units: 16384,
  }
  try {
    let root = scan_json(payload~, limits~)
    let entries = schema_fields(schema_object(root, path=""), path="", allowed=[
      "schema_version", "proposal_id", "parent_task_id", "base_revision", "tasks",
    ])
    schema_version(schema_require(entries, path="", field="schema_version"))
    let proposal_id = schema_string(entries, path="", field="proposal_id")
    let parent_task_id = schema_string(entries, path="", field="parent_task_id")
    schema_identifier(
      proposal_id,
      path="proposal_id",
      max_chars=policy.max_key_chars(),
    )
    schema_identifier(
      parent_task_id,
      path="parent_task_id",
      max_chars=policy.max_key_chars(),
    )
    let base_revision = schema_revision(
      schema_require(entries, path="", field="base_revision"),
    )
    let tasks_value = schema_require(entries, path="", field="tasks")
    let items = match tasks_value {
      JsonValue::Arr(items) => items
      _ => schema_fail(TypeMismatch(path="tasks", expected="array"))
    }
    if items.length() > policy.max_tasks() {
      schema_fail(
        ExceedsLimit(path="tasks", limit="at most \{policy.max_tasks()} tasks"),
      )
    }
    let tasks : Array[DraftTask] = []
    let keys : Set[String] = Set([])
    for index, item in items {
      let task = schema_task(item, index, policy)
      if keys.contains(task.key) {
        schema_fail(
          InvalidString(
            path="tasks[\{index}].key",
            reason="duplicate local reference",
          ),
        )
      }
      keys.add(task.key)
      tasks.push(task)
    }
    if tasks.is_empty() {
      schema_fail(ExceedsLimit(path="tasks", limit="at least one task"))
    }
    let edges = tasks.fold(init=0, (n, task) => n + task.depends_on.length())
    if edges > policy.max_edges() {
      schema_fail(ExceedsLimit(path="tasks", limit="total edges"))
    }
    Ok({ proposal_id, parent_task_id, base_revision, tasks, })
  } catch {
    ScanAbort::Abort(offset~, reason~) => Err(MalformedJson(offset~, reason~))
    ScanAbort::Encoding(offset~, reason~) =>
      Err(UnsupportedEncoding(offset~, reason~))
    ScanAbort::Limit(reason~) => Err(ExceedsLimit(path="payload", limit=reason))
    SchemaAbort::Fail(error) => Err(error)
    _ => Err(MalformedJson(offset=0, reason="invalid proposal"))
  }
}

///|
/// Exact nonnegative integer, restricted to JS's interoperable integer range.
fn schema_revision(value : JsonValue) -> Int64 raise SchemaAbort {
  let token = match value {
    JsonValue::Num(token) => token
    _ => schema_fail(TypeMismatch(path="base_revision", expected="integer"))
  }
  if token.length() > 16 || token.is_empty() {
    schema_fail(InvalidNumber(offset=0, reason="revision range"))
  }
  let mut n = 0L
  for ch in token {
    if ch < '0' || ch > '9' {
      schema_fail(InvalidNumber(offset=0, reason="revision must be an integer"))
    }
    n = n * 10L + (ch.to_int() - 48).to_int64()
  }
  if n > 9007199254740991L {
    schema_fail(InvalidNumber(offset=0, reason="revision range"))
  }
  n
}
