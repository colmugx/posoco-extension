///|
/// Build one moonrun `--policy` JSON document (verified schema, moonrun
/// 0.1.20260827): deny-by-default; `env.from_host` passes host environment
/// through; `fs.read` is world-readable while `fs.write` is confined to the
/// call's temp roots; `net` allows outbound DNS/connect and loopback-only
/// bind; `process.allow` enumerates the exact spawnable programs, where a
/// rule with an empty `args_prefix` means any arguments (the field is
/// omitted rather than sent empty). Pure function — snapshot-tested.
#warnings("-unused_value")
fn build_policy(
  rules~ : Array[SpawnRule],
  write_roots~ : Array[String],
) -> Json {
  let allow : Array[Json] = []
  for rule in rules {
    let entry : Array[(String, Json)] = [
      ("program", Json::string(rule.program)),
    ]
    if rule.args_prefix.length() > 0 {
      entry.push(
        ("args_prefix", Json::array(rule.args_prefix.map(Json::string))),
      )
    }
    allow.push(Json::object(Map::from_array(entry)))
  }
  Json::object(
    Map::from_array([
      (
        "env",
        Json::object(
          Map::from_array([("from_host", Json::array([Json::string("*")]))]),
        ),
      ),
      (
        "fs",
        Json::object(
          Map::from_array([
            ("read", Json::array([Json::string("*")])),
            ("write", Json::array(write_roots.map(Json::string))),
          ]),
        ),
      ),
      (
        "net",
        Json::object(
          Map::from_array([
            ("dns", Json::array([Json::string("*")])),
            ("connect", Json::array([Json::string("*:*")])),
            (
              "bind",
              Json::array([Json::string("127.0.0.1:*"), Json::string("[::1]:*")]),
            ),
          ]),
        ),
      ),
      (
        "process",
        Json::object(Map::from_array([("allow", Json::array(allow))])),
      ),
    ]),
  )
}
