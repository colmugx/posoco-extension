///|
/// Mutating a returned entry's raw nested JSON must never rewrite the
/// manager's last-known-good catalog.
async test "catalog_entry returns a fully isolated raw JSON snapshot" {
  let transport = gateway(
    models=models_body(
      model_entry(
        id="m/snapshot",
        fields="\"reasoning\":true,\"native_endpoints\":[\"/v1/messages\"],\"modalities\":{\"input\":[\"text\",\"image\"]}",
      ),
    ),
  )
  let manager = manager_with(transport~, config=local_config())
  refresh_ok(manager)
  guard manager.catalog_entry("m/snapshot") is Some(first) else {
    fail("missing model")
  }
  match first.raw {
    Json::Object(fields) => {
      fields["id"] = Json::string("mutated")
      match fields.get("modalities") {
        Some(Json::Object(modalities)) =>
          match modalities.get("input") {
            Some(Json::Array(inputs)) => inputs.push(Json::string("tampered"))
            _ => fail("missing raw inputs")
          }
        _ => fail("missing raw modalities")
      }
    }
    _ => fail("expected object")
  }
  guard manager.catalog_entry("m/snapshot") is Some(second) else {
    fail("model id changed by caller")
  }
  match second.raw {
    Json::Object(fields) => {
      inspect(
        fields.get("id") == Some(Json::string("m/snapshot")),
        content="true",
      )
      match fields.get("modalities") {
        Some(Json::Object(modalities)) =>
          match modalities.get("input") {
            Some(Json::Array(inputs)) => inspect(inputs.length(), content="2")
            _ => fail("missing untouched raw inputs")
          }
        _ => fail("missing untouched raw modalities")
      }
    }
    _ => fail("expected object")
  }
}
