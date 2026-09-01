///|
/// Default thread sync timeout in milliseconds (upstream
/// DEFAULT_THREAD_SYNC_TIMEOUT_MS = 120_000), overridable through
/// NMEM_SYNC_TIMEOUT_MS via resolve_thread_sync_timeout_ms.
pub const DEFAULT_THREAD_SYNC_TIMEOUT_MS : Int = 120_000

///|
const NMEM_MIN_THREAD_SYNC_TIMEOUT_MS : Int = 1_000

///|
const NMEM_MAX_THREAD_SYNC_TIMEOUT_MS : Int = 1_800_000

///|
const NMEM_SAFE_INTEGER_MAX_AS_DOUBLE : Double = 9007199254740991.0

///|
/// Resolve NMEM_SYNC_TIMEOUT_MS (upstream resolveThreadSyncTimeoutMs):
/// blank, non-numeric, non-integral, or non-positive input yields the
/// default; everything else is clamped into [1s, 30min]. Parsing goes through
/// Double so exponent forms like "1e3" behave like upstream's Number().
pub fn resolve_thread_sync_timeout_ms(raw : String?) -> Int {
  let trimmed = match raw {
    Some(text) => text.trim().to_owned()
    None => return DEFAULT_THREAD_SYNC_TIMEOUT_MS
  }
  if trimmed == "" {
    return DEFAULT_THREAD_SYNC_TIMEOUT_MS
  }
  // -1.0 fails the positive gate below, standing in for unparseable input.
  let parsed : Double = @string.parse_double(trimmed) catch { _ => -1.0 }
  let safe_integer = parsed.floor() == parsed &&
    parsed > 0.0 &&
    parsed <= NMEM_SAFE_INTEGER_MAX_AS_DOUBLE
  if !safe_integer {
    DEFAULT_THREAD_SYNC_TIMEOUT_MS
  } else if parsed > NMEM_MAX_THREAD_SYNC_TIMEOUT_MS.to_double() {
    NMEM_MAX_THREAD_SYNC_TIMEOUT_MS
  } else if parsed.to_int() < NMEM_MIN_THREAD_SYNC_TIMEOUT_MS {
    NMEM_MIN_THREAD_SYNC_TIMEOUT_MS
  } else {
    parsed.to_int()
  }
}

///|
/// One staged flush of a lane: the latest transcript snapshot plus everything
/// needed to send it (upstream SyncPayload; `config` replaces the payload's
/// destination reference). Assembled by build_sync_request.
pub(all) struct SyncRequest {
  lane_key : String
  thread_id : String
  session_id : String
  body : Json
  messages : Array[NmemThreadMessage]
  config : NmemConfig
  sync_reason : String
} derive(Debug)

///|
/// Per-lane sync state (upstream SyncState minus its timer/in-flight fields,
/// which the SyncEngine loop replaces). `pending` holds the newest
/// not-yet-flushed request — upstream coalesces the same way by keeping only
/// the latest payload while a flush is in flight.
pub(all) struct LaneState {
  created : Bool
  acknowledged : AckedCursor?
  last_error : String?
  pending : SyncRequest?
} derive(Debug)

///|
/// Map a captured transcript snapshot to the request for one flush (upstream
/// buildSyncPayload): message mapping, shouldSync gate, thread id/title, the
/// create body, and the lane key. Returns `None` when the transcript has no
/// user/assistant pair yet — such snapshots never enter the queue.
pub fn build_sync_request(
  messages : Array[@posoco.Message],
  session_id~ : String,
  config~ : NmemConfig,
  sync_reason~ : String,
) -> SyncRequest? {
  let thread_messages = map_messages(messages, config~, session_id~)
  if !should_sync(thread_messages) {
    return None
  }
  let id = thread_id(config.source_app, session_id)
  Some({
    lane_key: sync_lane_key(id, config),
    thread_id: id,
    session_id,
    body: build_thread_body(
      thread_id=id,
      title=thread_title(thread_messages, config.source_app),
      messages=thread_messages,
      config~,
      session_id~,
      sync_reason~,
    ),
    messages: thread_messages,
    config,
    sync_reason,
  })
}

///|
/// Resolved outcome of one logical POST: a decoded response or a
/// transport-level failure (status 0, null body, `failure` holding the
/// error message). Upstream folds this shape into postJson's
/// {ok, status, data} triple.
priv struct NmemPostOutcome {
  ok : Bool
  status : Int
  body : Json
  failure : String?
}

///|
fn http_status_ok(status : Int) -> Bool {
  status >= 200 && status <= 299
}

///|
/// POST `path` against the configured api url, trying each /remote-api
/// fallback origin (upstream postJson). The next url is attempted when the
/// current one answers 404/405 (upstream shouldTryRemoteApiFallback) or when
/// the transport fails before a response arrives; any other answer is final.
async fn nmem_post(
  transport : &NmemTransport,
  config : NmemConfig,
  path : String,
  body : Json,
  timeout_ms~ : Int,
) -> NmemPostOutcome {
  let primary = config.api_url + path
  let urls : Array[String] = [primary]
  for fallback in remote_api_fallback_urls(primary) {
    urls.push(fallback)
  }
  let headers = nmem_request_headers(config)
  let wire_body = with_space_id(body, config.space)
  let mut last : NmemPostOutcome = {
    ok: false,
    status: 0,
    body: Json::null(),
    failure: Some("request was not sent"),
  }
  for url in urls {
    match
      NmemTransport::post_json(transport, url, headers, wire_body, timeout_ms~) {
      Ok(response) => {
        last = {
          ok: http_status_ok(response.status),
          status: response.status,
          body: response.body,
          failure: None,
        }
        if http_status_ok(response.status) ||
          !(response.status == 404 || response.status == 405) {
          return last
        }
      }
      Err(message) =>
        last = {
          ok: false,
          status: 0,
          body: Json::null(),
          failure: Some(message),
        }
    }
  }
  last
}

///|
fn thread_sync_failed_error(outcome : NmemPostOutcome) -> String {
  let detail = match outcome.failure {
    Some(message) => message
    None => outcome.body.stringify()
  }
  "thread sync failed (\{outcome.status}): \{detail}"
}

///|
/// POST /threads/{id}/append body (upstream flushOnce): the delta messages,
/// deduplication, an idempotency key, and — in checkpoint mode — the expected
/// remote count.
fn append_body(
  messages : Array[NmemThreadMessage],
  idempotency_key : String,
  expected_remote_count : Int?,
) -> Json {
  let fields : Map[String, Json] = {
    "messages": Json::array(messages.map(m => m.to_wire_json())),
    "deduplicate": Json::boolean(true),
    "idempotency_key": Json::string(idempotency_key),
  }
  match expected_remote_count {
    Some(count) =>
      fields["expected_message_count"] = Json::number(count.to_double())
    None => ()
  }
  Json::object(fields)
}

///|
/// Run one flush attempt for `request` against `state` (upstream flushOnce)
/// and return the resulting lane state:
///
/// - empty delta (nothing new since the cursor) returns `state` unchanged;
/// - create: on a valid create ack the whole transcript counts as
///   acknowledged; on 409 already-exists the lane falls through to append;
/// - append: checkpoint mode adds expected_message_count; a checkpoint
///   conflict retries once with the full transcript (reconcile); a 404
///   thread_not_found recreates the thread via POST /threads;
/// - every terminal path carries the ack predicates' exact error strings;
///   `pending` is cleared because the flush attempt consumed the request.
pub async fn flush_once(
  transport : &NmemTransport,
  request : SyncRequest,
  state : LaneState,
  timeout_ms~ : Int,
) -> LaneState {
  let delta = select_acked_delta(request.messages, state.acknowledged)
  if delta.messages.length() == 0 {
    return state
  }
  let mut created = state.created
  if !created {
    let create_result = nmem_post(
      transport,
      request.config,
      "/threads",
      request.body,
      timeout_ms~,
    )
    let create_remote_count : Int? = if is_thread_create_ack(
        create_result.body,
        request.thread_id,
      ) {
      thread_create_remote_count(create_result.body)
    } else {
      None
    }
    match (create_result.ok, create_remote_count) {
      (true, Some(remote_count)) =>
        return {
          created: true,
          acknowledged: Some({ ..delta.next, remote_count, }),
          last_error: None,
          pending: None,
        }
      _ => ()
    }
    if create_result.ok {
      return {
        created,
        acknowledged: state.acknowledged,
        last_error: Some("thread sync did not receive a create acknowledgement"),
        pending: None,
      }
    }
    if !is_thread_already_exists(create_result.status, create_result.body) {
      return {
        created,
        acknowledged: state.acknowledged,
        last_error: Some(thread_sync_failed_error(create_result)),
        pending: None,
      }
    }
    created = true
  }
  let mut checkpointed = state.acknowledged is Some(_) && !delta.reset
  let expected_remote_count : Int? = if checkpointed {
    match state.acknowledged {
      Some(acked) => Some(acked.remote_count)
      None => None
    }
  } else {
    None
  }
  // Thread ids are normalized to [a-z0-9._-] by thread_id, so no
  // percent-encoding is needed in the append path (upstream encodeURIComponent
  // is a no-op on that alphabet).
  let append_path = "/threads/" + request.thread_id + "/append"
  let delta_key = "\{request.config.source_app}:\{request.session_id}:\{delta.start}-\{delta.stop}:\{delta.next.prefix_fingerprint}"
  let mut result = nmem_post(
    transport,
    request.config,
    append_path,
    append_body(delta.messages, delta_key, expected_remote_count),
    timeout_ms~,
  )
  if !result.ok && checkpointed && is_checkpoint_conflict(result.body) {
    checkpointed = false
    let reconcile_key = "\{request.config.source_app}:\{request.session_id}:reconcile:\{delta.next.prefix_fingerprint}"
    result = nmem_post(
      transport,
      request.config,
      append_path,
      append_body(request.messages, reconcile_key, None),
      timeout_ms~,
    )
  }
  let mut recreated = false
  if !result.ok && created && is_thread_not_found(result.status, result.body) {
    created = false
    result = nmem_post(
      transport,
      request.config,
      "/threads",
      request.body,
      timeout_ms~,
    )
    recreated = true
  }
  if !result.ok {
    return {
      created,
      acknowledged: state.acknowledged,
      last_error: Some(thread_sync_failed_error(result)),
      pending: None,
    }
  }
  let persisted = if recreated {
    is_thread_create_ack(result.body, request.thread_id)
  } else {
    is_thread_append_ack(result.body)
  }
  if !persisted {
    return {
      created,
      acknowledged: state.acknowledged,
      last_error: Some(
        "thread sync did not receive a persistence acknowledgement",
      ),
      pending: None,
    }
  }
  if checkpointed && !recreated && !is_checkpointed_append_ack(result.body) {
    return {
      created,
      acknowledged: state.acknowledged,
      last_error: Some(
        "thread sync did not receive a checkpoint acknowledgement",
      ),
      pending: None,
    }
  }
  let remote_count : Int? = if recreated {
    // The persistence gate above already verified the create ack shape.
    thread_create_remote_count(result.body)
  } else {
    match json_field(result.body, "total_messages") {
      Some(value) => json_int_value(value)
      None => None
    }
  }
  match remote_count {
    Some(count) => {
      created = true
      {
        created,
        acknowledged: Some({ ..delta.next, remote_count: count, }),
        last_error: None,
        pending: None,
      }
    }
    None =>
      {
        created,
        acknowledged: state.acknowledged,
        last_error: Some("thread sync did not receive the remote message count"),
        pending: None,
      }
  }
}

///|
/// Lane map driving the flusher loop (plan D3): one entry per
/// lane_key, mutated only by mark_dirty, drain_once, and the loop itself —
/// single-coroutine access, no locking (risk R7).
pub(all) struct SyncEngine {
  lanes : Map[String, LaneState]
  mut stopped : Bool
}

///|
pub fn SyncEngine::SyncEngine() -> SyncEngine {
  { lanes: Map::from_array([]), stopped: false, }
}

///|
/// Stage `request` as its lane's pending flush, replacing any earlier pending
/// request (only the latest transcript syncs — upstream's timer coalescing).
/// Existing created/acknowledged/error state is preserved.
pub fn SyncEngine::mark_dirty(self : SyncEngine, request : SyncRequest) -> Unit {
  let staged : LaneState = if self.lanes.contains(request.lane_key) {
    { ..self.lanes[request.lane_key], pending: Some(request), }
  } else {
    {
      created: false,
      acknowledged: None,
      last_error: None,
      pending: Some(request),
    }
  }
  self.lanes[request.lane_key] = staged
}

///|
/// Current state of one lane; `None` when the lane has never been dirtied.
pub fn SyncEngine::lane_state(
  self : SyncEngine,
  lane_key : String,
) -> LaneState? {
  if self.lanes.contains(lane_key) {
    Some(self.lanes[lane_key])
  } else {
    None
  }
}

///|
/// Flush every lane with a pending request once, sequentially. The pending
/// request is removed before its flush so a mark_dirty landing while the
/// flush awaits installs a newer request that survives the write-back
/// (upstream's in-flight coalescing loop).
pub async fn SyncEngine::drain_once(
  self : SyncEngine,
  transport : &NmemTransport,
  timeout_ms~ : Int,
) -> Unit {
  let dirty : Array[String] = []
  for lane_key, lane in self.lanes {
    if lane.pending is Some(_) {
      dirty.push(lane_key)
    }
  }
  for lane_key in dirty {
    match self.lanes[lane_key].pending {
      Some(request) => {
        self.lanes[lane_key] = { ..self.lanes[lane_key], pending: None, }
        let result = flush_once(
          transport,
          request,
          self.lanes[lane_key],
          timeout_ms~,
        )
        let staged = self.lanes[lane_key].pending
        self.lanes[lane_key] = { ..result, pending: staged, }
      }
      None => ()
    }
  }
}

///|
/// Long-lived flusher loop (plan D3): drain pending lanes, sleep, repeat
/// until stop() flips `stopped`. Cancellation re-raises so a host task group
/// teardown terminates the loop (a swallowed cancellation here spins the
/// idle loop forever); other sleep errors are swallowed.
pub async fn SyncEngine::flusher_loop(
  self : SyncEngine,
  transport : &NmemTransport,
  interval_ms~ : Int,
  timeout_ms~ : Int,
) -> Unit {
  while !self.stopped {
    self.drain_once(transport, timeout_ms~)
    @async.sleep(interval_ms) catch {
      err if @async.is_cancellation_error(err) => raise err
      _ => ()
    }
  }
}

///|
pub fn SyncEngine::stop(self : SyncEngine) -> Unit {
  self.stopped = true
}
