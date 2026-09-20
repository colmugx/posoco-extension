///|
test "cache reporting distinguishes unknown from explicit zero" {
  let stats = Stats(clock=fn() { 0L })
  stats.on_event_at(
    Some(tk_scope("s")),
    tk_response(Some(tk_usage_cache(Some(100), None))),
  )
  stats.on_event_at(
    Some(tk_scope("s")),
    tk_response(Some(tk_usage_cache(Some(200), Some(0)))),
  )
  stats.on_event_at(
    Some(tk_scope("s")),
    tk_response(Some(tk_usage_cache(Some(300), Some(120)))),
  )
  match stats.cache_buckets.get("s") {
    Some(bucket) => {
      assert_eq(bucket.requests, 3)
      assert_eq(bucket.cache_reported_requests, 2)
      assert_eq(bucket.hit_requests, 1)
      assert_eq(bucket.sum_input, 600)
      assert_eq(bucket.sum_cache_input, 500)
      assert_eq(bucket.sum_cached, 120)
    }
    None => fail("expected cache bucket")
  }
}

///|
async test "cache doctor never diagnoses unreported telemetry as misses" {
  let stats = Stats()
  for _i in 0..<5 {
    stats.on_event_at(
      Some(tk_scope("s")),
      tk_response(Some(tk_usage_cache(Some(100), None))),
    )
  }
  match stats.invoke("cache_doctor", Json::null()) {
    @posoco.CommandOutcome::Success(feedback~, structured~, ..) => {
      assert_true(feedback.contains("cache metrics not reported"))
      assert_true(feedback.contains("5 usage requests"))
      assert_false(feedback.contains("warning"))
      match structured {
        Some(Json::Object(fields)) => {
          match fields.get("aggregate") {
            Some(Json::Object(aggregate)) => {
              match aggregate.get("cache_reported_requests") {
                Some(Json::Number(n, ..)) => assert_eq(n, 0.0)
                _ => fail("expected cache_reported_requests")
              }
              match aggregate.get("sum_cache_input_tokens") {
                Some(Json::Number(n, ..)) => assert_eq(n, 0.0)
                _ => fail("expected sum_cache_input_tokens")
              }
            }
            _ => fail("expected aggregate object")
          }
          match fields.get("diagnosis") {
            Some(_) =>
              fail("unreported cache telemetry must not diagnose misses")
            None => ()
          }
        }
        _ => fail("expected structured object")
      }
    }
    _ => fail("expected success outcome")
  }
}

///|
async test "cache doctor token ratio uses only cache-reporting input" {
  let stats = Stats()
  stats.on_event_at(
    Some(tk_scope("s")),
    tk_response(Some(tk_usage_cache(Some(100), Some(50)))),
  )
  // A large usage round with no cache telemetry must not dilute the 50/100
  // reported cache-token ratio or its request denominator.
  stats.on_event_at(
    Some(tk_scope("s")),
    tk_response(Some(tk_usage_cache(Some(900), None))),
  )
  match stats.invoke("cache_doctor", Json::null()) {
    @posoco.CommandOutcome::Success(feedback~, ..) => {
      assert_true(
        feedback.contains("session s: 1/1 requests·50/100 tok·50.0%"),
      )
      assert_true(
        feedback.contains("aggregate: 1/1 requests·50/100 tok·50.0%"),
      )
    }
    _ => fail("expected success outcome")
  }
}
