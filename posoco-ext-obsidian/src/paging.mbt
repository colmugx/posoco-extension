///|
/// JSON accessors over the CLI's documented output shapes (verified against
/// Obsidian 1.13.7; see docs/obsidian-extension-implementation.md).

///|
fn json_str(j : Json?) -> String? {
  match j {
    Some(Json::String(s)) => Some(s)
    _ => None
  }
}

///|
fn json_int(j : Json?) -> Int? {
  match j {
    Some(Json::Number(n, ..)) => Some(n.to_int())
    _ => None
  }
}

///|
fn json_obj(j : Json?) -> Map[String, Json]? {
  match j {
    Some(Json::Object(map)) => Some(map)
    _ => None
  }
}

///|
fn json_arr(j : Json?) -> Array[Json]? {
  match j {
    Some(Json::Array(arr)) => Some(arr)
    _ => None
  }
}

///|
fn parse_i64(s : String) -> Int64? {
  let v : Int64 = @strconv.from_str(s) catch { _ => return None }
  Some(v)
}

///|
/// Parse `obsidian file` output: tab-separated `key<TAB>value` lines with
/// millisecond epochs for `created`/`modified`.
fn parse_file_meta(output : String) -> @devkit.FileStamp? {
  let mut size : Int64? = None
  let mut modified_ms : Int64? = None
  for line in output.split("\n") {
    let parts : Array[String] = []
    for part in line.split("\t") {
      parts.push(part.to_owned())
    }
    if parts.length() >= 2 {
      match parts[0] {
        "size" => size = parse_i64(parts[1])
        "modified" => modified_ms = parse_i64(parts[1])
        _ => ()
      }
    }
  }
  match (size, modified_ms) {
    (Some(sz), Some(ms)) =>
      Some({
        mtime_s: ms / 1000L,
        mtime_ns: (ms % 1000L * 1_000_000L).to_int(),
        size: sz,
      })
    _ => None
  }
}

///|
pub(all) struct OutlineEntry {
  level : Int
  heading : String
  /// 1-based line in the full file text (frontmatter included).
  line : Int
} derive(Debug, Eq)

///|
/// Parse `outline format=json`: `[{"level":1,"heading":"Top","line":1}]`.
fn parse_outline_json(output : String) -> Array[OutlineEntry] {
  let entries : Array[OutlineEntry] = []
  let parsed : Json = @json.parse(output) catch { _ => Json::null() }
  match parsed {
    Json::Array(items) =>
      for item in items {
        match json_obj(Some(item)) {
          Some(map) =>
            match
              (
                json_int(map.get("level")),
                json_str(map.get("heading")),
                json_int(map.get("line")),
              ) {
              (Some(level), Some(heading), Some(line)) =>
                entries.push({ level, heading, line, })
              _ => ()
            }
          None => ()
        }
      }
    _ => ()
  }
  entries
}

///|
pub(all) struct SearchHit {
  file : String
  line : Int
  text : String
} derive(Debug)

///|
/// Parse `search:context format=json`:
/// `[{"file":"a.md","matches":[{"line":9,"text":"..."}]}]`.
fn parse_search_context_json(output : String) -> Array[SearchHit] {
  let hits : Array[SearchHit] = []
  let parsed : Json = @json.parse(output) catch { _ => Json::null() }
  match parsed {
    Json::Array(files) =>
      for file in files {
        match json_obj(Some(file)) {
          Some(fmap) =>
            match json_str(fmap.get("file")) {
              Some(fname) =>
                match json_arr(fmap.get("matches")) {
                  Some(matches) =>
                    for m in matches {
                      match json_obj(Some(m)) {
                        Some(mmap) =>
                          match
                            (
                              json_int(mmap.get("line")),
                              json_str(mmap.get("text")),
                            ) {
                            (Some(line), Some(text)) =>
                              hits.push({ file: fname, line, text, })
                            _ => ()
                          }
                        None => ()
                      }
                    }
                  None => ()
                }
              None => ()
            }
          None => ()
        }
      }
    _ => ()
  }
  hits
}

///|
/// Rendering limits, mirroring posoco-ext-read's read tool contract.
const OBS_LINE_CHAR_CAP = 2000

///|
const OBS_BYTE_CAP = 100_000

///|
/// Format a page of the note body: `L<line>: ` 1-indexed prefixes, long
/// lines truncated with a marker, byte cap with a continuation footer.
fn format_page(
  lines : ArrayView[String],
  first_line : Int,
  total_lines : Int,
) -> String {
  let sb = StringBuilder()
  let mut bytes = 0
  let mut emitted = 0
  let mut cut = false
  for idx, line in lines {
    let no = first_line + idx
    let mut shown = line
    if shown.length() > OBS_LINE_CHAR_CAP {
      shown = "\{shown[:OBS_LINE_CHAR_CAP]} …[truncated]"
    }
    let chunk = "L\{no}: \{shown}\n"
    if bytes + chunk.length() > OBS_BYTE_CAP {
      cut = true
      break
    }
    sb.write_string(chunk)
    bytes += chunk.length()
    emitted += 1
  }
  let remaining = total_lines - first_line + 1 - emitted
  if cut || remaining > 0 {
    sb.write_string(
      "…[\{remaining} more lines; re-read with offset=\{first_line + emitted}]",
    )
  }
  sb.to_string()
}

///|
/// Split file content into lines, dropping a single trailing empty line so
/// "a\nb\n" is two lines.
fn split_lines(content : String) -> Array[String] {
  let lines : Array[String] = []
  for line in content.split("\n") {
    lines.push(strip_trailing_cr(line.to_owned()))
  }
  if lines.length() > 0 && lines[lines.length() - 1] == "" {
    let _ = lines.pop()
  }
  lines
}

///|
fn strip_trailing_cr(line : String) -> String {
  if line.has_suffix("\r") {
    line[:line.length() - 1].to_owned()
  } else {
    line
  }
}
