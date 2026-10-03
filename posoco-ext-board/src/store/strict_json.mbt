///|
/// Core JSON parsing overwrites duplicate object keys. Check the validated
/// input's key tokens as well, including escaped spellings of the same key.
fn strict_json(input : String) -> Json raise {
  let value = @json.parse(input)
  let objects : Array[Map[String, Bool]] = []
  let mut i = 0
  while i < input.length() {
    match input[i] {
      '{' => {
        objects.push(Map::from_array([]))
        i = i + 1
      }
      '}' => {
        let _ = objects.pop()
        i = i + 1
      }
      '"' => {
        let start = i
        i = i + 1
        while input[i] != '"' {
          if input[i] == '\\' {
            i = i + 1
          }
          i = i + 1
        }
        i = i + 1
        let end = i
        while i < input.length() &&
              (
                input[i] == ' ' ||
                input[i] == '\n' ||
                input[i] == '\r' ||
                input[i] == '\t'
              ) {
          i = i + 1
        }
        if i < input.length() && input[i] == ':' {
          let key = text(@json.parse(input[start:end]))
          let keys = objects[objects.length() - 1]
          if keys.contains(key) {
            bad("duplicate JSON field")
          }
          keys[key] = true
        }
      }
      _ => i = i + 1
    }
  }
  value
}
