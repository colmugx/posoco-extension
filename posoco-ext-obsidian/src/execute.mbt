///|
/// Shared tool dispatch. Backend impls hand in their `CliIo` and everything
/// below is target-independent. Errors: business failures (missing file,
/// stale target, path refusal) return `ToolReportedError` so the run
/// continues; spawn/decode failures raise `RuntimeError`.

///|
fn arg_string(args : Json, key : String) -> String? {
  match args {
    Json::Object(map) => json_str(map.get(key))
    _ => None
  }
}

///|
fn arg_bool(args : Json, key : String) -> Bool {
  match args {
    Json::Object(map) =>
      match map.get(key) {
        Some(Json::True) => true
        _ => false
      }
    _ => false
  }
}

///|
fn arg_int(args : Json, key : String) -> Int? {
  match args {
    Json::Object(map) => json_int(map.get(key))
    _ => None
  }
}

///|
fn ok(content~ : String, summary~ : String) -> @posoco.ToolOutcome {
  @posoco.ToolOutcome::Success(
    content~,
    structured=Some(Json::object({ "summary": Json::string(summary) })),
  )
}

///|
fn tool_error(content : String) -> @posoco.ToolOutcome {
  @posoco.ToolOutcome::ToolReportedError(content~, structured=None)
}

///|
fn refuse(reason~ : String) -> @posoco.ToolOutcome {
  tool_error("path refused: \{reason}")
}

///|
async fn ObsidianTools::execute_impl(
  self : ObsidianTools,
  io : &CliIo,
  name : String,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  match name {
    "obsidian_search" => self.exec_search(io, call)
    "obsidian_read_note" => self.exec_read(io, call)
    "obsidian_get_frontmatter" => self.exec_frontmatter(io, call)
    "obsidian_outline" => self.exec_outline(io, call)
    "obsidian_list_notes" => self.exec_list(io, call)
    "obsidian_backlinks" => self.exec_backlinks(io, call)
    "obsidian_create_note" => self.exec_create(io, call)
    "obsidian_patch_note" => self.exec_patch(io, call)
    "obsidian_move_note" => self.exec_move(io, call)
    "obsidian_delete_note" => self.exec_delete(io, call)
    _ => tool_error("unknown tool: \{name}")
  }
}

///|
async fn ObsidianTools::exec_search(
  self : ObsidianTools,
  io : &CliIo,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let query = match arg_string(call.arguments, "query") {
    Some(q) if q != "" => q
    _ => return tool_error("query is required")
  }
  let args : Array[String] = ["search:context", "query=\{query}", "format=json"]
  match arg_string(call.arguments, "folder") {
    Some(folder) => args.push("path=\{folder}")
    None => ()
  }
  match arg_int(call.arguments, "limit") {
    Some(limit) => args.push("limit=\{limit}")
    None => ()
  }
  if arg_bool(call.arguments, "case_sensitive") {
    args.push("case")
  }
  let result = run_cli(io, self, args)
  if cli_is_business_error(result) {
    return tool_error(result.output)
  }
  let hits = parse_search_context_json(result.output)
  if hits.is_empty() {
    return ok(content="No matches.", summary="0 matches")
  }
  let sb = StringBuilder()
  for hit in hits {
    sb.write_string("\{hit.file}:\{hit.line}: \{hit.text}\n")
  }
  ok(content=sb.to_string(), summary="\{hits.length()} matches")
}

///|
async fn ObsidianTools::exec_read(
  self : ObsidianTools,
  io : &CliIo,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let raw = match arg_string(call.arguments, "path") {
    Some(p) => p
    None => return tool_error("path is required")
  }
  let path = check_read_path(self.config, raw)
  if path == "" {
    return refuse(
      reason="path escapes the vault, lands in a reserved directory, or is outside read_paths",
    )
  }
  let read_result = run_cli(io, self, ["read", "path=\{path}"])
  if cli_is_business_error(read_result) {
    return tool_error(read_result.output)
  }
  let content = read_result.output
  match self.current_stamp(io, path) {
    Some(s) => self.freshness.note_read(path, s)
    None => ()
  }
  let lines = split_lines(content)
  let offset = match arg_int(call.arguments, "offset") {
    Some(o) if o > 1 => o
    _ => 1
  }
  let limit = match arg_int(call.arguments, "limit") {
    Some(l) if l > 0 => l
    _ => 1000
  }
  if offset > lines.length() {
    return ok(
      content="No lines at offset \{offset} (note has \{lines.length()} lines).",
      summary="empty page",
    )
  }
  let end = if offset - 1 + limit < lines.length() {
    offset - 1 + limit
  } else {
    lines.length()
  }
  let page = format_page(lines[offset - 1:end], offset, lines.length())
  ok(content=page, summary="read \{path} L\{offset}-L\{end}")
}

///|
/// Stat the note via the CLI. None = missing file (still a value, not an IO
/// failure — the CLI prints `Error: File ... not found.` with exit 0).
async fn ObsidianTools::current_stamp(
  self : ObsidianTools,
  io : &CliIo,
  path : String,
) -> @devkit.FileStamp? raise @posoco.RuntimeError {
  let result = run_cli(io, self, ["file", "path=\{path}"])
  if cli_is_business_error(result) {
    return None
  }
  parse_file_meta(result.output)
}

///|
async fn ObsidianTools::exec_frontmatter(
  self : ObsidianTools,
  io : &CliIo,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let raw = match arg_string(call.arguments, "path") {
    Some(p) => p
    None => return tool_error("path is required")
  }
  let path = check_read_path(self.config, raw)
  if path == "" {
    return refuse(
      reason="path escapes the vault, lands in a reserved directory, or is outside read_paths",
    )
  }
  let result = run_cli(io, self, ["properties", "path=\{path}", "format=json"])
  if cli_is_business_error(result) {
    return tool_error(result.output)
  }
  ok(content=result.output, summary="frontmatter of \{path}")
}

///|
async fn ObsidianTools::exec_outline(
  self : ObsidianTools,
  io : &CliIo,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let raw = match arg_string(call.arguments, "path") {
    Some(p) => p
    None => return tool_error("path is required")
  }
  let path = check_read_path(self.config, raw)
  if path == "" {
    return refuse(
      reason="path escapes the vault, lands in a reserved directory, or is outside read_paths",
    )
  }
  let result = run_cli(io, self, ["outline", "path=\{path}", "format=json"])
  if cli_is_business_error(result) {
    return tool_error(result.output)
  }
  match self.current_stamp(io, path) {
    Some(s) => self.freshness.note_read(path, s)
    None => ()
  }
  ok(content=result.output, summary="outline of \{path}")
}

///|
async fn ObsidianTools::exec_list(
  self : ObsidianTools,
  io : &CliIo,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let args : Array[String] = ["files"]
  let mut listed_dir = false
  match arg_string(call.arguments, "dirpath") {
    Some(dir) => {
      args.push("folder=\{dir}")
      listed_dir = true
    }
    None => ()
  }
  match arg_string(call.arguments, "ext") {
    Some(ext) => args.push("ext=\{ext}")
    None => ()
  }
  let result = run_cli(io, self, args)
  if cli_is_business_error(result) {
    return tool_error(result.output)
  }
  let content = if listed_dir {
    result.output
  } else {
    filter_listed_files(result.output, self.config.read_paths)
  }
  ok(content~, summary="listed vault files")
}

///|
/// Whole-vault listings are trimmed to the read allowlist (empty = keep all).
fn filter_listed_files(output : String, prefixes : Array[String]) -> String {
  if prefixes.is_empty() {
    return output
  }
  let kept : Array[String] = []
  for line in output.split("\n") {
    let trimmed = line.to_owned()
    if trimmed != "" && path_allowed(prefixes, trimmed) {
      kept.push(trimmed)
    }
  }
  if kept.is_empty() {
    ""
  } else {
    "\{kept.join("\n")}\n"
  }
}

///|
async fn ObsidianTools::exec_backlinks(
  self : ObsidianTools,
  io : &CliIo,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let kind = match arg_string(call.arguments, "kind") {
    Some(k) => k
    None => return tool_error("kind is required")
  }
  let args : Array[String] = match kind {
    "backlinks" => {
      let raw = match arg_string(call.arguments, "path") {
        Some(p) => p
        None => return tool_error("path is required for kind=backlinks")
      }
      let path = check_read_path(self.config, raw)
      if path == "" {
        return refuse(
          reason="path escapes the vault, lands in a reserved directory, or is outside read_paths",
        )
      }
      ["backlinks", "path=\{path}", "format=json", "counts"]
    }
    "unresolved" => ["unresolved", "format=json", "verbose"]
    "orphans" => ["orphans"]
    _ => return tool_error("kind must be backlinks, unresolved, or orphans")
  }
  let result = run_cli(io, self, args)
  if cli_is_business_error(result) {
    return tool_error(result.output)
  }
  ok(content=result.output, summary="\{kind} report")
}

///|
fn write_refused(config : ObsidianConfig, raw : String) -> String {
  check_write_path(config, raw)
}

///|
async fn ObsidianTools::exec_create(
  self : ObsidianTools,
  io : &CliIo,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let raw = match arg_string(call.arguments, "path") {
    Some(p) => p
    None => return tool_error("path is required")
  }
  let content = match arg_string(call.arguments, "content") {
    Some(c) => c
    None => return tool_error("content is required")
  }
  let path = write_refused(self.config, raw)
  if path == "" {
    return refuse(
      reason="path escapes the vault, lands in a reserved directory, or is outside write_paths",
    )
  }
  let overwrite = arg_bool(call.arguments, "overwrite")
  let args : Array[String] = [
    "create",
    "path=\{path}",
    "content=\{escape_cli_content(content)}",
  ]
  if overwrite {
    args.push("overwrite")
  }
  let result = run_cli(io, self, args)
  if cli_is_business_error(result) {
    return tool_error(result.output)
  }
  self.freshness.forget(path)
  ok(content=result.output, summary="created \{path}")
}

///|
async fn ObsidianTools::exec_move(
  self : ObsidianTools,
  io : &CliIo,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let raw = match arg_string(call.arguments, "path") {
    Some(p) => p
    None => return tool_error("path is required")
  }
  let new_raw = match arg_string(call.arguments, "new_path") {
    Some(p) => p
    None => return tool_error("new_path is required")
  }
  let path = check_read_path(self.config, raw)
  if path == "" {
    return refuse(
      reason="source escapes the vault, lands in a reserved directory, or is outside read_paths",
    )
  }
  let new_path = write_refused(self.config, new_raw)
  if new_path == "" {
    return refuse(reason="destination write refused")
  }
  let result = run_cli(io, self, ["move", "path=\{path}", "to=\{new_path}"])
  if cli_is_business_error(result) {
    return tool_error(result.output)
  }
  self.freshness.forget(path)
  self.freshness.forget(new_path)
  ok(content=result.output, summary="moved \{path} -> \{new_path}")
}

///|
async fn ObsidianTools::exec_delete(
  self : ObsidianTools,
  io : &CliIo,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let raw = match arg_string(call.arguments, "path") {
    Some(p) => p
    None => return tool_error("path is required")
  }
  let confirm = match arg_string(call.arguments, "confirm_path") {
    Some(c) => c
    None =>
      return tool_error(
        "confirm_path is required and must repeat path verbatim",
      )
  }
  let path = write_refused(self.config, raw)
  if path == "" {
    return refuse(
      reason="path escapes the vault, lands in a reserved directory, or is outside write_paths",
    )
  }
  if normalize_vault_path(confirm) != path {
    return tool_error(
      "confirm_path must equal path exactly (got \"\{confirm}\")",
    )
  }
  let args : Array[String] = ["delete", "path=\{path}"]
  if arg_bool(call.arguments, "permanent") {
    args.push("permanent")
  }
  let result = run_cli(io, self, args)
  if cli_is_business_error(result) {
    return tool_error(result.output)
  }
  self.freshness.forget(path)
  ok(content=result.output, summary="deleted \{path}")
}

///|
async fn ObsidianTools::exec_patch(
  self : ObsidianTools,
  io : &CliIo,
  call : @posoco.ToolCall,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let raw = match arg_string(call.arguments, "path") {
    Some(p) => p
    None => return tool_error("path is required")
  }
  let operation = match arg_string(call.arguments, "operation") {
    Some(o) => o
    None => return tool_error("operation is required")
  }
  let target_type = match arg_string(call.arguments, "target_type") {
    Some(t) => t
    None => return tool_error("target_type is required")
  }
  let target = match arg_string(call.arguments, "target") {
    Some(t) => t
    None => return tool_error("target is required")
  }
  let content = arg_string(call.arguments, "content")
  let path = write_refused(self.config, raw)
  if path == "" {
    return refuse(
      reason="path escapes the vault, lands in a reserved directory, or is outside write_paths",
    )
  }
  match target_type {
    "frontmatter" =>
      self.exec_patch_property(io, path, operation, target, content)
    "heading" => self.exec_patch_heading(io, path, operation, target, content)
    _ => tool_error("target_type must be heading or frontmatter")
  }
}

///|
async fn ObsidianTools::exec_patch_property(
  self : ObsidianTools,
  io : &CliIo,
  path : String,
  operation : String,
  key : String,
  content : String?,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  match operation {
    "replace" =>
      match content {
        Some(value) => {
          let result = run_cli(io, self, [
            "property:set",
            "name=\{key}",
            "value=\{escape_cli_content(value)}",
            "path=\{path}",
          ])
          if cli_is_business_error(result) {
            return tool_error(result.output)
          }
          self.freshness.forget(path)
          ok(content=result.output, summary="set property \{key} on \{path}")
        }
        None => tool_error("content is required for operation=replace")
      }
    "delete" => {
      let result = run_cli(io, self, [
        "property:remove",
        "name=\{key}",
        "path=\{path}",
      ])
      if cli_is_business_error(result) {
        return tool_error(result.output)
      }
      self.freshness.forget(path)
      ok(content=result.output, summary="removed property \{key} from \{path}")
    }
    _ =>
      tool_error(
        "operation=\{operation} is not valid for target_type=frontmatter (use replace or delete)",
      )
  }
}

///|
priv enum LocateResult {
  Found(Int)
  Ambiguous(Array[Int])
  NotFound(Array[String])
}

///|
fn locate_heading(
  entries : Array[OutlineEntry],
  target : String,
) -> LocateResult {
  let hits : Array[Int] = []
  let names : Array[String] = []
  for e in entries {
    if !names.contains(e.heading) {
      names.push(e.heading)
    }
    if e.heading == target {
      hits.push(e.line)
    }
  }
  match hits.length() {
    0 => NotFound(names)
    1 => Found(hits[0])
    _ => Ambiguous(hits)
  }
}

///|
/// Inclusive 1-based end line for the heading section starting at
/// `start_line` with `level`: through the line before the next heading of
/// level <= `level` (EOF otherwise).
fn section_end(
  entries : Array[OutlineEntry],
  start_line : Int,
  level : Int,
  total_lines : Int,
) -> Int {
  let mut end = total_lines
  for e in entries {
    if e.line > start_line && e.level <= level {
      end = e.line - 1
      break
    }
  }
  end
}

///|
async fn ObsidianTools::exec_patch_heading(
  self : ObsidianTools,
  io : &CliIo,
  path : String,
  operation : String,
  target : String,
  content : String?,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  match operation {
    "append" | "prepend" =>
      match content {
        Some(text) => {
          let result = run_cli(io, self, [
            operation,
            "path=\{path}",
            "content=\{escape_cli_content(text)}",
          ])
          if cli_is_business_error(result) {
            return tool_error(result.output)
          }
          self.freshness.forget(path)
          ok(content=result.output, summary="\{operation} \{path}")
        }
        None => tool_error("content is required for operation=\{operation}")
      }
    "replace" | "delete" =>
      self.exec_patch_section(io, path, operation, target, content)
    _ => tool_error("operation must be append, prepend, replace, or delete")
  }
}

///|
/// Read-modify-write for section edits: freshness check, locate via outline,
/// splice lines, rewrite whole file. The CLI has no surgical replace, so the
/// freshness ledger is the only stale-write defense on this transport.
async fn ObsidianTools::exec_patch_section(
  self : ObsidianTools,
  io : &CliIo,
  path : String,
  operation : String,
  target : String,
  content : String?,
) -> @posoco.ToolOutcome raise @posoco.RuntimeError {
  let current = self.current_stamp(io, path)
  match self.freshness.check(path, current) {
    @devkit.FreshnessVerdict::Fresh => ()
    verdict =>
      return tool_error(
        "cannot patch \{path}: \{verdict.hint()} (call obsidian_read_note or obsidian_outline first)",
      )
  }
  let outline_result = run_cli(io, self, [
    "outline",
    "path=\{path}",
    "format=json",
  ])
  if cli_is_business_error(outline_result) {
    return tool_error(outline_result.output)
  }
  let entries = parse_outline_json(outline_result.output)
  match locate_heading(entries, target) {
    Ambiguous(lines) => {
      let line_list = lines.map(fn(l) { l.to_string() }).join(", ")
      return tool_error(
        "ambiguous heading \"\{target}\" (appears at lines \{line_list}); use a more specific heading",
      )
    }
    NotFound(names) => {
      let available = if names.is_empty() { "(none)" } else { names.join(", ") }
      return tool_error(
        "heading \"\{target}\" not found; available headings: \{available}",
      )
    }
    Found(start_line) => {
      let body_result = run_cli(io, self, ["read", "path=\{path}"])
      if cli_is_business_error(body_result) {
        return tool_error(body_result.output)
      }
      let body = body_result.output
      let lines = split_lines(body)
      let level = first_level_of(entries, start_line)
      let end_line = section_end(entries, start_line, level, lines.length())
      let spliced : Array[String] = []
      for idx, line in lines {
        let no = idx + 1
        if no < start_line || no > end_line {
          spliced.push(line)
        } else if no == start_line && operation == "replace" {
          spliced.push(line)
          match content {
            Some(text) =>
              for r in split_lines(text) {
                spliced.push(r)
              }
            None => ()
          }
        }
      }
      let new_content = "\{spliced.join("\n")}\n"
      let write = run_cli(io, self, [
        "create",
        "path=\{path}",
        "overwrite",
        "content=\{escape_cli_content(new_content)}",
      ])
      if cli_is_business_error(write) {
        return tool_error(write.output)
      }
      self.freshness.forget(path)
      let prev_bytes = match current {
        Some(s) => s.size.to_string()
        None => "?"
      }
      let summary = "\{operation} section \"\{target}\" in \{path}"
      ok(content="\{write.output}previous size: \{prev_bytes} bytes", summary~)
    }
  }
}

///|
fn first_level_of(entries : Array[OutlineEntry], line : Int) -> Int {
  for e in entries {
    if e.line == line {
      return e.level
    }
  }
  1
}
