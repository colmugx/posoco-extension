///|
/// verdict.mbt — pure verdict and budget semantics for the live harness.
///
/// Everything here is a total function over values the harness constructs
/// itself: no I/O, no gateway access, fully covered by white-box tests.
/// The harness main only *feeds* observations in and prints what comes out.

///|
pub(all) enum Verdict {
  VPass
  VFail
  VSkip
  VUnsupported
} derive(Eq, Debug)

///|
pub fn Verdict::label(self : Verdict) -> String {
  match self {
    VPass => "PASS"
    VFail => "FAIL"
    VSkip => "SKIP"
    VUnsupported => "UNSUPPORTED"
  }
}

///|
/// One auditable outcome. `required` checks gate the production verdict;
/// optional checks record capability absence without failing the run.
pub(all) struct CheckOutcome {
  area : String
  capability : String
  verdict : Verdict
  required : Bool
  /// Sanitized, length-capped observation; never keys, bodies, accounts,
  /// session identifiers or raw model output.
  detail : String
} derive(Debug)

///|
pub fn CheckOutcome::row(self : CheckOutcome) -> String {
  let gating = if self.required { "required" } else { "optional" }
  "| \{self.area} | \{self.capability} | \{self.verdict.label()} | \{gating} | \{self.detail} |"
}

///|
/// Hard request budget for billable calls. Both direct HTTP posts and
/// ModelPort-driven executions go through `pay`; unsuccessful attempts are
/// counted by the caller before issuing anything, and once exhausted no
/// further paid request is issued.
pub(all) struct Budget {
  mut spent : Int32
  limit : Int32
} derive(Debug)

///|
pub fn Budget::Budget(limit~ : Int32) -> Budget {
  { spent: 0, limit, }
}

///|
/// Reserves one billable request. Returns `false` — without reserving —
/// once the budget is exhausted.
pub fn Budget::pay(self : Budget) -> Bool {
  if self.spent >= self.limit {
    return false
  }
  self.spent += 1
  true
}

///|
pub fn Budget::remaining(self : Budget) -> Int32 {
  let rest = self.limit - self.spent
  if rest < 0 {
    0
  } else {
    rest
  }
}

///|
pub(all) enum OverallVerdict {
  /// Every check passed.
  AllPassed
  /// Passed, with skipped optional checks recorded as such.
  PassedWithSkips
  /// A required check failed: production gate closed.
  Failed
  /// The gateway was not configured; nothing ran.
  SkippedRun
} derive(Eq, Debug)

///|
pub fn OverallVerdict::label(self : OverallVerdict) -> String {
  match self {
    AllPassed => "PASSED"
    PassedWithSkips => "PASSED (with skips)"
    Failed => "FAILED"
    SkippedRun => "SKIPPED"
  }
}

///|
/// Nonzero process exit is required exactly when a required check failed.
pub fn verdict_requires_failure_exit(outcomes : Array[CheckOutcome]) -> Bool {
  for outcome in outcomes {
    if outcome.required && outcome.verdict is VFail {
      return true
    }
  }
  false
}

///|
/// The overall run verdict. Configuration absence dominates: nothing
/// executed, so the run is SKIPPED — never a pass.
pub fn summarize(
  outcomes : Array[CheckOutcome],
  configured~ : Bool,
) -> OverallVerdict {
  if !configured {
    return SkippedRun
  }
  let mut saw_skip = false
  for outcome in outcomes {
    match outcome.verdict {
      VFail => if outcome.required { return Failed }
      VSkip => {
        if outcome.required {
          // A configured run must not skip required checks; treat that as
          // a broken contract rather than a pass.
          return Failed
        }
        saw_skip = true
      }
      VUnsupported => saw_skip = true
      VPass => ()
    }
  }
  if saw_skip {
    PassedWithSkips
  } else {
    AllPassed
  }
}

///|
fn cap_detail(text : String) -> String {
  if text.length() > 140 {
    text[0:140].to_owned() + "…"
  } else {
    text
  }
}

///|
pub fn CheckOutcome::make(
  area~ : String,
  capability~ : String,
  verdict~ : Verdict,
  required~ : Bool,
  detail~ : String,
) -> CheckOutcome {
  { area, capability, verdict, required, detail: cap_detail(detail), }
}

///|
/// The evidence matrix as Markdown. Source identifies where the evidence
/// came from (e.g. `live-read-only`, `live-inference`); a LIVE inference
/// PASS is only ever recorded by rows whose source says so — offline
/// fixtures can never produce one.
pub fn matrix_markdown(
  outcomes : Array[CheckOutcome],
  gateway_version~ : String,
  source~ : String,
) -> String {
  let out = StringBuilder()
  out.write_string(
    "| Area | Capability | Verdict | Gating | Evidence source | Gateway | Observation |",
  )
  out.write_string("\n|---|---|---|---|---|---|---|\n")
  for outcome in outcomes {
    out.write_string(
      "| \{outcome.area} | \{outcome.capability} | \{outcome.verdict.label()} | \{if outcome.required { "required" } else { "optional" }} | \{source} | \{gateway_version} | \{outcome.detail} |\n",
    )
  }
  out.to_string()
}

///|
/// Turn the harness report lines into matrix rows without re-running
/// anything: `## Section` lines set the area, `- [VERDICT] cap: detail`
/// lines become rows. Pure text in, rows out — fully testable.
pub fn matrix_from_report(
  lines : Array[String],
  gateway_version~ : String,
  source~ : String,
) -> String {
  let rows : Array[String] = []
  let mut area = "general"
  for line in lines {
    if line.has_prefix("## ") {
      area = line[3:].to_owned()
      continue
    }
    guard line.has_prefix("- [") else { continue }
    let end = match line.find("]") {
      Some(index) => index
      None => continue
    }
    let verdict_label = line[3:end].to_owned()
    let rest = line[end + 1:].to_owned()
    let trimmed = rest.trim(chars=" ")
    let capability = match trimmed.find(":") {
      Some(index) => trimmed[0:index].to_owned()
      None => trimmed.to_owned()
    }
    let detail = match trimmed.find(":") {
      Some(index) => trimmed[index + 1:].to_owned().trim(chars=" ").to_owned()
      None => ""
    }
    // Evidence is per section, not per invocation. A read-only PASS
    // must never inherit a "live-inference" label merely because paid
    // probes were enabled elsewhere in the same run.
    let evidence = if area == "Inference (billable)" ||
      area == "Messages cache economics (billable)" ||
      area == "One-hour cache writes" {
      if source == "live-inference+read-only" {
        "live-inference"
      } else {
        "not-executed"
      }
    } else {
      "live-read-only"
    }
    let actual_evidence = if verdict_label == "SKIP" {
      "not-executed"
    } else {
      evidence
    }
    rows.push(
      "| \{area} | \{capability} | \{verdict_label} | \{actual_evidence} | \{gateway_version} | \{detail} |",
    )
  }
  let out = StringBuilder()
  out.write_string(
    "| Area | Capability | Verdict | Evidence source | Gateway | Observation |",
  )
  out.write_string("\n|---|---|---|---|---|---|\n")
  for row in rows {
    out.write_string(row)
    out.write_string("\n")
  }
  out.to_string()
}
