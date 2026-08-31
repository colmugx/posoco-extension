///|
/// One converted document as cached after a successful fetch. `content` is
/// the full converted text, so later pages slice from cache without a
/// refetch; `retrieved_ms` is the clock reading taken when it was stored.
pub struct CachedDoc {
  title : String
  content : String
  content_type : String
  url_requested : String
  url_final : String
  status : Int
  bytes_fetched : Int
  retrieved_ms : Int64
}

///|
/// TTL + LRU cache of converted documents, keyed by the *requested* URL (not
/// the final URL after redirects). `order` tracks recency with the most
/// recent key at the tail; a `get` hit refreshes recency.
pub struct DocCache {
  ttl_ms : Int64
  cap : Int
  now_ms : () -> Int64
  entries : Map[String, CachedDoc]
  order : Array[String]
}

///|
/// The default clock returns constant 0: this module owns no IO, and the
/// host layer injects the real clock (`@async.now()` or similar) at
/// construction. An entry expires once its age reaches `ttl_ms`.
pub fn DocCache::DocCache(
  ttl_ms? : Int64 = 900_000L,
  cap? : Int = 50,
  now_ms? : () -> Int64 = fn() { 0L },
) -> DocCache {
  { ttl_ms, cap, now_ms, entries: Map::from_array([]), order: [], }
}

///|
/// Remove `url` from the recency order in place; false when it was absent.
pub fn DocCache::shift_out(self : DocCache, url : String) -> Bool {
  let n = self.order.length()
  let mut found = -1
  for i in 0..<n {
    if self.order[i] == url {
      found = i
      break
    }
  }
  if found < 0 {
    return false
  }
  let last = n - 1
  for i in found..<last {
    self.order[i] = self.order[i + 1]
  }
  ignore(self.order.pop())
  true
}

///|
pub fn DocCache::touch(self : DocCache, url : String) -> Unit {
  ignore(self.shift_out(url))
  self.order.push(url)
}

///|
pub fn DocCache::drop_key(self : DocCache, url : String) -> Unit {
  ignore(self.entries.remove(url))
  ignore(self.shift_out(url))
}

///|
/// Hit returns the cached doc and refreshes recency; an expired entry is
/// treated as a miss and evicted.
pub fn DocCache::get(self : DocCache, url : String) -> CachedDoc? {
  match self.entries.get(url) {
    None => None
    Some(doc) =>
      if (self.now_ms)() - doc.retrieved_ms >= self.ttl_ms {
        self.drop_key(url)
        None
      } else {
        self.touch(url)
        Some(doc)
      }
  }
}

///|
/// Store (or overwrite) `doc` under the requested URL, then evict the least
/// recently used entries while over capacity. Overwriting refreshes recency.
pub fn DocCache::put(self : DocCache, url : String, doc : CachedDoc) -> Unit {
  self.entries[url] = doc
  self.touch(url)
  while self.order.length() > self.cap {
    let oldest = self.order[0]
    self.drop_key(oldest)
  }
}
