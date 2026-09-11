///|
/// DeepSeek peak/off-peak pricing, ported verbatim from cetas-js (where the
/// vendor rule was removed). Facts only, never an estimate: peak windows are
/// Beijing 9:00–12:00 and 14:00–18:00 on weekdays; Saturday and Sunday are
/// always off-peak; holidays are not modeled. Peak multiplier is the
/// provider's "2x", off-peak "1x", and the window text is DeepSeek's own
/// display string.

///|
/// Beijing wall clock from a unix millisecond timestamp, as
/// `(weekday, minutes_of_day)` with weekday 0=Sunday. Beijing has no DST, so
/// the fixed +8h shift is exact; unix day 0 (1970-01-01) was a Thursday,
/// hence `(days + 4) mod 7`.
fn beijing_wall_clock(now_ms : Int64) -> (Int, Int) {
  let shifted = now_ms + 28800000L
  let days = shifted / 86400000L
  let minutes = (shifted % 86400000L / 60000L).to_int()
  let weekday = ((days + 4L) % 7L).to_int()
  (weekday, minutes)
}

///|
/// The vendor rule as pure clock math: no credentials, no network, one
/// shared phase across all DeepSeek models.
fn deepseek_pricing_phase(now_ms : Int64) -> @devkit.PricingPhase {
  let (weekday, minutes) = beijing_wall_clock(now_ms)
  let is_weekday = weekday >= 1 && weekday <= 5
  let in_peak_window = (minutes >= 540 && minutes < 720) ||
    (minutes >= 840 && minutes < 1080)
  let (tier, multiplier) = if is_weekday && in_peak_window {
    ("peak", "2x")
  } else {
    ("off-peak", "1x")
  }
  { tier, multiplier, window: "9:00 ~ 12:00, 14:00 ~ 18:00", }
}

///|
priv struct DeepSeekPricingSource {}

///|
impl @devkit.PricingSource for DeepSeekPricingSource with fn phase(
  _self : DeepSeekPricingSource,
) -> @devkit.PricingPhase? {
  Some(deepseek_pricing_phase(@async.now()))
}
