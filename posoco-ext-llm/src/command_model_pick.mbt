///|
/// `/model <provider> pick` support.
///
/// When the `/model` slot argument is not a real slot but the effort keyword
/// `pick`, the slot argument names a provider: the command reads that
/// provider's registered `ModelMetricsSource`, scores the eligible
/// slot/effort pairs on the four scored dimensions (IQ, token efficiency,
/// cost, duration) under the priority gradient 分数(IQ) > tokens 效率比 >
/// 金钱 > 时间, and auto-switches to the winner. Metrics are vendor-stated
/// facts; every failure raises instead of estimating.

///|
/// Reserved `/model` effort keyword that turns a provider id into a pick
/// command; only consulted when the id is not a real slot.
let pick_keyword : String = "pick"

///|
/// Score points charged per 1M amortized tokens per solved problem (unit:
/// points per million tokens; the tokens 效率比 dimension). The three
/// penalty weights below encode the priority gradient 分数(IQ) > tokens >
/// 金钱 > 时间: over the live GPT pool the per-dimension contribution spread
/// orders tokens (~25 points) above money (~15 points) above time (~1.4
/// points), all below the meaningful IQ spread's decisiveness.
///
/// Worked calibration (2026-09-10 live anchor gpt-6-astra:medium: 107.81 IQ
/// @ $2.26, 9.0 minutes, 1.53M amortized tokens per solved problem):
/// `107.81 - 1.0 * 1.53 - 2.0 * 2.26 - 0.5 * 0.9 = 101.31`, the winner.
/// gpt-5.6-luna:max (102.23 IQ but 26.34M amortized tokens per solved
/// problem) falls to 72.96: its 26-point token penalty dwarfs the ~3.4
/// points its cheaper price saves.
let pick_token_penalty_per_m : Double = 1.0

///|
/// Score points charged per US dollar of average run cost (unit: points per
/// dollar; the 金钱 dimension, below tokens in the gradient).
let pick_cost_penalty_per_usd : Double = 2.0

///|
/// Score points charged per 10 minutes of average run duration (unit:
/// points per 10 minutes; the 时间 dimension, last in the gradient).
let pick_time_penalty_per_10min : Double = 0.5

///|
/// Minimum benchmark sample count a metrics point must carry; tiny samples
/// must not win on noise.
let pick_min_total : Int = 30

///|
/// The slice of slot metadata pick eligibility needs: which provider owns
/// the slot, which model id metrics points must name, and which efforts the
/// slot advertises.
priv struct PickSlotFacts {
  slot_id : String
  provider_id : String
  model_id : String
  thinking_efforts : Array[String]
}

///|
/// One scored metrics point together with the slot it landed on.
priv struct PickCandidate {
  point : @devkit.MetricsPoint
  slot_id : String
}

///|
/// Amortized tokens per solved problem: the source's average total tokens
/// per run scaled by `total / passed`. Failed runs burn tokens too, so this
/// is the honest "tokens to complete one task": a model that fails often
/// pays for every attempt until one succeeds. `None` when the source stated
/// no token total or when no run solved a problem — such points are
/// ineligible, never zero-filled or estimated.
fn pick_tokens_per_pass(point : @devkit.MetricsPoint) -> Double? {
  match point.tokens {
    Some(tokens) =>
      if point.passed > 0 {
        Some(tokens * point.total.to_double() / point.passed.to_double())
      } else {
        None
      }
    None => None
  }
}

///|
/// Eligible pool for one provider: metrics points whose model names one of
/// the provider's slot models, whose effort that slot advertises, whose
/// benchmark sample clears the noise guard, and that state every scored
/// dimension — the token total (amortizable over a positive pass count) and
/// the run duration. A point missing a scored dimension is skipped, never
/// zero-filled or estimated. Slots sharing provider and model deduplicate
/// (first in slot order wins).
fn pick_eligible_pool(
  provider_id : String,
  points : Array[@devkit.MetricsPoint],
  slots : Array[PickSlotFacts],
) -> Array[PickCandidate] {
  let pool : Array[PickCandidate] = []
  let claimed : Map[String, Unit] = Map::from_array([])
  for slot in slots {
    if slot.provider_id != provider_id || claimed.contains(slot.model_id) {
      continue
    }
    claimed[slot.model_id] = ()
    for point in points {
      if point.model == slot.model_id &&
        slot.thinking_efforts.contains(point.effort) &&
        point.total >= pick_min_total &&
        pick_tokens_per_pass(point) is Some(_) &&
        point.minutes is Some(_) &&
        point.passed > 0 {
        pool.push({ point, slot_id: slot.slot_id, })
      }
    }
  }
  pool
}

///|
/// Drop every point another eligible point dominates on the four scored
/// dimensions: Q dominates P when Q's IQ is >=, cost <=, tokens per solved
/// problem <=, and minutes <=, with at least one comparison strict. Such
/// points leave the pool before ranking, so they can never win nor become
/// candidates.
fn pick_dominance_filter(pool : Array[PickCandidate]) -> Array[PickCandidate] {
  let kept : Array[PickCandidate] = []
  for entry in pool {
    let mut dominated = false
    match (pick_tokens_per_pass(entry.point), entry.point.minutes) {
      (Some(entry_tpp), Some(entry_minutes)) =>
        for other in pool {
          match (pick_tokens_per_pass(other.point), other.point.minutes) {
            (Some(other_tpp), Some(other_minutes)) =>
              if other.point.iq >= entry.point.iq &&
                other.point.cost_usd <= entry.point.cost_usd &&
                other_tpp <= entry_tpp &&
                other_minutes <= entry_minutes &&
                (
                  other.point.iq > entry.point.iq ||
                  other.point.cost_usd < entry.point.cost_usd ||
                  other_tpp < entry_tpp ||
                  other_minutes < entry_minutes
                ) {
                dominated = true
                break
              }
            _ => ()
          }
        }
      // Eligibility guarantees both dimensions; an unscorable entry is kept
      // (and can never dominate anything).
      _ => ()
    }
    if !dominated {
      kept.push(entry)
    }
  }
  kept
}

///|
/// The pick score in IQ points: raw IQ minus the weighted token, cost, and
/// time penalties under the gradient 分数 > tokens > 金钱 > 时间 (weights
/// documented on the constants). Eligibility guarantees both derived
/// dimensions; anything else never reaches ranking and scores on raw IQ.
fn pick_score(point : @devkit.MetricsPoint) -> Double {
  match (pick_tokens_per_pass(point), point.minutes) {
    (Some(tokens_per_pass), Some(minutes)) =>
      point.iq -
      pick_token_penalty_per_m * (tokens_per_pass / 1_000_000.0) -
      pick_cost_penalty_per_usd * point.cost_usd -
      pick_time_penalty_per_10min * (minutes / 10.0)
    _ => point.iq
  }
}

///|
/// Deterministic pick order: score descending, then cheaper cost first,
/// then model name ascending.
fn pick_order(a : PickCandidate, b : PickCandidate) -> Int {
  let score_a = pick_score(a.point)
  let score_b = pick_score(b.point)
  if score_a != score_b {
    return score_b.compare(score_a)
  }
  if a.point.cost_usd != b.point.cost_usd {
    return a.point.cost_usd.compare(b.point.cost_usd)
  }
  a.point.model.compare(b.point.model)
}

///|
/// Dominance-filtered, score-ranked eligible pool, best first.
fn pick_ranked(pool : Array[PickCandidate]) -> Array[PickCandidate] {
  let ranked = pick_dominance_filter(pool)
  ranked.sort_by(pick_order)
  ranked
}

///|
/// Encode one pick candidate verbatim for the host-side candidate notices:
/// slot/model/effort identity plus the source-stated numbers at full
/// precision (number formatting is presentation, the host's job).
fn pick_candidate_json(slot_id : String, point : @devkit.MetricsPoint) -> Json {
  Json::object(
    Map::from_array([
      ("slot_id", Json::string(slot_id)),
      ("model", Json::string(point.model)),
      ("effort", Json::string(point.effort)),
      ("iq", Json::number(point.iq)),
      ("cost_usd", Json::number(point.cost_usd)),
    ]),
  )
}

///|
/// Run the `/model <provider> pick` flow: read the provider's registered
/// metrics, score the eligible slot/effort pairs, auto-switch to the winner
/// mirroring the manual switch branch, and return ranks 2-3 of the filtered
/// pool as candidates. A failed read or an empty eligible pool raises —
/// never a fallback pick.
async fn RouterModelPort::run_provider_pick(
  self : RouterModelPort,
  provider_id : String,
  source : &@devkit.ModelMetricsSource,
) -> @posoco.CommandOutcome raise @posoco.CommandError {
  // The async read can also raise (cancellation, timeout); a raised read is
  // as unavailable as an Err one and folds into the same failure.
  let result = source.read() catch { error => Err(error.to_string()) }
  let points = match result {
    Ok(points) => points
    Err(reason) =>
      raise @posoco.CommandError::ExecutionFailed(
        "metrics unavailable: " + reason,
      )
  }
  let slots : Array[PickSlotFacts] = []
  for slot in self.list_slots() {
    slots.push({
      slot_id: slot.id,
      provider_id: slot.provider_id,
      model_id: slot.model_id,
      thinking_efforts: slot.thinking_efforts,
    })
  }
  let ranked = pick_ranked(pick_eligible_pool(provider_id, points, slots))
  if ranked.is_empty() {
    raise @posoco.CommandError::ExecutionFailed(
      "no eligible " + provider_id + " models in metrics",
    )
  }
  let winner = ranked[0]
  // Validates the effort against the slot and rebuilds it; a mismatch is a
  // command failure.
  self.select_effort(winner.slot_id, winner.point.effort)
  self.active_id = winner.slot_id
  self.publish_model_status()
  self.publish_provider_event()
  // Mirror the manual switch: immediate probe so the bar reflects the new
  // provider's quota as soon as the command returns.
  self.refresh_quota_now()
  let candidates : Array[Json] = []
  let mut rank = 2
  while rank <= 3 && rank <= ranked.length() {
    let entry = ranked[rank - 1]
    candidates.push(pick_candidate_json(entry.slot_id, entry.point))
    rank = rank + 1
  }
  @posoco.CommandOutcome::Success(
    feedback="auto-picked model slot: " +
      winner.slot_id +
      " (" +
      winner.point.effort +
      ")",
    structured=Some(
      Json::object(
        Map::from_array([
          ("provider", Json::string(provider_id)),
          ("picked", pick_candidate_json(winner.slot_id, winner.point)),
          ("candidates", Json::array(candidates)),
        ]),
      ),
    ),
    ui_hint=Some(@posoco.UiHint::RefreshModelList),
  )
}
