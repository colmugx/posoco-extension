///|
/// White-box tests for `/model <provider> pick`: v2 calibration under the
/// priority gradient 分数 > tokens 效率比 > 金钱 > 时间, the luna
/// token-efficiency anchor, 4-dimension dominance, sample and dimension
/// guards, eligibility filtering, and the failure/intercept contract. The
/// fake metrics source registers under the router's real provider id
/// "provider-a" (never "openai", to avoid registry collisions with other
/// packages' tests) and unregisters in every test. Fixture numbers are
/// frozen: R1's IQ/cost anchors plus tokens/minutes scaled from the
/// 2026-09-10 live calibration table.

///|
/// Fixed-point metrics source for pick tests: replays one canned result and
/// counts reads so tests can prove whether the pick intercept fired.
struct PickMetricsSource {
  result : Result[Array[@devkit.MetricsPoint], String]
  mut reads : Int
}

///|
impl @devkit.ModelMetricsSource for PickMetricsSource with fn read(
  self : PickMetricsSource,
) -> Result[Array[@devkit.MetricsPoint], String] {
  self.reads = self.reads + 1
  self.result
}

///|
/// A metrics point where every run solved its problem (passed = total) and
/// the source stated both the token total and the run duration.
fn pick_point(
  model : String,
  effort : String,
  iq : Double,
  cost : Double,
  total : Int,
  tokens : Double?,
  minutes : Double?,
) -> @devkit.MetricsPoint {
  { model, effort, iq, cost_usd: cost, passed: total, total, tokens, minutes, }
}

///|
/// A metrics point with an explicit pass ratio: the token total is the
/// source's average per run, so failed attempts amortize into the tokens
/// charged per solved problem.
fn pick_attempt_point(
  model : String,
  effort : String,
  iq : Double,
  cost : Double,
  passed : Int,
  total : Int,
  tokens : Double?,
  minutes : Double?,
) -> @devkit.MetricsPoint {
  { model, effort, iq, cost_usd: cost, passed, total, tokens, minutes, }
}

///|
/// One effort-capable slot: real advertised efforts plus a working rebuild
/// hook, so a pick winner goes through select_effort. Built locally because
/// command_test_router's slots advertise no efforts.
fn pick_effort_slot(
  id : String,
  provider_id : String,
  model_id : String,
) -> ModelSlot {
  let port : &@posoco.ModelPort = RouterTestPort::{
    reasoning_effort_values: [],
  }
  let base = ModelSlot::ModelSlot(id~, label=id, provider_id~, model_id~, port~)
  {
    ..base,
    thinking_efforts: ["low", "medium", "high", "xhigh"],
    default_effort: Some("low"),
    rebuild_on_effort: Some(_ => base),
  }
}

///|
/// Single provider-a slot on model-a.
fn pick_test_router() -> RouterModelPort raise @posoco.CompositionError {
  RouterModelPort(slots=[pick_effort_slot("astra", "provider-a", "model-a")])
}

///|
/// The R1 calibration example upgraded to the v2 formula: R1's frozen IQ
/// and cost with tokens/minutes scaled from the gpt-6-astra anchor (9.0
/// minutes, ~1.5M tokens per run). Medium must win on score (110.26 over
/// low's 105.655); high is strictly dominated by medium on all four
/// dimensions; low loses on score only.
fn pick_calibration_points() -> Array[@devkit.MetricsPoint] {
  [
    pick_point("model-a", "low", 110.0, 1.20, 100, Some(1500000.0), Some(8.9)),
    pick_point(
      "model-a",
      "medium",
      117.0,
      2.37,
      127,
      Some(1550000.0),
      Some(9.0),
    ),
    pick_point("model-a", "high", 115.0, 4.00, 91, Some(1700000.0), Some(10.5)),
  ]
}

///|
/// The exact `{slot, effort}` object the TS host sends for
/// `/model <provider> pick`.
fn pick_args(provider_id : String) -> Json {
  Json::object(
    Map::from_array([
      ("slot", Json::string(provider_id)),
      ("effort", Json::string(pick_keyword)),
    ]),
  )
}

///|
fn pick_assert_string(
  fields : Map[String, Json],
  key : String,
  expected : String,
) -> Unit raise {
  match fields.get(key) {
    Some(Json::String(value)) => assert_eq(value, expected)
    _ => fail("expected string field " + key)
  }
}

///|
fn pick_assert_number(
  fields : Map[String, Json],
  key : String,
  expected : Double,
) -> Unit raise {
  match fields.get(key) {
    Some(Json::Number(value, ..)) => assert_eq(value, expected)
    _ => fail("expected number field " + key)
  }
}

///|
/// Fields of the `picked` object in a pick structured payload.
fn pick_picked_fields(structured : Json?) -> Map[String, Json] raise {
  match structured {
    Some(Json::Object(fields)) =>
      match fields.get("picked") {
        Some(Json::Object(picked)) => picked
        _ => fail("expected picked object in pick payload")
      }
    _ => fail("expected structured pick payload")
  }
}

///|
/// Fields of the candidate at `index` in a pick structured payload.
fn pick_candidate_fields(
  structured : Json?,
  index : Int,
) -> Map[String, Json] raise {
  match structured {
    Some(Json::Object(fields)) =>
      match fields.get("candidates") {
        Some(Json::Array(entries)) =>
          if index < entries.length() {
            match entries[index] {
              Json::Object(candidate) => candidate
              _ => fail("expected candidate object")
            }
          } else {
            fail("expected a candidate at index " + index.to_string())
          }
        _ => fail("expected candidates array in pick payload")
      }
    _ => fail("expected structured pick payload")
  }
}

///|
fn pick_candidates_length(structured : Json?) -> Int raise {
  match structured {
    Some(Json::Object(fields)) =>
      match fields.get("candidates") {
        Some(Json::Array(entries)) => entries.length()
        _ => fail("expected candidates array in pick payload")
      }
    _ => fail("expected structured pick payload")
  }
}

///|
async test "pick calibration picks medium with the exact wire payload" {
  let router = pick_test_router()
  @devkit.metrics_registry_register("provider-a", PickMetricsSource::{
    result: Ok(pick_calibration_points()),
    reads: 0,
  })
  let outcome = router.invoke("model", pick_args("provider-a"))
  @devkit.metrics_registry_unregister("provider-a")
  match outcome {
    @posoco.CommandOutcome::Success(feedback~, structured~, ui_hint~) => {
      assert_eq(feedback, "auto-picked model slot: astra (medium)")
      assert_true(ui_hint is Some(@posoco.UiHint::RefreshModelList))
      match structured {
        Some(Json::Object(fields)) =>
          pick_assert_string(fields, "provider", "provider-a")
        _ => fail("expected structured pick payload")
      }
      // Scores: medium 117 - 1.55 - 4.74 - 0.45 = 110.26 beats low
      // 110 - 1.5 - 2.4 - 0.445 = 105.655; high is dominated by medium on
      // all four dimensions (higher IQ, cheaper, fewer tokens, fewer
      // minutes), so it never becomes a candidate.
      let picked = pick_picked_fields(structured)
      pick_assert_string(picked, "slot_id", "astra")
      pick_assert_string(picked, "model", "model-a")
      pick_assert_string(picked, "effort", "medium")
      pick_assert_number(picked, "iq", 117.0)
      pick_assert_number(picked, "cost_usd", 2.37)
      assert_eq(pick_candidates_length(structured), 1)
      let candidate = pick_candidate_fields(structured, 0)
      pick_assert_string(candidate, "slot_id", "astra")
      pick_assert_string(candidate, "model", "model-a")
      pick_assert_string(candidate, "effort", "low")
      pick_assert_number(candidate, "iq", 110.0)
      pick_assert_number(candidate, "cost_usd", 1.20)
    }
    _ => fail("expected successful pick")
  }
  assert_eq(router.active_slot_id(), "astra")
}

///|
/// The round's motivating anchor: the cheap-verbose model's ~26.34M
/// amortized tokens per solved problem (26-point token penalty) dwarfs the
/// ~3.4 points its $3.4-lower price saves, so the expensive-efficient model
/// wins despite costing four times as much.
async test "pick luna anchor: expensive-efficient beats cheap-verbose" {
  let router = RouterModelPort(slots=[
    pick_effort_slot("astra", "provider-a", "model-a"),
    pick_effort_slot("luna", "provider-a", "model-b"),
  ])
  let points = [
    pick_attempt_point(
      "model-a",
      "medium",
      107.81,
      2.26,
      92,
      128,
      Some(1097281.0),
      Some(9.0),
    ),
    pick_attempt_point(
      "model-b",
      "low",
      102.23,
      0.54,
      229,
      336,
      Some(17950000.0),
      Some(37.1),
    ),
  ]
  // The amortization is what prices in failed attempts: 1097281 tokens per
  // run over 128 total / 92 passed attempts per success.
  match pick_tokens_per_pass(points[0]) {
    Some(tpp) => assert_eq(tpp, 1097281.0 * 128.0 / 92.0)
    None => fail("expected amortized tokens for model-a")
  }
  @devkit.metrics_registry_register("provider-a", PickMetricsSource::{
    result: Ok(points),
    reads: 0,
  })
  let outcome = router.invoke("model", pick_args("provider-a"))
  @devkit.metrics_registry_unregister("provider-a")
  match outcome {
    @posoco.CommandOutcome::Success(feedback~, structured~, ..) => {
      assert_eq(feedback, "auto-picked model slot: astra (medium)")
      assert_eq(pick_candidates_length(structured), 1)
      let candidate = pick_candidate_fields(structured, 0)
      pick_assert_string(candidate, "slot_id", "luna")
      pick_assert_string(candidate, "model", "model-b")
      pick_assert_string(candidate, "effort", "low")
      pick_assert_number(candidate, "iq", 102.23)
      pick_assert_number(candidate, "cost_usd", 0.54)
    }
    _ => fail("expected successful pick")
  }
  assert_eq(router.active_slot_id(), "astra")
  assert_eq(router.active_effort(), Some("medium"))
}

///|
async test "pick candidates are the next non-dominated ranks" {
  let router = pick_test_router()
  @devkit.metrics_registry_register("provider-a", PickMetricsSource::{
    result: Ok([
      pick_point(
        "model-a",
        "medium",
        117.0,
        2.37,
        127,
        Some(1550000.0),
        Some(9.0),
      ),
      pick_point("model-a", "low", 105.0, 0.50, 200, Some(1500000.0), Some(8.9)),
      pick_point(
        "model-a",
        "high",
        115.0,
        4.00,
        91,
        Some(1700000.0),
        Some(10.5),
      ),
      pick_point(
        "model-a",
        "xhigh",
        125.0,
        6.00,
        60,
        Some(2600000.0),
        Some(20.0),
      ),
    ]),
    reads: 0,
  })
  let outcome = router.invoke("model", pick_args("provider-a"))
  @devkit.metrics_registry_unregister("provider-a")
  match outcome {
    @posoco.CommandOutcome::Success(feedback~, structured~, ..) => {
      assert_eq(feedback, "auto-picked model slot: astra (medium)")
      // Dominance drops high before ranking (medium beats it on all four
      // dimensions), so ranks 2-3 of the filtered pool are xhigh
      // (125 - 2.6 - 12.0 - 1.0 = 109.4) then low (102.055) and high never
      // appears.
      assert_eq(pick_candidates_length(structured), 2)
      let first = pick_candidate_fields(structured, 0)
      pick_assert_string(first, "effort", "xhigh")
      pick_assert_number(first, "iq", 125.0)
      pick_assert_number(first, "cost_usd", 6.00)
      let second = pick_candidate_fields(structured, 1)
      pick_assert_string(second, "effort", "low")
      pick_assert_number(second, "iq", 105.0)
      pick_assert_number(second, "cost_usd", 0.50)
    }
    _ => fail("expected successful pick")
  }
}

///|
async test "pick skips points below the sample guard" {
  let router = pick_test_router()
  @devkit.metrics_registry_register("provider-a", PickMetricsSource::{
    result: Ok([
      pick_point("model-a", "low", 110.0, 1.20, 28, Some(1500000.0), Some(8.9)),
      pick_point(
        "model-a",
        "medium",
        117.0,
        2.37,
        127,
        Some(1550000.0),
        Some(9.0),
      ),
    ]),
    reads: 0,
  })
  let outcome = router.invoke("model", pick_args("provider-a"))
  @devkit.metrics_registry_unregister("provider-a")
  match outcome {
    @posoco.CommandOutcome::Success(structured~, ..) =>
      // The 28-run point never enters the pool, not even as a candidate.
      assert_eq(pick_candidates_length(structured), 0)
    _ => fail("expected successful pick")
  }
}

///|
/// A point missing any scored dimension — the token total, the run
/// duration, or a positive pass count — is skipped, never zero-filled or
/// estimated. Each skipped point here would have won outright (130 IQ at
/// $0.10) had it been eligible.
async test "pick skips points missing a scored dimension" {
  let router = pick_test_router()
  @devkit.metrics_registry_register("provider-a", PickMetricsSource::{
    result: Ok([
      pick_point("model-a", "low", 130.0, 0.10, 100, None, Some(8.9)),
      pick_point("model-a", "high", 130.0, 0.10, 100, Some(1200000.0), None),
      pick_attempt_point(
        "model-a",
        "xhigh",
        130.0,
        0.10,
        0,
        100,
        Some(1200000.0),
        Some(8.9),
      ),
      pick_point(
        "model-a",
        "medium",
        117.0,
        2.37,
        127,
        Some(1550000.0),
        Some(9.0),
      ),
    ]),
    reads: 0,
  })
  let outcome = router.invoke("model", pick_args("provider-a"))
  @devkit.metrics_registry_unregister("provider-a")
  match outcome {
    @posoco.CommandOutcome::Success(feedback~, structured~, ..) => {
      assert_eq(feedback, "auto-picked model slot: astra (medium)")
      assert_eq(pick_candidates_length(structured), 0)
    }
    _ => fail("expected successful pick")
  }
}

///|
async test "pick skips efforts the slot does not advertise" {
  let router = pick_test_router()
  @devkit.metrics_registry_register("provider-a", PickMetricsSource::{
    result: Ok([
      pick_point("model-a", "max", 130.0, 0.10, 100, Some(1200000.0), Some(8.5)),
      pick_point(
        "model-a",
        "medium",
        117.0,
        2.37,
        127,
        Some(1550000.0),
        Some(9.0),
      ),
    ]),
    reads: 0,
  })
  let outcome = router.invoke("model", pick_args("provider-a"))
  @devkit.metrics_registry_unregister("provider-a")
  match outcome {
    @posoco.CommandOutcome::Success(feedback~, structured~, ..) => {
      // "max" is not advertised; had it been eligible it would have won.
      assert_eq(feedback, "auto-picked model slot: astra (medium)")
      assert_eq(pick_candidates_length(structured), 0)
    }
    _ => fail("expected successful pick")
  }
}

///|
async test "pick skips models without a matching slot" {
  let router = pick_test_router()
  @devkit.metrics_registry_register("provider-a", PickMetricsSource::{
    result: Ok([
      pick_point(
        "model-zzz",
        "low",
        130.0,
        0.10,
        100,
        Some(1200000.0),
        Some(8.5),
      ),
      pick_point(
        "model-a",
        "medium",
        117.0,
        2.37,
        127,
        Some(1550000.0),
        Some(9.0),
      ),
    ]),
    reads: 0,
  })
  let outcome = router.invoke("model", pick_args("provider-a"))
  @devkit.metrics_registry_unregister("provider-a")
  match outcome {
    @posoco.CommandOutcome::Success(feedback~, structured~, ..) => {
      assert_eq(feedback, "auto-picked model slot: astra (medium)")
      assert_eq(pick_candidates_length(structured), 0)
    }
    _ => fail("expected successful pick")
  }
}

///|
async test "pick fails on an empty eligible pool" {
  let router = pick_test_router()
  @devkit.metrics_registry_register("provider-a", PickMetricsSource::{
    result: Ok([
      pick_point("model-a", "max", 117.0, 2.37, 127, Some(1550000.0), Some(9.0)),
    ]),
    reads: 0,
  })
  let outcome = router.invoke("model", pick_args("provider-a"))
  @devkit.metrics_registry_unregister("provider-a")
  match outcome {
    @posoco.CommandOutcome::Failure(reason~) =>
      // Caught command errors carry the debug rendering as the reason.
      assert_true(reason.contains("no eligible provider-a models in metrics"))
    _ => fail("expected the empty-pool failure")
  }
  // A failed pick never touched the selection.
  assert_eq(router.active_slot_id(), "astra")
  assert_eq(router.active_effort(), None)
}

///|
async test "pick surfaces a failed metrics read" {
  let router = pick_test_router()
  @devkit.metrics_registry_register("provider-a", PickMetricsSource::{
    result: Err("radar down"),
    reads: 0,
  })
  let outcome = router.invoke("model", pick_args("provider-a"))
  @devkit.metrics_registry_unregister("provider-a")
  match outcome {
    @posoco.CommandOutcome::Failure(reason~) =>
      assert_true(reason.contains("metrics unavailable: radar down"))
    _ => fail("expected the metrics-unavailable failure")
  }
}

///|
async test "pick without a registered source fails" {
  let router = pick_test_router()
  @devkit.metrics_registry_unregister("provider-a")
  let outcome = router.invoke("model", pick_args("provider-a"))
  match outcome {
    @posoco.CommandOutcome::Failure(reason~) =>
      assert_eq(
        reason, "no metrics source registered for provider 'provider-a'",
      )
    _ => fail("expected the missing-source failure")
  }
}

///|
async test "a real slot named like the provider wins over the pick intercept" {
  let router = RouterModelPort(slots=[
    pick_effort_slot("provider-a", "provider-a", "model-a"),
  ])
  let source : PickMetricsSource = {
    result: Ok(pick_calibration_points()),
    reads: 0,
  }
  @devkit.metrics_registry_register("provider-a", source)
  let outcome = router.invoke("model", pick_args("provider-a"))
  @devkit.metrics_registry_unregister("provider-a")
  match outcome {
    @posoco.CommandOutcome::Failure(reason~) =>
      assert_true(
        reason.contains("unsupported effort 'pick' for model slot provider-a"),
      )
    _ => fail("expected the normal unsupported-effort failure")
  }
  // The intercept never consulted the metrics source.
  assert_eq(source.reads, 0)
  assert_eq(router.active_effort(), None)
}

///|
async test "pick switches the active slot and effort" {
  let router = RouterModelPort(slots=[
    pick_effort_slot("plain", "provider-b", "model-b"),
    pick_effort_slot("astra", "provider-a", "model-a"),
  ])
  @devkit.metrics_registry_register("provider-a", PickMetricsSource::{
    result: Ok(pick_calibration_points()),
    reads: 0,
  })
  let outcome = router.invoke("model", pick_args("provider-a"))
  @devkit.metrics_registry_unregister("provider-a")
  assert_true(outcome is @posoco.CommandOutcome::Success(..))
  assert_eq(router.active_slot_id(), "astra")
  assert_eq(router.active_effort(), Some("medium"))
}

///|
async test "the host {slot, effort} wire shape reaches the pick flow" {
  let router = pick_test_router()
  let source : PickMetricsSource = {
    result: Ok(pick_calibration_points()),
    reads: 0,
  }
  @devkit.metrics_registry_register("provider-a", source)
  let outcome = router.invoke(
    "model",
    Json::object(
      Map::from_array([
        ("slot", Json::string("provider-a")),
        ("effort", Json::string("pick")),
      ]),
    ),
  )
  @devkit.metrics_registry_unregister("provider-a")
  match outcome {
    @posoco.CommandOutcome::Success(feedback~, structured~, ..) => {
      assert_eq(feedback, "auto-picked model slot: astra (medium)")
      match structured {
        Some(Json::Object(fields)) =>
          pick_assert_string(fields, "provider", "provider-a")
        _ => fail("expected structured pick payload")
      }
    }
    _ => fail("expected successful pick")
  }
  assert_eq(source.reads, 1)
}
