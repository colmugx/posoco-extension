///|
/// HTML → LLM-oriented markdown. One pass over the parsed DOM: block elements
/// map to markdown blocks, boilerplate subtrees are dropped, and all output
/// flows through Emit's line state so results never contain blank-line runs,
/// trailing spaces, or leading indentation accidents.
priv struct HtmlDoc {
  title : String // <title> → og:title → first <h1> → last base path segment
  markdown : String // converted body; "" when the page has no content
}

///|
let html_max_depth : Int = 200

///|
/// Emitter state: `at_line_start`/`pending_space` keep inline whitespace
/// decisions local, `need_sep` guarantees at most one blank line between
/// blocks, `li_fresh` lets the first <p> of a list item stay on the marker
/// line while later ones break onto indented continuation lines.
priv struct Emit {
  base : String
  out : StringBuilder
  mut at_line_start : Bool
  mut need_sep : Bool
  mut pending_space : Bool
  mut li_fresh : Bool
  mut first_h1 : String
  list_ordered : Array[Bool]
  list_counters : Array[Int]
}

///|
fn Emit::put_char(self : Emit, c : Char) -> Unit {
  self.out.write_char(c)
  self.at_line_start = c == '\n'
  if c == '\n' {
    self.pending_space = false
  }
  self.li_fresh = false
}

///|
fn Emit::put_string(self : Emit, s : String) -> Unit {
  self.out.write_string(s)
  if s.length() > 0 {
    let u : UInt16 = s[s.length() - 1]
    self.at_line_start = u == 10
    if self.at_line_start {
      self.pending_space = false
    }
    self.li_fresh = false
  }
}

///|
fn Emit::flush_space(self : Emit) -> Unit {
  if self.pending_space {
    self.pending_space = false
    if !self.at_line_start {
      self.out.write_char(' ')
    }
  }
}

///|
fn Emit::raw_inline(self : Emit, s : String) -> Unit {
  self.flush_space()
  self.put_string(s)
  self.need_sep = true
}

///|
fn Emit::inline_text(self : Emit, s : String) -> Unit {
  let mut run = false
  for c in s {
    if is_ws_char(c) {
      run = true
    } else {
      if run {
        run = false
        if !self.at_line_start {
          self.pending_space = true
        }
      }
      self.flush_space()
      self.put_char(c)
      self.need_sep = true
    }
  }
  if run && !self.at_line_start {
    self.pending_space = true
  }
}

///|
fn Emit::open_block(self : Emit) -> Unit {
  if !self.at_line_start {
    self.out.write_char('\n')
    self.at_line_start = true
    self.pending_space = false
  }
  if self.need_sep {
    self.out.write_char('\n')
    self.need_sep = false
  }
}

///|
fn Emit::close_block(self : Emit) -> Unit {
  self.need_sep = true
}

///|
fn Emit::fork(self : Emit) -> Emit {
  Emit::{
    base: self.base,
    out: StringBuilder(),
    at_line_start: true,
    need_sep: false,
    pending_space: false,
    li_fresh: false,
    first_h1: "",
    list_ordered: [],
    list_counters: [],
  }
}

///|
fn Emit::walk(self : Emit, doc : @html.Document, i : Int, depth : Int) -> Unit {
  if depth > html_max_depth {
    self.inline_text(doc.get_text_content(i))
    return
  }
  match doc.get_node(i) {
    Some(TextNode(t)) => self.inline_text(t)
    Some(ElementNode(el)) => self.walk_element(doc, i, el.tag_name, depth)
    _ => ()
  }
}

///|
fn Emit::walk_element(
  self : Emit,
  doc : @html.Document,
  i : Int,
  tag : String,
  depth : Int,
) -> Unit {
  match tag {
    "script"
    | "style"
    | "noscript"
    | "template"
    | "svg"
    | "iframe"
    | "canvas"
    | "object"
    | "embed"
    | "nav"
    | "header"
    | "footer"
    | "aside"
    | "form"
    | "button"
    | "input"
    | "select"
    | "head"
    | "title"
    | "meta"
    | "link"
    | "base" => ()
    "h1" => self.render_heading(doc, i, depth, 1)
    "h2" => self.render_heading(doc, i, depth, 2)
    "h3" => self.render_heading(doc, i, depth, 3)
    "h4" => self.render_heading(doc, i, depth, 4)
    "h5" => self.render_heading(doc, i, depth, 5)
    "h6" => self.render_heading(doc, i, depth, 6)
    "p" => self.render_p(doc, i, depth)
    "br" => self.put_char('\n')
    "hr" => {
      self.open_block()
      self.put_string("---")
      self.close_block()
    }
    "a" => self.render_link(doc, i, depth)
    "img" => self.render_img(doc, i)
    "ul" => self.render_list(doc, i, depth, false)
    "ol" => self.render_list(doc, i, depth, true)
    "li" => self.render_li(doc, i, depth)
    "pre" => self.render_pre(doc, i, depth)
    "code" => self.render_code_span(doc, i)
    "table" => self.render_table(doc, i, depth)
    "blockquote" => self.render_quote(doc, i, depth)
    "strong" | "b" => self.render_emphasis(doc, i, depth, "**")
    "em" | "i" => self.render_emphasis(doc, i, depth, "*")
    "span"
    | "del"
    | "s"
    | "u"
    | "small"
    | "bdi"
    | "bdo"
    | "cite"
    | "q"
    | "abbr"
    | "time"
    | "sub"
    | "sup"
    | "mark"
    | "font"
    | "data"
    | "dfn"
    | "kbd"
    | "samp"
    | "var"
    | "output"
    | "label"
    | "wbr" =>
      for c in doc.get_children(i) {
        self.walk(doc, c, depth + 1)
      }
    _ => {
      // Block-transparent: div/section/article/dl/custom elements …
      self.open_block()
      for c in doc.get_children(i) {
        self.walk(doc, c, depth + 1)
      }
      self.close_block()
    }
  }
}

///|
fn Emit::render_heading(
  self : Emit,
  doc : @html.Document,
  i : Int,
  depth : Int,
  level : Int,
) -> Unit {
  if level == 1 && self.first_h1.length() == 0 {
    self.first_h1 = collapse_ws(doc.get_text_content(i))
  }
  self.open_block()
  for _t in 0..<level {
    self.put_char('#')
  }
  self.pending_space = true
  for c in doc.get_children(i) {
    self.walk(doc, c, depth + 1)
  }
  self.close_block()
}

///|
fn Emit::render_p(
  self : Emit,
  doc : @html.Document,
  i : Int,
  depth : Int,
) -> Unit {
  let level = self.list_ordered.length()
  if level == 0 {
    self.open_block()
    for c in doc.get_children(i) {
      self.walk(doc, c, depth + 1)
    }
    self.close_block()
    return
  }
  // Inside a list item: first block flows on the marker line, later ones
  // break onto an indented continuation line.
  if !self.li_fresh {
    if !self.at_line_start {
      self.put_char('\n')
    }
    for _t in 0..<(level * 2) {
      self.put_char(' ')
    }
  }
  for c in doc.get_children(i) {
    self.walk(doc, c, depth + 1)
  }
}

///|
fn Emit::render_list(
  self : Emit,
  doc : @html.Document,
  i : Int,
  depth : Int,
  ordered : Bool,
) -> Unit {
  if self.list_ordered.length() == 0 {
    self.open_block()
  } else {
    // Nested list: tight — single newline, no blank line before it.
    if !self.at_line_start {
      self.put_char('\n')
    }
    self.need_sep = false
  }
  self.list_ordered.push(ordered)
  self.list_counters.push(0)
  for c in doc.get_children(i) {
    self.walk(doc, c, depth + 1)
  }
  ignore(self.list_ordered.pop())
  ignore(self.list_counters.pop())
  self.close_block()
}

///|
fn Emit::render_li(
  self : Emit,
  doc : @html.Document,
  i : Int,
  depth : Int,
) -> Unit {
  let level = self.list_ordered.length()
  if level == 0 {
    for c in doc.get_children(i) {
      self.walk(doc, c, depth + 1)
    }
    return
  }
  if !self.at_line_start {
    self.put_char('\n')
  }
  self.need_sep = false
  for _t in 0..<((level - 1) * 2) {
    self.put_char(' ')
  }
  let n = self.list_counters[level - 1] + 1
  self.list_counters[level - 1] = n
  let marker : String = if self.list_ordered[level - 1] { "\{n}." } else { "-" }
  self.put_string(marker)
  self.pending_space = true
  self.li_fresh = true
  for c in doc.get_children(i) {
    self.walk(doc, c, depth + 1)
  }
}

///|
fn Emit::render_emphasis(
  self : Emit,
  doc : @html.Document,
  i : Int,
  depth : Int,
  marker : String,
) -> Unit {
  let sub = self.fork()
  for c in doc.get_children(i) {
    sub.walk(doc, c, depth + 1)
  }
  let text = collapse_ws(sub.out.to_string())
  if text.length() > 0 {
    self.raw_inline("\{marker}\{text}\{marker}")
  }
}

///|
fn Emit::render_code_span(self : Emit, doc : @html.Document, i : Int) -> Unit {
  let raw = doc.get_text_content(i)
  if raw.trim().length() == 0 {
    return
  }
  let ticks = max_backtick_run(raw) + 1
  let fence = repeat_char('`', ticks)
  let pad : String = if raw[0] == 96 || raw[raw.length() - 1] == 96 {
    " "
  } else {
    ""
  }
  self.raw_inline("\{fence}\{pad}\{raw}\{pad}\{fence}")
}

///|
fn Emit::render_pre(
  self : Emit,
  doc : @html.Document,
  i : Int,
  depth : Int,
) -> Unit {
  let buf = StringBuilder()
  collect_raw_text(doc, i, depth, buf)
  let content = buf.to_string()
  if content.trim().length() == 0 {
    return
  }
  let lang : String = match find_code_language(doc, i) {
    Some(l) => l
    None => ""
  }
  let ticks = max_backtick_run(content) + 1
  let fence = repeat_char('`', if ticks < 3 { 3 } else { ticks })
  self.open_block()
  self.put_string("\{fence}\{lang}\n")
  self.put_string(content)
  if content[content.length() - 1] != 10 {
    self.put_char('\n')
  }
  self.put_string(fence)
  self.close_block()
}

///|
fn Emit::render_quote(
  self : Emit,
  doc : @html.Document,
  i : Int,
  depth : Int,
) -> Unit {
  let sub = self.fork()
  for c in doc.get_children(i) {
    sub.walk(doc, c, depth + 1)
  }
  let inner = sub.out.to_string().trim().to_owned()
  if inner.length() == 0 {
    return
  }
  self.open_block()
  for line in split_lines(inner) {
    if line.length() == 0 {
      self.put_string(">")
    } else {
      self.put_string("> \{line}")
    }
    self.put_char('\n')
  }
  self.close_block()
}

///|
fn Emit::render_link(
  self : Emit,
  doc : @html.Document,
  i : Int,
  depth : Int,
) -> Unit {
  let sub = self.fork()
  for c in doc.get_children(i) {
    sub.walk(doc, c, depth + 1)
  }
  let text = escape_link_text(collapse_ws(sub.out.to_string()))
  let href : String? = doc.get_attribute(i, "href")
  let url : String? = match href {
    None => None
    Some(h) => {
      let ht = h.trim().to_owned()
      if ht.length() == 0 {
        None
      } else {
        let sch = ref_scheme(ht)
        if sch == "" || sch == "http" || sch == "https" {
          Some(escape_url(resolve_ref(self.base, ht)))
        } else {
          None
        }
      }
    }
  }
  match (text, url) {
    ("", Some(u)) => self.raw_inline(u)
    (t, None) => if t.length() > 0 { self.raw_inline(t) }
    (t, Some(u)) => self.raw_inline("[\{t}](\{u})")
  }
}

///|
fn Emit::render_img(self : Emit, doc : @html.Document, i : Int) -> Unit {
  match doc.get_attribute(i, "alt") {
    Some(alt) => {
      let a = collapse_ws(alt)
      if a.length() > 0 {
        self.inline_text(a)
      }
    }
    None => ()
  }
}

///|
fn Emit::render_table(
  self : Emit,
  doc : @html.Document,
  i : Int,
  depth : Int,
) -> Unit {
  for c in doc.get_children(i) {
    if doc.get_tag_name(c) == Some("caption") {
      self.open_block()
      self.inline_text(doc.get_text_content(c))
      self.close_block()
    }
  }
  let rows : Array[Int] = []
  collect_table_rows(doc, i, depth, rows)
  let mut header = -1
  for k, r in rows {
    if table_cells(doc, r).length() > 0 {
      header = k
      break
    }
  }
  if header < 0 {
    return
  }
  self.open_block()
  let header_cells = table_cells(doc, rows[header])
  self.write_table_row(doc, header_cells, depth)
  let sep = StringBuilder()
  sep.write_char('|')
  for _t in 0..<header_cells.length() {
    sep.write_string(" --- |")
  }
  self.put_string(sep.to_string())
  self.put_char('\n')
  for k in (header + 1)..<rows.length() {
    self.write_table_row(doc, table_cells(doc, rows[k]), depth)
  }
  self.close_block()
}

///|
fn Emit::write_table_row(
  self : Emit,
  doc : @html.Document,
  cells : Array[Int],
  depth : Int,
) -> Unit {
  let b = StringBuilder()
  b.write_char('|')
  for cell in cells {
    let text = self.render_cell(doc, cell, depth)
    if text.length() > 0 {
      b.write_char(' ')
      b.write_string(text)
      b.write_char(' ')
    } else {
      b.write_char(' ')
    }
    b.write_char('|')
  }
  self.put_string(b.to_string())
  self.put_char('\n')
}

///|
fn Emit::render_cell(
  self : Emit,
  doc : @html.Document,
  cell : Int,
  depth : Int,
) -> String {
  let sub = self.fork()
  for c in doc.get_children(cell) {
    sub.walk(doc, c, depth + 1)
  }
  let b = StringBuilder()
  for ch in sub.out.to_string() {
    if ch == '\n' || ch == '\r' {
      b.write_char(' ')
    } else if ch == '|' {
      b.write_string("\\|")
    } else {
      b.write_char(ch)
    }
  }
  b.to_string().trim().to_owned()
}

///|
fn collect_raw_text(
  doc : @html.Document,
  i : Int,
  depth : Int,
  buf : StringBuilder,
) -> Unit {
  if depth > html_max_depth {
    return
  }
  match doc.get_node(i) {
    Some(TextNode(t)) => buf.write_string(t)
    Some(ElementNode(el)) =>
      if el.tag_name != "script" && el.tag_name != "style" {
        for c in doc.get_children(i) {
          collect_raw_text(doc, c, depth + 1, buf)
        }
      }
    _ => ()
  }
}

///|
fn collect_table_rows(
  doc : @html.Document,
  i : Int,
  depth : Int,
  rows : Array[Int],
) -> Unit {
  if depth > html_max_depth {
    return
  }
  for c in doc.get_children(i) {
    match doc.get_tag_name(c) {
      Some("tr") => rows.push(c)
      Some("thead") | Some("tbody") | Some("tfoot") =>
        collect_table_rows(doc, c, depth + 1, rows)
      _ => ()
    }
  }
}

///|
fn table_cells(doc : @html.Document, row : Int) -> Array[Int] {
  let cells : Array[Int] = []
  for c in doc.get_children(row) {
    match doc.get_tag_name(c) {
      Some("th") | Some("td") => cells.push(c)
      _ => ()
    }
  }
  cells
}

///|
fn find_code_language(doc : @html.Document, pre : Int) -> String? {
  match class_lang(doc.get_attribute(pre, "class")) {
    Some(l) => Some(l)
    None => {
      for c in doc.get_children(pre) {
        if doc.get_tag_name(c) == Some("code") {
          match class_lang(doc.get_attribute(c, "class")) {
            Some(l) => return Some(l)
            None => ()
          }
        }
      }
      None
    }
  }
}

///|
fn class_lang(cls : String?) -> String? {
  guard cls is Some(c) else { return None }
  let mut tok = StringBuilder()
  let mut tok_len = 0
  for ch in c {
    if is_ws_char(ch) {
      if tok_len > 0 {
        let t = tok.to_string()
        match lang_of_token(t) {
          Some(l) => return Some(l)
          None => {
            tok = StringBuilder()
            tok_len = 0
          }
        }
      }
    } else {
      tok.write_char(ch)
      tok_len = tok_len + 1
    }
  }
  if tok_len > 0 {
    lang_of_token(tok.to_string())
  } else {
    None
  }
}

///|
fn lang_of_token(t : String) -> String? {
  let rest : String? = if starts_with_str(t, "language-") {
    Some(t[9:].to_owned())
  } else if starts_with_str(t, "lang-") {
    Some(t[5:].to_owned())
  } else {
    None
  }
  guard rest is Some(r) else { return None }
  let b = StringBuilder()
  for ch in r {
    let n = ch.to_int()
    if (n >= 48 && n <= 57) ||
      (n >= 65 && n <= 90) ||
      (n >= 97 && n <= 122) ||
      n == 45 ||
      n == 43 ||
      n == 46 ||
      n == 35 ||
      n == 95 {
      b.write_char(ch)
    }
  }
  let s = b.to_string()
  if s.length() == 0 {
    None
  } else {
    Some(s)
  }
}

///|
fn starts_with_str(s : String, pre : String) -> Bool {
  if s.length() < pre.length() {
    return false
  }
  for i in 0..<pre.length() {
    if s[i] != pre[i] {
      return false
    }
  }
  true
}

///|
fn is_ws_char(c : Char) -> Bool {
  c == ' ' ||
  c == '\t' ||
  c == '\n' ||
  c == '\r' ||
  c.to_int() == 11 ||
  c.to_int() == 12 ||
  c.to_int() == 160
}

///|
fn collapse_ws(s : String) -> String {
  let b = StringBuilder()
  let mut pending = false
  let mut wrote = false
  for c in s {
    if is_ws_char(c) {
      pending = true
    } else {
      if pending && wrote {
        b.write_char(' ')
      }
      pending = false
      b.write_char(c)
      wrote = true
    }
  }
  b.to_string()
}

///|
fn split_lines(s : String) -> Array[String] {
  let res : Array[String] = []
  let mut start = 0
  for i in 0..<s.length() {
    if s[i] == 10 {
      res.push(s[start:i].to_owned())
      start = i + 1
    }
  }
  res.push(s[start:].to_owned())
  res
}

///|
fn escape_link_text(s : String) -> String {
  let b = StringBuilder()
  for c in s {
    if c == '[' || c == ']' {
      b.write_char('\\')
    }
    b.write_char(c)
  }
  b.to_string()
}

///|
fn escape_url(s : String) -> String {
  let b = StringBuilder()
  for c in s {
    if c == '(' || c == ')' {
      b.write_char('\\')
      b.write_char(c)
    } else if c == ' ' {
      b.write_string("%20")
    } else {
      b.write_char(c)
    }
  }
  b.to_string()
}

///|
fn max_backtick_run(s : String) -> Int {
  let mut best = 0
  let mut cur = 0
  for i in 0..<s.length() {
    if s[i] == 96 {
      cur = cur + 1
      if cur > best {
        best = cur
      }
    } else {
      cur = 0
    }
  }
  best
}

///|
fn repeat_char(c : Char, n : Int) -> String {
  let b = StringBuilder()
  for _t in 0..<n {
    b.write_char(c)
  }
  b.to_string()
}

///|
fn find_title_tag(doc : @html.Document) -> String? {
  for i in 0..<doc.nodes.length() {
    if doc.get_tag_name(i) == Some("title") {
      let t = collapse_ws(doc.get_text_content(i))
      if t.length() > 0 {
        return Some(t)
      }
    }
  }
  None
}

///|
fn find_og_title(doc : @html.Document) -> String? {
  for i in 0..<doc.nodes.length() {
    if doc.get_tag_name(i) == Some("meta") &&
      doc.get_attribute(i, "property") == Some("og:title") {
      match doc.get_attribute(i, "content") {
        Some(c) => {
          let t = collapse_ws(c)
          if t.length() > 0 {
            return Some(t)
          }
        }
        None => ()
      }
    }
  }
  None
}

///|
fn base_last_segment(base : String) -> String {
  match parse_url(base) {
    Some(u) => {
      let p = u.path
      let mut cut = -1
      for k in 0..<p.length() {
        if p[k] == 47 {
          cut = k
        }
      }
      let last : String = if cut >= 0 { p[cut + 1:].to_owned() } else { p }
      if last.length() > 0 {
        last
      } else {
        u.host_display()
      }
    }
    None => base
  }
}

///|
fn html_to_markdown(html : String, base~ : String) -> HtmlDoc {
  let doc = @html.parse(html)
  let emit = Emit::{
    base,
    out: StringBuilder(),
    at_line_start: true,
    need_sep: false,
    pending_space: false,
    li_fresh: false,
    first_h1: "",
    list_ordered: [],
    list_counters: [],
  }
  let root : Int = if doc.body_element >= 0 {
    doc.body_element
  } else {
    doc.document_element
  }
  if root >= 0 {
    for c in doc.get_children(root) {
      emit.walk(doc, c, 1)
    }
  }
  let markdown = emit.out.to_string().trim().to_owned()
  let title : String = match find_title_tag(doc) {
    Some(t) => t
    None =>
      match find_og_title(doc) {
        Some(t) => t
        None =>
          if emit.first_h1.length() > 0 {
            emit.first_h1
          } else {
            base_last_segment(base)
          }
      }
  }
  HtmlDoc::{ title, markdown, }
}
