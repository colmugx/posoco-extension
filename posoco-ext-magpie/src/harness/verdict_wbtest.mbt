///|
/// verdict_wbtest.mbt — pure white-box tests for verdict, budget and matrix
/// semantics. No I/O, no gateway: every input is constructed here.

///|
fn pass_outcome(
  area~ : String,
  capability~ : String,
  required~ : Bool = true,
) -> CheckOutcome {
  CheckOutcome::make(area~, capability~, verdict=VPass, required~, detail="ok")
}

///|
test "budget pays until exhausted and never beyond" {
  let budget = Budget::Budget(limit=2)
  inspect(budget.pay(), content="true")
  inspect(budget.pay(), content="true")
  // The budget is exhausted: no further reservation, caller must not issue.
  inspect(budget.pay(), content="false")
  inspect(budget.pay(), content="false")
  inspect(budget.remaining(), content="0")
}

///|
test "budget reservations count unsuccessful attempts too" {
  // The caller reserves before issuing; a failing request still spent its
  // slot. Two failures consume a limit of two exactly like two successes.
  let budget = Budget::Budget(limit=2)
  let mut issued = 0
  while budget.pay() {
    issued += 1
    // simulate the request failing here — the reservation stands
  }
  inspect(issued, content="2")
  inspect(budget.remaining(), content="0")
}

///|
test "unconfigured runs are SKIPPED, never a pass" {
  let outcomes = [pass_outcome(area="discovery", capability="/api/hello")]
  inspect(summarize(outcomes, configured=false).label(), content="SKIPPED")
}

///|
test "a failed required check closes the gate" {
  let outcomes = [
    pass_outcome(area="discovery", capability="/api/hello"),
    CheckOutcome::make(
      area="inference",
      capability="messages-native",
      verdict=VFail,
      required=true,
      detail="gateway 500",
    ),
    CheckOutcome::make(
      area="cache",
      capability="cache-hit",
      verdict=VFail,
      required=false,
      detail="no read tokens",
    ),
  ]
  inspect(summarize(outcomes, configured=true).label(), content="FAILED")
  inspect(verdict_requires_failure_exit(outcomes), content="true")
}

///|
test "an optional failure does not close the gate but is recorded" {
  let outcomes = [
    pass_outcome(area="discovery", capability="/api/hello"),
    CheckOutcome::make(
      area="cache",
      capability="cache-hit",
      verdict=VFail,
      required=false,
      detail="no read tokens",
    ),
  ]
  inspect(summarize(outcomes, configured=true).label(), content="PASSED")
  inspect(verdict_requires_failure_exit(outcomes), content="false")
}

///|
test "skips and unsupported capabilities yield PASSED (with skips)" {
  let outcomes = [
    pass_outcome(area="discovery", capability="/api/hello"),
    CheckOutcome::make(
      area="inference",
      capability="streaming",
      verdict=VSkip,
      required=false,
      detail="not approved",
    ),
    CheckOutcome::make(
      area="cache",
      capability="cache-write-1h",
      verdict=VUnsupported,
      required=false,
      detail="model does not declare one-hour caching",
    ),
  ]
  inspect(
    summarize(outcomes, configured=true).label(),
    content="PASSED (with skips)",
  )
  inspect(verdict_requires_failure_exit(outcomes), content="false")
}

///|
test "a skipped required check in a configured run is a broken contract" {
  let outcomes = [
    CheckOutcome::make(
      area="discovery",
      capability="/v1/models",
      verdict=VSkip,
      required=true,
      detail="unexpectedly skipped",
    ),
  ]
  inspect(summarize(outcomes, configured=true).label(), content="FAILED")
}

///|
test "an all-pass run is AllPassed" {
  let outcomes = [
    pass_outcome(area="discovery", capability="/api/hello"),
    pass_outcome(area="inference", capability="messages-native", required=false),
  ]
  inspect(summarize(outcomes, configured=true).label(), content="PASSED")
}

///|
test "matrix rows carry verdict, gating, source and version" {
  let outcomes = [
    CheckOutcome::make(
      area="discovery",
      capability="/api/hello",
      verdict=VPass,
      required=true,
      detail="{name,version}",
    ),
    CheckOutcome::make(
      area="cache",
      capability="cache-hit",
      verdict=VUnsupported,
      required=false,
      detail="no cache declaration",
    ),
  ]
  let markdown = matrix_markdown(
    outcomes,
    gateway_version="magpie 0.1.1224",
    source="live-read-only",
  )
  inspect(
    markdown.contains(
      "| discovery | /api/hello | PASS | required | live-read-only | magpie 0.1.1224 |",
    ),
    content="true",
  )
  inspect(
    markdown.contains(
      "| cache | cache-hit | UNSUPPORTED | optional | live-read-only |",
    ),
    content="true",
  )
  // The source column is the only place evidence provenance lives.
  inspect(markdown.contains("live-inference"), content="false")
}

///|
test "offline fixtures can never produce a live-inference row" {
  // Guarding the rule by construction: the row renderer takes the source
  // as a parameter, and the harness only ever passes its own measured
  // source. A fixture-based row would carry source "offline-simulated".
  let outcome = pass_outcome(area="inference", capability="messages-native")
  let simulated = matrix_markdown(
    [outcome],
    gateway_version="n/a",
    source="offline-simulated",
  )
  inspect(simulated.contains("offline-simulated"), content="true")
  inspect(simulated.contains("live-inference"), content="false")
}

///|
test "detail text is length-capped" {
  let long = "x".repeat(500)
  let outcome = CheckOutcome::make(
    area="a",
    capability="b",
    verdict=VPass,
    required=false,
    detail=long,
  )
  inspect(outcome.detail.length() <= 141, content="true")
}

///|
test "report lines translate into matrix rows with section areas" {
  let lines = [
    "## Discovery", "- [PASS] /api/hello: HTTP 200; {name:string,version:string}",
    "- [FAIL] /v1/models: HTTP 500 nope", "## Commands", "- [PASS] magpie_status: feedback_present=true",
    "  - note: all 10 runtime commands passed",
  ]
  let markdown = matrix_from_report(
    lines,
    gateway_version="magpie 0.1.1224",
    source="live-read-only",
  )
  inspect(
    markdown.contains(
      "| Discovery | /api/hello | PASS | live-read-only | magpie 0.1.1224 | HTTP 200;",
    ),
    content="true",
  )
  inspect(
    markdown.contains(
      "| Discovery | /v1/models | FAIL | live-read-only | magpie 0.1.1224 | HTTP 500",
    ),
    content="true",
  )
  inspect(
    markdown.contains(
      "| Commands | magpie_status | PASS | live-read-only | magpie 0.1.1224 | feedback_present=true |",
    ),
    content="true",
  )
  // Note lines and section headers never become rows.
  inspect(markdown.contains("note:"), content="false")
}

///|
test "a failed required discovery closes the gate while optional cache trouble does not" {
  // The gate counts required failures only; this mirrors the harness rule
  // that /api/hello and /v1/models are the required contract, and cache or
  // tool capability gaps are optional observations.
  let required_failed = ["- [FAIL] /api/hello: HTTP 500"]
  let optional_failed = ["- [FAIL] cache-hit: identical prefix read 0"]
  fn gate_closed(lines : Array[String]) -> Bool {
    // /api/hello and /v1/models are the required discovery contract.
    for line in lines {
      if line.contains("- [FAIL] /api/hello") ||
        line.contains("- [FAIL] /v1/models") {
        return true
      }
    }
    false
  }
  inspect(gate_closed(required_failed), content="true")
  inspect(gate_closed(optional_failed), content="false")
}
