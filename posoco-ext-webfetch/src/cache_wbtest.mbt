///|
priv struct FakeClock {
  mut now_ms : Int64
}

///|
fn cached_doc(url : String, content : String, at_ms? : Int64 = 0L) -> CachedDoc {
  {
    title: "t",
    content,
    content_type: "text/markdown",
    url_requested: url,
    url_final: url,
    status: 200,
    bytes_fetched: 100,
    retrieved_ms: at_ms,
  }
}

///|
test "cache get hit refreshes recency so the untouched key is evicted" {
  let clock : FakeClock = { now_ms: 1000L, }
  let cache = DocCache(ttl_ms=900_000L, cap=2, now_ms=fn() { clock.now_ms })
  cache.put("https://a.com", cached_doc("https://a.com", "alpha", at_ms=1000L))
  clock.now_ms = 1000L + 899_999L
  cache.put(
    "https://b.com",
    cached_doc("https://b.com", "beta", at_ms=1000L + 899_999L),
  )
  // a is one tick before expiry and, crucially, the oldest — the hit must
  // both succeed and refresh its recency.
  guard cache.get("https://a.com") is Some(d) else {
    fail("expected a hit one tick before expiry")
  }
  inspect(
    d.content,
    content=(
      #|alpha
    ),
  )
  cache.put(
    "https://c.com",
    cached_doc("https://c.com", "gamma", at_ms=1000L + 899_999L),
  )
  inspect(
    cache.get("https://b.com") is None,
    content=(
      #|true
    ),
  )
  inspect(
    cache.get("https://a.com") is Some(_),
    content=(
      #|true
    ),
  )
  inspect(
    cache.get("https://c.com") is Some(_),
    content=(
      #|true
    ),
  )
}

///|
test "cache entry expires at ttl age and is evicted on get" {
  let clock : FakeClock = { now_ms: 0L, }
  let cache = DocCache(ttl_ms=900_000L, now_ms=fn() { clock.now_ms })
  cache.put("https://a.com", cached_doc("https://a.com", "alpha", at_ms=0L))
  clock.now_ms = 899_999L
  inspect(
    cache.get("https://a.com") is Some(_),
    content=(
      #|true
    ),
  )
  clock.now_ms = 900_000L
  inspect(
    cache.get("https://a.com") is None,
    content=(
      #|true
    ),
  )
  inspect(
    cache.entries.length(),
    content=(
      #|0
    ),
  )
  inspect(
    cache.order.length(),
    content=(
      #|0
    ),
  )
}

///|
test "cache put beyond capacity evicts the least recently used" {
  let clock : FakeClock = { now_ms: 0L, }
  let cache = DocCache(ttl_ms=900_000L, cap=2, now_ms=fn() { clock.now_ms })
  cache.put("https://a.com", cached_doc("https://a.com", "alpha"))
  cache.put("https://b.com", cached_doc("https://b.com", "beta"))
  cache.put("https://c.com", cached_doc("https://c.com", "gamma"))
  inspect(
    cache.get("https://a.com") is None,
    content=(
      #|true
    ),
  )
  inspect(
    cache.get("https://b.com") is Some(_),
    content=(
      #|true
    ),
  )
  inspect(
    cache.get("https://c.com") is Some(_),
    content=(
      #|true
    ),
  )
  inspect(
    cache.entries.length(),
    content=(
      #|2
    ),
  )
}

///|
test "cache put overwrites the same key without growth" {
  let clock : FakeClock = { now_ms: 0L, }
  let cache = DocCache(now_ms=fn() { clock.now_ms })
  cache.put("https://a.com", cached_doc("https://a.com", "alpha"))
  cache.put("https://a.com", cached_doc("https://a.com", "uno"))
  inspect(
    cache.entries.length(),
    content=(
      #|1
    ),
  )
  inspect(
    cache.order.length(),
    content=(
      #|1
    ),
  )
  guard cache.get("https://a.com") is Some(d) else { fail("expected a hit") }
  inspect(
    d.content,
    content=(
      #|uno
    ),
  )
}

///|
test "cache default clock is the constant zero placeholder" {
  let cache = DocCache(ttl_ms=10L)
  cache.put("https://a.com", cached_doc("https://a.com", "alpha", at_ms=0L))
  inspect(
    cache.get("https://a.com") is Some(_),
    content=(
      #|true
    ),
  )
}
