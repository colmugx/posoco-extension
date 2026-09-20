///|
/// Radar feed parsing and transport round trip.

///|
/// The verbatim gpt-6-astra feed point documented in
/// docs/model-pick/round-1-plan.md, byte-exact.
fn intelligence_metrics_astra_point() -> String {
  "{\"model\":\"gpt-6-astra\",\"effort\":\"medium\",\"passed\":91,\"total\":127,\"iq\":107.48,\"average_price_usd\":2.262258,\"average_price_usd_by_band\":null,\"average_minutes\":9.0,\"combined_cost_index\":164.15,\"average_agent_steps\":26.17,\"agent_steps_samples\":127,\"average_total_tokens\":1097281.1,\"token_samples\":127,\"cache_hit_rate\":0.943,\"cache_token_samples\":127,\"runs_24h\":2,\"runs_48h\":7,\"runs_total\":128,\"source_updated_at\":\"2026-09-10T03:51:33+00:00\"}"
}

///|
/// The verbatim deepseek-v4-flash feed point documented in
/// docs/model-pick/round-1-plan.md, byte-exact.
fn intelligence_metrics_deepseek_point() -> String {
  "{\"model\":\"deepseek-v4-flash\",\"effort\":\"max\",\"passed\":192,\"total\":336,\"iq\":85.71,\"average_price_usd\":0.224375,\"average_price_usd_by_band\":{\"off_peak\":0.224375,\"peak\":0.44875},\"average_minutes\":31.28,\"combined_cost_index\":729.687,\"runs_24h\":0,\"runs_48h\":4,\"runs_total\":1007}"
}

///|
/// The verbatim not-yet-measured placeholder entry observed on the live feed
/// (docs/model-pick/round-3-plan.md): the model is still being measured, so
/// every metric field is null with zero samples.
fn intelligence_metrics_placeholder_point() -> String {
  "{\"model\": \"deepseek-v4.1-flash\", \"effort\": \"max\", \"passed\": 0, \"total\": 0, \"iq\": null, \"average_price_usd\": null, \"average_price_usd_by_band\": null, \"average_minutes\": null, \"combined_cost_index\": null, \"average_agent_steps\": null, \"agent_steps_samples\": 0, \"average_total_tokens\": null, \"token_samples\": 0, \"cache_hit_rate\": null, \"cache_token_samples\": 0, \"runs_24h\": 0, \"runs_48h\": 0, \"runs_total\": 0, \"source_updated_at\": \"2026-09-10T03:51:33+00:00\"}"
}

///|
/// The two verbatim feed points documented in docs/model-pick/round-1-plan.md,
/// byte-exact inside a minimal schema-3 envelope.
fn intelligence_metrics_fixture() -> String {
  "{\"schema\":3,\"mode\":\"equal_latest_3\",\"points\":[" +
  intelligence_metrics_astra_point() +
  "," +
  intelligence_metrics_deepseek_point() +
  "]}"
}

///|
/// A good point, the verbatim live placeholder, and another good point: the
/// placeholder must be skipped while its neighbors survive.
fn intelligence_metrics_mixed_fixture() -> String {
  "{\"points\":[" +
  intelligence_metrics_astra_point() +
  "," +
  intelligence_metrics_placeholder_point() +
  "," +
  intelligence_metrics_deepseek_point() +
  "]}"
}

///|
test "parse intelligence metrics reads the documented feed points" {
  guard parse_intelligence_metrics(intelligence_metrics_fixture()) is Ok(points) else {
    fail("expected the fixture to parse")
  }
  assert_eq(points.length(), 2)
  assert_eq(points[0].model, "gpt-6-astra")
  assert_eq(points[0].effort, "medium")
  assert_eq(points[0].iq, 107.48)
  assert_eq(points[0].cost_usd, 2.262258)
  assert_eq(points[0].passed, 91)
  assert_eq(points[0].total, 127)
  assert_eq(points[0].tokens, Some(1097281.1))
  assert_eq(points[0].minutes, Some(9.0))
  // The deepseek banded entry parses through: the band object is ignored and
  // the flat average price wins. It states no average_total_tokens, so the
  // optional field stays None — never zero-filled.
  assert_eq(points[1].model, "deepseek-v4-flash")
  assert_eq(points[1].effort, "max")
  assert_eq(points[1].iq, 85.71)
  assert_eq(points[1].cost_usd, 0.224375)
  assert_eq(points[1].passed, 192)
  assert_eq(points[1].total, 336)
  assert_eq(points[1].tokens, None)
  assert_eq(points[1].minutes, Some(31.28))
}

///|
test "parse intelligence metrics rejects malformed feeds" {
  // Body is not JSON.
  assert_true(parse_intelligence_metrics("not json at all") is Err(_))
  // Object without a points array.
  assert_true(
    parse_intelligence_metrics("{\"schema\":3,\"mode\":\"equal_latest_3\"}")
    is Err(_),
  )
  // points stated as something other than an array.
  assert_true(parse_intelligence_metrics("{\"points\":3}") is Err(_))
  // iq stated as a string.
  assert_true(
    parse_intelligence_metrics(
      "{\"points\":[{\"model\":\"gpt-6-astra\",\"effort\":\"low\",\"iq\":\"107.48\",\"average_price_usd\":1.0,\"passed\":10,\"total\":20}]}",
    )
    is Err(_),
  )
  // Non-integral passed count.
  assert_true(
    parse_intelligence_metrics(
      "{\"points\":[{\"model\":\"gpt-6-astra\",\"effort\":\"low\",\"iq\":107.48,\"average_price_usd\":1.0,\"passed\":12.5,\"total\":20}]}",
    )
    is Err(_),
  )
  // Empty model string.
  assert_true(
    parse_intelligence_metrics(
      "{\"points\":[{\"model\":\"\",\"effort\":\"low\",\"iq\":107.48,\"average_price_usd\":1.0,\"passed\":10,\"total\":20}]}",
    )
    is Err(_),
  )
  // average_total_tokens stated as a string.
  assert_true(
    parse_intelligence_metrics(
      "{\"points\":[{\"model\":\"gpt-6-astra\",\"effort\":\"low\",\"iq\":107.48,\"average_price_usd\":1.0,\"passed\":10,\"total\":20,\"average_total_tokens\":\"12345\"}]}",
    )
    is Err(_),
  )
}

///|
test "optional metrics fields tolerate absence and null" {
  // Null optional fields parse as None; absence parses as None too.
  guard parse_intelligence_metrics(
      "{\"points\":[{\"model\":\"gpt-6-astra\",\"effort\":\"low\",\"iq\":107.48,\"average_price_usd\":1.0,\"passed\":10,\"total\":20,\"average_total_tokens\":null,\"average_minutes\":null},{\"model\":\"deepseek-v4-flash\",\"effort\":\"max\",\"iq\":85.71,\"average_price_usd\":0.224375,\"passed\":192,\"total\":336}]}",
    )
    is Ok(points) else {
    fail("expected the null-tolerant points to parse")
  }
  assert_eq(points.length(), 2)
  assert_eq(points[0].tokens, None)
  assert_eq(points[0].minutes, None)
  assert_eq(points[1].tokens, None)
  assert_eq(points[1].minutes, None)
}

///|
test "parse intelligence metrics skips not-yet-stated placeholder points" {
  // The middle entry is the verbatim live placeholder (round-3-plan.md):
  // every metric null with zero samples because the model is still being
  // measured. It is skipped; the good points around it survive.
  guard parse_intelligence_metrics(intelligence_metrics_mixed_fixture())
    is Ok(points) else {
    fail("expected the mixed fixture to parse")
  }
  assert_eq(points.length(), 2)
  assert_eq(points[0].model, "gpt-6-astra")
  assert_eq(points[0].iq, 107.48)
  assert_eq(points[1].model, "deepseek-v4-flash")
  assert_eq(points[1].iq, 85.71)
}

///|
test "parse intelligence metrics skips a point with null iq" {
  guard parse_intelligence_metrics(
      "{\"points\":[{\"model\":\"gpt-6-astra\",\"effort\":\"low\",\"iq\":null,\"average_price_usd\":1.0,\"passed\":10,\"total\":20}]}",
    )
    is Ok(points) else {
    fail("expected the null-iq point to be skipped")
  }
  assert_eq(points.length(), 0)
}

///|
test "parse intelligence metrics skips a point with no model key" {
  // An absent required key is "not stated" too, same as an explicit null.
  guard parse_intelligence_metrics(
      "{\"points\":[{\"effort\":\"low\",\"iq\":107.48,\"average_price_usd\":1.0,\"passed\":10,\"total\":20}]}",
    )
    is Ok(points) else {
    fail("expected the model-less point to be skipped")
  }
  assert_eq(points.length(), 0)
}

///|
priv struct FakeMetricsTransport {
  mut url : String
  status : Int
  body : String
  fail_get : Bool
}

///|
impl OpenAIModelsHttpTransport for FakeMetricsTransport with fn get(
  self : FakeMetricsTransport,
  url : String,
  _headers : Map[String, String],
) -> OpenAIModelsHttpResponse raise @posoco.ModelError {
  self.url = url
  if self.fail_get {
    raise @posoco.ModelError::Transport("fake metrics transport failure")
  }
  OpenAIModelsHttpResponse::{ status: self.status, body: self.body, }
}

///|
async test "metrics source reads through the injected transport" {
  let fake = FakeMetricsTransport::{
    url: "",
    status: 200,
    body: intelligence_metrics_fixture(),
    fail_get: false,
  }
  let transport : &OpenAIModelsHttpTransport = fake
  let source = RadarMetricsSource::{ transport, }
  let borrowed : &@devkit.ModelMetricsSource = source
  guard borrowed.read() is Ok(points) else {
    fail("expected the transport round trip to parse")
  }
  assert_eq(points.length(), 2)
  assert_eq(points[0].iq, 107.48)
  // The feed is the credential-free radar endpoint fetched with no headers.
  assert_eq(
    fake.url,
    "https://codex-reset-radar.pages.dev/api/intelligence-efficiency-metrics?refresh=1",
  )
  // Non-200 means unavailable, never a fallback estimate.
  let down = FakeMetricsTransport::{
    url: "",
    status: 500,
    body: "{}",
    fail_get: false,
  }
  let down_transport : &OpenAIModelsHttpTransport = down
  let down_source : &@devkit.ModelMetricsSource = RadarMetricsSource::{
    transport: down_transport,
  }
  guard down_source.read() is Err(reason) else {
    fail("expected the 500 status to fail the read")
  }
  assert_eq(reason, "intelligence metrics HTTP 500")
  // Transport failures surface as Err strings too.
  let broken = FakeMetricsTransport::{
    url: "",
    status: 200,
    body: "",
    fail_get: true,
  }
  let broken_transport : &OpenAIModelsHttpTransport = broken
  let broken_source : &@devkit.ModelMetricsSource = RadarMetricsSource::{
    transport: broken_transport,
  }
  assert_true(broken_source.read() is Err(_))
}

///|
async test "intelligence metrics source registers under a unique test id" {
  let fake = FakeMetricsTransport::{
    url: "",
    status: 200,
    body: "{\"points\":[{\"model\":\"gpt-6-astra\",\"effort\":\"low\",\"iq\":100.0,\"average_price_usd\":1.0,\"passed\":10,\"total\":20}]}",
    fail_get: false,
  }
  let transport : &OpenAIModelsHttpTransport = fake
  let source = RadarMetricsSource::{ transport, }
  let borrowed : &@devkit.ModelMetricsSource = source
  let id = "openai-metrics-wbtest"
  @devkit.metrics_registry_register(id, borrowed)
  guard @devkit.metrics_registry_lookup(id) is Some(stored) else {
    fail("expected the test registration")
  }
  guard stored.read() is Ok(points) else {
    fail("expected the registered source to read")
  }
  assert_eq(points.length(), 1)
  @devkit.metrics_registry_unregister(id)
  assert_true(@devkit.metrics_registry_lookup(id) is None)
}
