///|
test "freshness: nonexistent target is always fresh" {
  let ledger = FreshnessGuard::FreshnessGuard()
  debug_inspect(ledger.check("/a.txt", None), content="Fresh")
}

///|
test "freshness: existing unread file is NeverRead" {
  let ledger = FreshnessGuard::FreshnessGuard()
  let stamp = FileStamp::{ mtime_s: 1L, mtime_ns: 2, size: 10L }
  debug_inspect(ledger.check("/a.txt", Some(stamp)), content="NeverRead")
}

///|
test "freshness: matching stamp is Fresh" {
  let ledger = FreshnessGuard::FreshnessGuard()
  let stamp = FileStamp::{ mtime_s: 1L, mtime_ns: 2, size: 10L }
  ledger.note_read("/a.txt", stamp)
  debug_inspect(ledger.check("/a.txt", Some(stamp)), content="Fresh")
}

///|
test "freshness: size change is Modified" {
  let ledger = FreshnessGuard::FreshnessGuard()
  ledger.note_read("/a.txt", FileStamp::{ mtime_s: 1L, mtime_ns: 2, size: 10L })
  let changed = FileStamp::{ mtime_s: 1L, mtime_ns: 2, size: 11L }
  debug_inspect(ledger.check("/a.txt", Some(changed)), content="Modified")
}

///|
test "freshness: mtime change with equal size is Modified" {
  let ledger = FreshnessGuard::FreshnessGuard()
  ledger.note_read("/a.txt", FileStamp::{ mtime_s: 1L, mtime_ns: 2, size: 10L })
  let changed = FileStamp::{ mtime_s: 3L, mtime_ns: 4, size: 10L }
  debug_inspect(ledger.check("/a.txt", Some(changed)), content="Modified")
}

///|
test "freshness: records are per path" {
  let ledger = FreshnessGuard::FreshnessGuard()
  ledger.note_read("/a.txt", FileStamp::{ mtime_s: 1L, mtime_ns: 2, size: 10L })
  let other = FileStamp::{ mtime_s: 1L, mtime_ns: 2, size: 10L }
  debug_inspect(ledger.check("/b.txt", Some(other)), content="NeverRead")
}

///|
test "freshness: forget drops the record" {
  let ledger = FreshnessGuard::FreshnessGuard()
  let stamp = FileStamp::{ mtime_s: 1L, mtime_ns: 2, size: 10L }
  ledger.note_read("/a.txt", stamp)
  ledger.forget("/a.txt")
  debug_inspect(ledger.check("/a.txt", Some(stamp)), content="NeverRead")
}

///|
test "freshness: hints for each verdict" {
  inspect(Fresh.hint(), content="file is current")
  inspect(
    NeverRead.hint(),
    content="file exists but has not been read in this session; read it first",
  )
  inspect(
    Modified.hint(),
    content="file changed since it was last read; read it again",
  )
}
