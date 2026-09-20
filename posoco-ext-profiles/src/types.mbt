///|
/// Reserved profile id: the one program-decided builtin preset meaning
/// "every deep-deferred extension". Manifest files may never claim it (Q16) —
/// `all` is activated like any profile but is not authorable.
let reserved_profile_id : String = "all"

///|
/// A named intent package: which extensions belong to one working mode. The
/// manifest is the only author-facing surface — a single file, ext
/// granularity, no tool globs.
///
/// - `id` doubles as the manifest file name stem and the activation
///   identity. It must be non-empty, contain no path separators, and must
///   not be the reserved id `all` (Q16).
/// - `description` is the one-sentence "when to activate" line the profile
///   menu shows; one content, two uses (menu + save flow).
/// - `exts` is the member extension id list, deduplicated preserving first
///   occurrence. An empty list is legal: a profile that activates nothing.
pub(all) struct ProfileManifest {
  id : String
  name : String
  description : String
  exts : Array[String]
} derive(Eq, Debug)

///|
/// Parse a profile manifest from JSON. The value must be an object with
/// string fields `id` / `name` / `description` and a string array `exts`;
/// `id` additionally passes the non-empty, path-separator, and reserved-id
/// checks. Every violation yields an Err naming the reason. Duplicate
/// entries in `exts` are deduplicated preserving first occurrence.
pub fn parse_profile_manifest(value : Json) -> Result[ProfileManifest, String] {
  let fields = match value {
    Json::Object(fields) => fields
    _ => return Err("profile manifest must be a JSON object")
  }
  let id = match fields.get("id") {
    Some(Json::String(id)) =>
      if id.length() == 0 {
        return Err("profile manifest field 'id' must be non-empty")
      } else if id.contains("/") || id.contains("\\") {
        return Err(
          "profile manifest id '\{id}' must not contain path separators",
        )
      } else if id == reserved_profile_id {
        return Err("profile manifest id '\{id}' is reserved")
      } else {
        id
      }
    Some(_) => return Err("profile manifest field 'id' must be a string")
    None => return Err("profile manifest is missing field 'id'")
  }
  let name = match fields.get("name") {
    Some(Json::String(name)) =>
      if name.length() == 0 {
        return Err("profile manifest field 'name' must be non-empty")
      } else {
        name
      }
    Some(_) => return Err("profile manifest field 'name' must be a string")
    None => return Err("profile manifest is missing field 'name'")
  }
  let description = match fields.get("description") {
    Some(Json::String(description)) =>
      if description.length() == 0 {
        return Err("profile manifest field 'description' must be non-empty")
      } else {
        description
      }
    Some(_) =>
      return Err("profile manifest field 'description' must be a string")
    None => return Err("profile manifest is missing field 'description'")
  }
  let exts : Array[String] = []
  match fields.get("exts") {
    Some(Json::Array(items)) =>
      for item in items {
        match item {
          Json::String(ext) => if !exts.contains(ext) { exts.push(ext) }
          _ =>
            return Err(
              "profile manifest field 'exts' must contain only strings",
            )
        }
      }
    Some(_) =>
      return Err("profile manifest field 'exts' must be an array of strings")
    None => return Err("profile manifest is missing field 'exts'")
  }
  Ok({ id, name, description, exts, })
}

///|
/// Serialize back to the manifest JSON shape. The host persists exactly this
/// through the `ProfileStore` seam and `parse_profile_manifest` reads it
/// back — the two functions share one file format.
pub fn ProfileManifest::to_json(self : ProfileManifest) -> Json {
  Json::object(
    Map::from_array([
      ("id", Json::string(self.id)),
      ("name", Json::string(self.name)),
      ("description", Json::string(self.description)),
      ("exts", Json::array(self.exts.map(fn(ext) { Json::string(ext) }))),
    ]),
  )
}
