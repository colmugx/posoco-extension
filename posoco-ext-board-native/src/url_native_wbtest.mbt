///|
fn board_query_param(path : String, key : String) -> String? {
  let query = match path.find("?") {
    Some(index) => path.exact_view(start=index + 1).to_owned()
    None => return None
  }
  let prefix = key + "="
  for part in query.split("&") {
    let value = part.to_owned()
    if value.has_prefix(prefix) {
      return Some(value.exact_view(start=prefix.length()).to_owned())
    }
  }
  None
}
