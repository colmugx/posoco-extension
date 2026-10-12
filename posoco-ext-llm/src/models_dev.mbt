///|
pub(open) trait ModelMetadataTransport {
  async fn fetch(Self) -> Json
}

///|
pub(open) trait ModelMetadataStore {
  async fn read(Self) -> Json?
  async fn write(Self, Json) -> Unit
}

///|
priv struct HttpModelMetadataTransport {}

///|
impl ModelMetadataTransport for HttpModelMetadataTransport with fn fetch(
  _self : HttpModelMetadataTransport,
) -> Json {
  let (response, body) = @async.with_timeout(10_000, () => {
    @http.get("https://models.dev/api.json", headers={
      "Accept": "application/json",
    })
  })
  if response.code < 200 || response.code >= 300 {
    fail("models.dev HTTP status: \{response.code}")
  }
  @json.parse(body.text())
}

///|
pub struct ModelMetadata {
  priv entries : Map[String, Map[String, Int]]
  priv fetched_at : Map[String, Int64]
  priv warned_fallbacks : Map[String, Bool]
  priv gate : @async.Mutex
  priv transport : &ModelMetadataTransport
  priv store : &ModelMetadataStore?
  priv mut loaded : Bool
  priv mut failed_at : Int64?
  priv warn : async (String) -> Unit noraise
}

///|
pub fn ModelMetadata::ModelMetadata(
  transport? : &ModelMetadataTransport = HttpModelMetadataTransport::{ },
  store? : &ModelMetadataStore? = None,
  warn? : async (String) -> Unit noraise = fn(_ : String) { () },
) -> ModelMetadata {
  {
    entries: Map::from_array([]),
    fetched_at: Map::from_array([]),
    warned_fallbacks: Map::from_array([]),
    gate: @async.Mutex(),
    transport,
    store,
    loaded: false,
    failed_at: None,
    warn,
  }
}

///|
async fn ModelMetadata::report_fallback(
  self : ModelMetadata,
  provider_id : String,
  model_id : String,
) -> Unit noraise {
  let key = provider_id + "/" + model_id
  if !self.warned_fallbacks.contains(key) {
    self.warned_fallbacks[key] = true
    (self.warn)(
      "context window for " +
      key +
      " is unverified; using 500000-token fallback for auto compact. A smaller real window can overflow before this threshold; configure context_window to override it.",
    )
  }
}

///|
fn models_dev_windows(
  payload : Json,
  provider_id : String,
) -> Map[String, Int]? {
  guard payload is Json::Object(providers) else { return None }
  guard providers.get(provider_id) is Some(Json::Object(provider)) else {
    return None
  }
  guard provider.get("models") is Some(Json::Object(models)) else {
    return None
  }
  let result : Map[String, Int] = Map::from_array([])
  for id, model in models {
    if model is Json::Object(fields) &&
      fields.get("limit") is Some(Json::Object(limits)) {
      if context_window_integer(limits.get("context")) is Some(window) {
        result[id] = window
      }
    }
  }
  Some(result)
}

///|
pub fn ModelMetadata::lookup(
  self : ModelMetadata,
  provider_id : String,
  model_id : String,
  now? : Int64 = @async.now(),
) -> ContextWindowReading {
  match self.entries.get(provider_id) {
    Some(models) =>
      match models.get(model_id) {
        Some(tokens) =>
          {
            tokens,
            source: "models_dev",
            stale: match self.fetched_at.get(provider_id) {
              Some(time) => now < time || now - time >= 86_400_000L
              None => true
            },
          }
        None => { tokens: 500_000, source: "fallback", stale: false, }
      }
    None => { tokens: 500_000, source: "fallback", stale: false, }
  }
}

///|
fn ModelMetadata::restore(self : ModelMetadata, payload : Json) -> Unit raise {
  guard payload is Json::Object(root) &&
    root.get("version") == Some(Json::number(1.0)) &&
    root.get("providers") is Some(Json::Object(providers)) else {
    fail("models.dev cache has an invalid schema")
  }
  let entries : Map[String, Map[String, Int]] = Map::from_array([])
  let times : Map[String, Int64] = Map::from_array([])
  for id, record in providers {
    guard record is Json::Object(fields) &&
      fields.get("models") is Some(Json::Object(models)) &&
      fields.get("fetched_at") is Some(Json::String(timestamp)) else {
      fail("models.dev cache provider record is invalid")
    }
    let time = @string.parse_int64(timestamp)
    if time < 0L {
      fail("models.dev cache timestamp is invalid")
    }
    let windows : Map[String, Int] = Map::from_array([])
    for model_id, value in models {
      guard context_window_integer(Some(value)) is Some(window) else {
        fail("models.dev cache window is invalid")
      }
      windows[model_id] = window
    }
    entries[id] = windows
    times[id] = time
  }
  for id, models in entries {
    self.entries[id] = models
    self.fetched_at[id] = times[id]
  }
}

///|
fn ModelMetadata::cache_json(self : ModelMetadata) -> Json {
  let providers : Map[String, Json] = Map::from_array([])
  for id, models in self.entries {
    let windows : Map[String, Json] = Map::from_array([])
    for model_id, window in models {
      windows[model_id] = Json::number(window.to_double())
    }
    providers[id] = {
      "fetched_at": Json::string(self.fetched_at[id].to_string()),
      "models": Json::object(windows),
    }
  }
  { "version": 1, "providers": Json::object(providers) }
}

///|
/// Refresh only requested serving providers. Failures retain the last good
/// snapshot; cancellation unwinds the gate so the next operation can retry.
pub async fn ModelMetadata::refresh(
  self : ModelMetadata,
  provider_ids : Array[String],
  now? : Int64 = @async.now(),
) -> Unit noraise {
  self.gate.acquire()
  defer self.gate.release()
  if !self.loaded {
    match self.store {
      Some(store) =>
        try {
          if store.read() is Some(payload) {
            self.restore(payload)
          }
        } catch {
          err => (self.warn)("models.dev cache read failed: " + err.to_string())
        }
      None => ()
    }
    self.loaded = true
  }
  let needed : Array[String] = []
  for id in provider_ids {
    let fresh = match self.fetched_at.get(id) {
      Some(time) => time <= now && now - time < 86_400_000L
      None => false
    }
    if !fresh && !needed.contains(id) {
      needed.push(id)
    }
  }
  if needed.is_empty() {
    return
  }
  if self.failed_at is Some(time) && time <= now && now - time < 60_000L {
    return
  }
  let payload = self.transport.fetch() catch {
    err => {
      self.failed_at = Some(now)
      (self.warn)("models.dev refresh failed: " + err.to_string())
      return
    }
  }
  guard payload is Json::Object(_) else {
    self.failed_at = Some(now)
    (self.warn)("models.dev refresh failed: root must be an object")
    return
  }
  let mut changed = false
  for id in needed {
    match models_dev_windows(payload, id) {
      Some(windows) if !windows.is_empty() => {
        self.entries[id] = windows
        self.fetched_at[id] = now
        changed = true
      }
      _ =>
        (self.warn)(
          "models.dev has no valid context windows for provider " + id,
        )
    }
  }
  self.failed_at = if changed { None } else { Some(now) }
  if changed {
    match self.store {
      Some(store) =>
        store.write(self.cache_json()) catch {
          err =>
            (self.warn)("models.dev cache write failed: " + err.to_string())
        }
      None => ()
    }
  }
}
