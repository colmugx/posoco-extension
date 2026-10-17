///|
test "context percentage requires actual nonzero capacity" {
  let selection : SelectionRef = {
    owner: "router-a",
    model_id: "opaque-id",
    effort: None,
    pending: false,
    revision: 1L,
  }
  let f : ModelStatusFacts = {
    selection,
    context_used_tokens: Some(25L),
    context_capacity_tokens: Some(100L),
    last_served_model_id: None,
    observed_at_ms: 1L,
  }
  assert_eq(f.context_percent(), Some(25.0))
  assert_eq({ ..f, context_capacity_tokens: None, }.context_percent(), None)
  assert_eq({ ..f, context_capacity_tokens: Some(0L), }.context_percent(), None)
  assert_eq({ ..f, context_used_tokens: Some(-1L), }.context_percent(), None)
}

///|
test "quota windows preserve independent source and time domains" {
  let selection : SelectionRef = {
    owner: "router-a",
    model_id: "single-model",
    effort: None,
    pending: false,
    revision: 0L,
  }
  let five_hour : ModelQuotaWindow = {
    name: "5h",
    remaining_percent: Some(20.0),
    resets_at_ms: Some(1000L),
    unlimited: None,
  }
  let week : ModelQuotaWindow = {
    name: "weekly",
    remaining_percent: Some(90.0),
    resets_at_ms: Some(2000L),
    unlimited: None,
  }
  let snapshot : ModelQuotaSnapshot = {
    selection,
    sources: [
      {
        source_ref: "opaque-A",
        display_label: "Subscription A",
        windows: [five_hour, week],
        eligible: Some(true),
        observed_at_ms: Some(1L),
      },
      {
        source_ref: "opaque-B",
        display_label: "Subscription B",
        windows: [
          { ..five_hour, remaining_percent: Some(80.0), },
          { ..week, remaining_percent: Some(10.0), },
        ],
        eligible: Some(true),
        observed_at_ms: Some(2L),
      },
    ],
    observed_at_ms: 2L,
  }
  assert_eq(snapshot.sources.length(), 2)
  assert_eq(snapshot.sources[0].windows[0].remaining_percent, Some(20.0))
  assert_eq(snapshot.sources[1].windows[0].remaining_percent, Some(80.0))
  assert_eq(snapshot.sources[0].windows[1].resets_at_ms, Some(2000L))
}

///|
test "recovery deadline stays absent for unknown and backoff" {
  assert_eq(ModelRecoveryAdvice::WaitUntil(42L).deadline(), Some(42L))
  assert_eq(ModelRecoveryAdvice::WaitUntil(0L).deadline(), None)
  assert_eq(ModelRecoveryAdvice::ProbeWithBackoff.deadline(), None)
  assert_eq(ModelRecoveryAdvice::Unknown.deadline(), None)
}
