///|
/// Strict bounded JSON scanning for S4E1 proposal payloads. The scanner is
/// written once for this package and trusts nothing:
///
/// - the whole payload is bounded by UTF-8 byte length before any parsing;
/// - nesting depth is bounded during parsing (no unbounded recursion);
/// - every container is bounded in entry count and every string in length;
/// - unescaped control characters and unpaired surrogates (raw or escaped)
///   are rejected, so decoded strings are always well-formed UTF-16;
/// - numbers must be well-formed JSON; the schema layer additionally demands
///   the exact literal it accepts.
///
/// The scanner produces a small ordered value tree; field-level policy
/// bounds and duplicate-field detection are enforced by `schema.mbt` on top.

///|
priv enum JsonValue {
  Obj(Array[(String, JsonValue)])
  Arr(Array[JsonValue])
  Str(String)
  Num(String)
  Bool(Bool)
  Null
}

///|
priv suberror ScanAbort {
  /// Structural/lexical failure inside the scanner itself.
  Abort(offset~ : Int32, reason~ : String)
  /// Encoding-level failure (surrogates, control characters).
  Encoding(offset~ : Int32, reason~ : String)
  /// A pre-parse or in-parse bound was exceeded.
  Limit(reason~ : String)
}

///|
priv struct ScanLimits {
  max_bytes : Int32
  max_depth : Int32
  max_items : Int32
  max_string_units : Int32
}

///|
priv struct Scanner {
  input : String
  len : Int32
  limits : ScanLimits
  mut pos : Int32
}

///|
fn[T] Scanner::fail(self : Scanner, reason~ : String) -> T raise ScanAbort {
  raise ScanAbort::Abort(offset=self.pos, reason~)
}

///|
fn[T] Scanner::eof(self : Scanner) -> T raise ScanAbort {
  raise ScanAbort::Abort(offset=self.pos, reason="unexpected end of input")
}

///|
fn Scanner::peek(self : Scanner) -> UInt16? {
  if self.pos < self.len {
    Some(self.input[self.pos])
  } else {
    None
  }
}

///|
fn Scanner::skip_ws(self : Scanner) -> Unit {
  while self.pos < self.len {
    match self.input[self.pos] {
      0x20 | 0x09 | 0x0A | 0x0D => self.pos += 1
      _ => break
    }
  }
}

///|
fn Scanner::expect(self : Scanner, unit : UInt16) -> Unit raise ScanAbort {
  guard self.pos < self.len else { self.eof() }
  if self.input[self.pos] == unit {
    self.pos += 1
  } else {
    self.fail(reason="expected '\{unit}'")
  }
}

///|
fn Scanner::literal(
  self : Scanner,
  word : String,
  value : JsonValue,
) -> JsonValue raise ScanAbort {
  for unit in word {
    guard self.pos < self.len else { self.eof() }
    if self.input[self.pos].to_int() != unit.to_int() {
      self.fail(reason="invalid literal")
    }
    self.pos += 1
  }
  value
}

///|
/// Total UTF-8 byte length of the payload, computed without materializing
/// anything. Astral characters (valid surrogate pairs) count four bytes, as
/// they will in any downstream encoding.
fn utf8_length(input : String) -> Int32 {
  let len = input.length()
  let mut bytes = 0
  let mut i = 0
  while i < len {
    let unit = input[i]
    if unit < 0x80 {
      bytes += 1
      i += 1
    } else if unit.is_leading_surrogate() &&
      i + 1 < len &&
      input[i + 1].is_trailing_surrogate() {
      bytes += 4
      i += 2
    } else if unit < 0x800 {
      bytes += 2
      i += 1
    } else {
      bytes += 3
      i += 1
    }
  }
  bytes
}

///|
fn Scanner::string_budget(
  self : Scanner,
  units : Int32,
  needed : Int32,
) -> Unit raise ScanAbort {
  if units + needed > self.limits.max_string_units {
    raise ScanAbort::Limit(
      reason="string exceeds \{self.limits.max_string_units} code units",
    )
  }
}

///|
fn Scanner::hex4(self : Scanner) -> Int32 raise ScanAbort {
  let mut value = 0
  for _ in 0..<4 {
    guard self.pos < self.len else { self.eof() }
    let unit = self.input[self.pos]
    let digit = match unit {
      0x30..<=0x39 => unit.to_int() - 0x30
      0x41..<=0x46 => unit.to_int() - 0x41 + 10
      0x61..<=0x66 => unit.to_int() - 0x61 + 10
      _ => raise ScanAbort::Abort(offset=self.pos, reason="invalid \\u digit")
    }
    value = value * 16 + digit
    self.pos += 1
  }
  value
}

///|
fn Scanner::parse_string(self : Scanner) -> String raise ScanAbort {
  self.expect('"')
  let buf = StringBuilder()
  let mut units = 0
  for ;; {
    guard self.pos < self.len else { self.eof() }
    let unit = self.input[self.pos]
    if unit == '"' {
      self.pos += 1
      return buf.to_string()
    }
    if unit == '\\' {
      self.pos += 1
      guard self.pos < self.len else { self.eof() }
      match self.input[self.pos] {
        '"' => {
          self.string_budget(units, 1)
          buf.write_char('"')
          self.pos += 1
          units += 1
        }
        '\\' => {
          self.string_budget(units, 1)
          buf.write_char('\\')
          self.pos += 1
          units += 1
        }
        '/' => {
          self.string_budget(units, 1)
          buf.write_char('/')
          self.pos += 1
          units += 1
        }
        'b' => {
          self.string_budget(units, 1)
          buf.write_char('\u{0008}')
          self.pos += 1
          units += 1
        }
        'f' => {
          self.string_budget(units, 1)
          buf.write_char('\u{000C}')
          self.pos += 1
          units += 1
        }
        'n' => {
          self.string_budget(units, 1)
          buf.write_char('\n')
          self.pos += 1
          units += 1
        }
        'r' => {
          self.string_budget(units, 1)
          buf.write_char('\r')
          self.pos += 1
          units += 1
        }
        't' => {
          self.string_budget(units, 1)
          buf.write_char('\t')
          self.pos += 1
          units += 1
        }
        'u' => {
          self.pos += 1
          let escape_start = self.pos - 2
          let scalar = self.escape_scalar(escape_start~)
          // A combined astral pair is stored as two UTF-16 code units.
          let needed = if scalar > 0xFFFF { 2 } else { 1 }
          self.string_budget(units, needed)
          buf.write_char(scalar.unsafe_to_char())
          units += needed
        }
        _ => raise ScanAbort::Abort(offset=self.pos, reason="invalid escape")
      }
      continue
    }
    if unit < 0x20 {
      raise ScanAbort::Encoding(
        offset=self.pos,
        reason="unescaped control character",
      )
    }
    if unit.is_surrogate() {
      if unit.is_leading_surrogate() &&
        self.pos + 1 < self.len &&
        self.input[self.pos + 1].is_trailing_surrogate() {
        let trail = self.input[self.pos + 1]
        let scalar = 0x10000 +
          (unit.to_int() - 0xD800) * 0x400 +
          (trail.to_int() - 0xDC00)
        self.string_budget(units, 2)
        buf.write_char(scalar.unsafe_to_char())
        units += 2
        self.pos += 2
        continue
      }
      raise ScanAbort::Encoding(offset=self.pos, reason="unpaired surrogate")
    }
    self.string_budget(units, 1)
    buf.write_char(unit.unsafe_to_char())
    units += 1
    self.pos += 1
  }
}

///|
/// Decode one `\uXXXX` escape; a leading surrogate must be immediately
/// followed by the matching trailing escape and the pair is combined into
/// one scalar value. Lone surrogate escapes are rejected.
fn Scanner::escape_scalar(
  self : Scanner,
  escape_start~ : Int32,
) -> Int32 raise ScanAbort {
  let first = self.hex4()
  if first is (0xD800..<=0xDBFF) {
    guard self.pos + 1 < self.len else { self.eof() }
    if self.input[self.pos] != '\\' || self.input[self.pos + 1] != 'u' {
      raise ScanAbort::Encoding(
        offset=escape_start,
        reason="unpaired surrogate escape",
      )
    }
    self.pos += 2
    let second = self.hex4()
    if second is (0xDC00..<=0xDFFF) {
      (first - 0xD800) * 0x400 + (second - 0xDC00) + 0x10000
    } else {
      raise ScanAbort::Encoding(
        offset=escape_start,
        reason="unpaired surrogate escape",
      )
    }
  } else if first is (0xDC00..<=0xDFFF) {
    raise ScanAbort::Encoding(
      offset=escape_start,
      reason="lone trailing surrogate escape",
    )
  } else {
    first
  }
}

///|
fn Scanner::parse_number(self : Scanner) -> String raise ScanAbort {
  let start = self.pos
  if self.peek() == Some('-') {
    self.pos += 1
  }
  // Integer part: JSON forbids leading zeros.
  match self.peek() {
    Some('0') => self.pos += 1
    Some(unit) if unit is ('1'..<='9') => {
      self.pos += 1
      while self.pos < self.len && self.input[self.pos] is ('0'..<='9') {
        self.pos += 1
      }
    }
    _ => raise ScanAbort::Abort(offset=start, reason="invalid number")
  }
  if self.peek() == Some('.') {
    self.pos += 1
    guard self.pos < self.len && self.input[self.pos] is ('0'..<='9') else {
      raise ScanAbort::Abort(offset=start, reason="invalid fraction")
    }
    while self.pos < self.len && self.input[self.pos] is ('0'..<='9') {
      self.pos += 1
    }
  }
  match self.peek() {
    Some('e') | Some('E') => {
      self.pos += 1
      match self.peek() {
        Some('+') | Some('-') => self.pos += 1
        _ => ()
      }
      guard self.pos < self.len && self.input[self.pos] is ('0'..<='9') else {
        raise ScanAbort::Abort(offset=start, reason="invalid exponent")
      }
      while self.pos < self.len && self.input[self.pos] is ('0'..<='9') {
        self.pos += 1
      }
    }
    _ => ()
  }
  self.input[start:self.pos].to_owned()
}

///|
fn Scanner::parse_value(
  self : Scanner,
  depth : Int32,
) -> JsonValue raise ScanAbort {
  if depth > self.limits.max_depth {
    raise ScanAbort::Limit(
      reason="nesting exceeds \{self.limits.max_depth} levels",
    )
  }
  self.skip_ws()
  guard self.pos < self.len else { self.eof() }
  match self.input[self.pos] {
    '{' => self.parse_object(depth)
    '[' => self.parse_array(depth)
    '"' => JsonValue::Str(self.parse_string())
    't' => self.literal("true", JsonValue::Bool(true))
    'f' => self.literal("false", JsonValue::Bool(false))
    'n' => self.literal("null", JsonValue::Null)
    '-' => JsonValue::Num(self.parse_number())
    unit if unit is ('0'..<='9') => JsonValue::Num(self.parse_number())
    _ => self.fail(reason="unexpected character")
  }
}

///|
fn Scanner::parse_object(
  self : Scanner,
  depth : Int32,
) -> JsonValue raise ScanAbort {
  self.expect('{')
  let entries : Array[(String, JsonValue)] = []
  self.skip_ws()
  if self.peek() == Some('}') {
    self.pos += 1
    return JsonValue::Obj(entries)
  }
  for ;; {
    self.skip_ws()
    let key = self.parse_string()
    self.skip_ws()
    self.expect(':')
    let value = self.parse_value(depth + 1)
    entries.push((key, value))
    if entries.length() > self.limits.max_items {
      raise ScanAbort::Limit(
        reason="object exceeds \{self.limits.max_items} fields",
      )
    }
    self.skip_ws()
    match self.peek() {
      Some(',') => self.pos += 1
      Some('}') => {
        self.pos += 1
        return JsonValue::Obj(entries)
      }
      _ => self.fail(reason="expected ',' or '}'")
    }
  }
}

///|
fn Scanner::parse_array(
  self : Scanner,
  depth : Int32,
) -> JsonValue raise ScanAbort {
  self.expect('[')
  let items : Array[JsonValue] = []
  self.skip_ws()
  if self.peek() == Some(']') {
    self.pos += 1
    return JsonValue::Arr(items)
  }
  for ;; {
    let value = self.parse_value(depth + 1)
    items.push(value)
    if items.length() > self.limits.max_items {
      raise ScanAbort::Limit(
        reason="array exceeds \{self.limits.max_items} items",
      )
    }
    self.skip_ws()
    match self.peek() {
      Some(',') => self.pos += 1
      Some(']') => {
        self.pos += 1
        return JsonValue::Arr(items)
      }
      _ => self.fail(reason="expected ',' or ']'")
    }
  }
}

///|
fn scan_json(
  payload~ : String,
  limits~ : ScanLimits,
) -> JsonValue raise ScanAbort {
  if payload.length() == 0 {
    raise ScanAbort::Abort(offset=0, reason="empty payload")
  }
  if utf8_length(payload) > limits.max_bytes {
    raise ScanAbort::Limit(reason="payload exceeds \{limits.max_bytes} bytes")
  }
  let scanner : Scanner = {
    input: payload,
    len: payload.length(),
    limits,
    pos: 0,
  }
  let value = scanner.parse_value(1)
  scanner.skip_ws()
  if scanner.pos != scanner.len {
    scanner.fail(reason="trailing content after JSON value")
  }
  value
}
