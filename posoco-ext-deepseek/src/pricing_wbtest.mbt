///|
/// Assert the phase the vendor rule states at `now_ms`. Pure clock math, so
/// these run without touching `phase()`'s wall clock.

///|
fn assert_deepseek_phase(
  now_ms : Int64,
  expected_tier : String,
  expected_multiplier : String,
) -> Unit raise {
  let phase = deepseek_pricing_phase(now_ms)
  assert_eq(phase.tier, expected_tier)
  assert_eq(phase.multiplier, expected_multiplier)
  assert_eq(phase.window, "9:00 ~ 12:00, 14:00 ~ 18:00")
}

///|
test "beijing wall clock anchors the epoch to Thursday 08:00" {
  // 1970-01-01T00:00Z = Beijing Thursday 08:00: weekday 4, minute 480.
  assert_eq(beijing_wall_clock(0L), (4, 480))
}

///|
test "deepseek phase peaks exactly on weekday window bounds" {
  // Unix day 5 = 1970-01-06 (Tuesday). Beijing Tuesday 08:00 = day 5 00:00Z,
  // so each Beijing wall time below is day 5 plus its minutes past 08:00.
  let tue = 5L * 86400000L
  // Beijing Tue 09:00 = 01:00Z — first minute of the morning window.
  let tue_0900 = tue + 60L * 60000L
  // Beijing Tue 11:59 = 03:59Z — last minute of the morning window.
  let tue_1159 = tue + 239L * 60000L
  // Beijing Tue 12:00 = 04:00Z — first minute outside the morning window.
  let tue_1200 = tue + 240L * 60000L
  // Beijing Tue 14:00 = 06:00Z — first minute of the afternoon window.
  let tue_1400 = tue + 360L * 60000L
  // Beijing Tue 17:59 = 09:59Z — last minute of the afternoon window.
  let tue_1759 = tue + 599L * 60000L
  // Beijing Tue 18:00 = 10:00Z — first minute outside the afternoon window.
  let tue_1800 = tue + 600L * 60000L
  assert_deepseek_phase(tue_0900, "peak", "2x")
  assert_deepseek_phase(tue_1159, "peak", "2x")
  assert_deepseek_phase(tue_1200, "off-peak", "1x")
  assert_deepseek_phase(tue_1400, "peak", "2x")
  assert_deepseek_phase(tue_1759, "peak", "2x")
  assert_deepseek_phase(tue_1800, "off-peak", "1x")
}

///|
test "deepseek phase stays off-peak on weekends even inside window times" {
  // Unix day 2 = 1970-01-03 (Saturday); Beijing Sat 10:00 = day 2 02:00Z.
  // 10:00 falls inside a weekday window, but the weekend gate wins.
  let sat_1000 = 2L * 86400000L + 120L * 60000L
  assert_eq(beijing_wall_clock(sat_1000), (6, 600))
  assert_deepseek_phase(sat_1000, "off-peak", "1x")
}
