///|
fn origin_of(s : String) -> String {
  match parse_url(s) {
    Some(u) => u.origin_string()
    None => "PARSE_FAILED:\{s}"
  }
}

///|
fn url_of(s : String) -> String {
  match parse_url(s) {
    Some(u) => u.to_url_string()
    None => "PARSE_FAILED:\{s}"
  }
}

///|
fn rejects(s : String) -> Bool {
  parse_url(s) is None
}

///|
fn joined(base : String, reference : String) -> String {
  match parse_url(base) {
    Some(b) => b.join(reference).to_url_string()
    None => "PARSE_FAILED:\{base}"
  }
}

///|
fn host_reason(url : String) -> String {
  match parse_url(url) {
    Some(u) =>
      match check_host(u) {
        HostAllowed => "ALLOWED"
        HostBlocked(r) => r
      }
    None => "PARSE_FAILED"
  }
}

///|
fn same_origin_str(a : String, b : String) -> String {
  match parse_url(a) {
    Some(x) =>
      match parse_url(b) {
        Some(y) => if same_origin(x, y) { "SAME" } else { "DIFF" }
        None => "PARSE_FAILED"
      }
    None => "PARSE_FAILED"
  }
}

///|
fn repeat_a(n : Int) -> String {
  let b = StringBuilder()
  let mut i = 0
  while i < n {
    b.write_char('a')
    i = i + 1
  }
  b.to_string()
}

///|
test "url parse absolute" {
  inspect(
    origin_of("http://example.com/path?q=1"),
    content="http://example.com",
  )
  inspect(
    url_of("http://example.com/path?q=1"),
    content="http://example.com/path?q=1",
  )
  inspect(
    origin_of("HTTPS://EXAMPLE.COM:8443/X"),
    content="https://example.com:8443",
  )
  inspect(
    url_of("HTTPS://EXAMPLE.com/A/b?Q=1"),
    content="https://example.com/A/b?Q=1",
  )
  inspect(url_of("http://example.com"), content="http://example.com/")
  inspect(url_of("http://example.com?a=1"), content="http://example.com/?a=1")
  inspect(origin_of("http://example.com:80/"), content="http://example.com")
  inspect(origin_of("https://example.com:443/"), content="https://example.com")
  inspect(
    origin_of("http://example.com:8080/"),
    content="http://example.com:8080",
  )
  inspect(
    origin_of("https://example.com:80/"),
    content="https://example.com:80",
  )
  inspect(
    url_of("http://example.com/p?q=1#frag"),
    content="http://example.com/p?q=1",
  )
  inspect(url_of("http://example.com/#top"), content="http://example.com/")
  inspect(
    url_of("http://example.com:65535/x"),
    content="http://example.com:65535/x",
  )
}

///|
test "url parse host forms" {
  inspect(origin_of("http://1.2.3.4/x"), content="http://1.2.3.4")
  inspect(origin_of("http://[2001:DB8::AB]/x"), content="http://[2001:db8::ab]")
  inspect(origin_of("http://[::1]:9999/x"), content="http://[::1]:9999")
  inspect(
    origin_of("http://[::ffff:10.0.0.1]:81/x"),
    content="http://[::ffff:10.0.0.1]:81",
  )
  inspect(origin_of("http://[fe80::1]/x"), content="http://[fe80::1]")
  inspect(
    url_of("http://xn--80ak6aa92e.com/p"),
    content="http://xn--80ak6aa92e.com/p",
  )
  inspect(
    url_of("http://my_host.example.com/"),
    content="http://my_host.example.com/",
  )
}

///|
test "url parse rejects" {
  // userinfo
  inspect(rejects("http://user:pass@example.com/"), content="true")
  inspect(rejects("http://@example.com/"), content="true")
  // empty host / authority
  inspect(rejects("http://"), content="true")
  inspect(rejects("http:///path"), content="true")
  inspect(rejects("http://:8080/"), content="true")
  // scheme
  inspect(rejects("ftp://example.com/"), content="true")
  inspect(rejects("file:///etc/passwd"), content="true")
  inspect(rejects("mailto:a@b.c"), content="true")
  inspect(rejects("javascript:alert(1)"), content="true")
  inspect(rejects("httpx://example.com/"), content="true")
  inspect(rejects("example.com/no-scheme"), content="true")
  inspect(rejects("//example.com/x"), content="true")
  inspect(rejects("/relative"), content="true")
  // port boundaries: 0, 65536, junk, empty, double
  inspect(rejects("http://x.com:0/"), content="true")
  inspect(rejects("http://x.com:65536/"), content="true")
  inspect(rejects("http://x.com:99999/"), content="true")
  inspect(rejects("http://x.com:8a/"), content="true")
  inspect(rejects("http://x.com:/"), content="true")
  inspect(rejects("https://x.com:/"), content="true")
  inspect(rejects("http://x.com:80:90/"), content="true")
  // host charset
  inspect(rejects("http://exa mple.com/"), content="true")
  inspect(rejects("http://ex%61mple.com/"), content="true")
  inspect(rejects("http://例子.com/"), content="true")
  // malformed bracket authorities
  inspect(rejects("http://foo[::1]/"), content="true")
  inspect(rejects("http://[::1]x/"), content="true")
  inspect(rejects("http://[::1]:/"), content="true")
  inspect(rejects("http://[]/"), content="true")
}

///|
test "url join matrix" {
  let base = "https://a.example/dir/page"
  // absolute http(s) reference replaces everything
  inspect(
    joined(base, "http://b.example/x?y=2"),
    content="http://b.example/x?y=2",
  )
  inspect(joined(base, "HTTP://B.COM/x"), content="http://b.com/x")
  // foreign scheme: base returned untouched
  inspect(joined(base, "mailto:x@y.z"), content="https://a.example/dir/page")
  inspect(
    joined(base, "javascript:void(0)"),
    content="https://a.example/dir/page",
  )
  inspect(
    joined(base, "data:text/plain,hi"),
    content="https://a.example/dir/page",
  )
  // protocol-relative
  inspect(joined(base, "//b.example/p"), content="https://b.example/p")
  inspect(
    joined(base, "//b.example:8080/p?q=1"),
    content="https://b.example:8080/p?q=1",
  )
  inspect(joined(base, "//b.example/../p"), content="https://b.example/p")
  // root-relative
  inspect(joined(base, "/root"), content="https://a.example/root")
  inspect(joined(base, "/root/"), content="https://a.example/root/")
  // relative and dot segments
  inspect(joined(base, "sibling"), content="https://a.example/dir/sibling")
  inspect(joined(base, "./sibling"), content="https://a.example/dir/sibling")
  inspect(joined(base, "sub/"), content="https://a.example/dir/sub/")
  inspect(joined(base, "../up"), content="https://a.example/up")
  inspect(joined(base, "../../up"), content="https://a.example/up")
  inspect(joined(base, "/a/./b/../c"), content="https://a.example/a/c")
  inspect(
    joined("https://a.example/x/y/z/page", "../q/r"),
    content="https://a.example/x/y/q/r",
  )
  inspect(joined("https://a.example/", "p"), content="https://a.example/p")
  // query and fragment
  inspect(joined(base, "?q=2"), content="https://a.example/dir/page?q=2")
  inspect(
    joined("https://a.example/dir/page?old=1", "?new=2"),
    content="https://a.example/dir/page?new=2",
  )
  inspect(
    joined("https://a.example/dir/page?old=1", "sib"),
    content="https://a.example/dir/sib",
  )
  inspect(joined(base, ""), content="https://a.example/dir/page")
  inspect(joined(base, "#sec"), content="https://a.example/dir/page")
  inspect(joined(base, "sib#sec"), content="https://a.example/dir/sib")
  inspect(joined(base, "  /root  "), content="https://a.example/root")
}

///|
test "url resolve_ref string seam" {
  inspect(
    resolve_ref("https://a.example/dir/page", "sib#x"),
    content="https://a.example/dir/sib",
  )
  inspect(
    resolve_ref("https://a.example/dir/page", "//b.example/p"),
    content="https://b.example/p",
  )
  inspect(resolve_ref("not a url", "x"), content="not a url")
}

///|
test "url guard blocks localhost and local suffixes" {
  inspect(host_reason("http://localhost/"), content="localhost")
  inspect(host_reason("http://LocalHost:8080/"), content="localhost")
  inspect(host_reason("http://localhost./"), content="localhost")
  inspect(
    host_reason("http://app.localhost/"),
    content="local suffix app.localhost",
  )
  inspect(
    host_reason("http://x.y.localhost/"),
    content="local suffix x.y.localhost",
  )
  inspect(
    host_reason("http://printer.local/"),
    content="local suffix printer.local",
  )
  inspect(
    host_reason("http://db.corp.internal:5432/"),
    content="local suffix db.corp.internal",
  )
}

///|
test "url guard blocks ipv4 ranges" {
  inspect(
    host_reason("http://127.0.0.1/"),
    content="loopback address 127.0.0.1",
  )
  inspect(
    host_reason("http://127.8.8.8/"),
    content="loopback address 127.8.8.8",
  )
  inspect(host_reason("http://10.0.0.1/"), content="private address 10.0.0.1")
  inspect(
    host_reason("http://10.255.0.1/"),
    content="private address 10.255.0.1",
  )
  inspect(
    host_reason("http://172.16.0.1/"),
    content="private address 172.16.0.1",
  )
  inspect(
    host_reason("http://172.31.255.254/"),
    content="private address 172.31.255.254",
  )
  inspect(
    host_reason("http://192.168.1.1/"),
    content="private address 192.168.1.1",
  )
  inspect(
    host_reason("http://192.168.0.0/"),
    content="private address 192.168.0.0",
  )
  inspect(
    host_reason("http://169.254.169.254/latest/meta-data/"),
    content="link-local address 169.254.169.254",
  )
  inspect(
    host_reason("http://169.254.0.99/"),
    content="link-local address 169.254.0.99",
  )
  inspect(host_reason("http://0.0.0.0/"), content="unspecified address 0.0.0.0")
}

///|
test "url guard blocks ipv6 ranges" {
  inspect(host_reason("http://[::1]/"), content="IPv6 loopback ::1")
  inspect(host_reason("http://[::]/"), content="IPv6 unspecified ::")
  inspect(host_reason("http://[fe80::1]/"), content="IPv6 link-local fe80::1")
  inspect(host_reason("http://[fe80::]/"), content="IPv6 link-local fe80::")
  inspect(host_reason("http://[fc00::1]/"), content="IPv6 ULA fc00::1")
  inspect(
    host_reason("http://[fd12:3456:789a::1]/"),
    content="IPv6 ULA fd12:3456:789a::1",
  )
  inspect(
    host_reason("http://[::ffff:127.0.0.1]/"),
    content="loopback address 127.0.0.1 (IPv4-embedded)",
  )
  inspect(
    host_reason("http://[::ffff:10.0.0.1]/"),
    content="private address 10.0.0.1 (IPv4-embedded)",
  )
  inspect(
    host_reason("http://[::ffff:169.254.169.254]/"),
    content="link-local address 169.254.169.254 (IPv4-embedded)",
  )
  inspect(
    host_reason("http://[::ffff:0.0.0.0]/"),
    content="unspecified address 0.0.0.0 (IPv4-embedded)",
  )
  inspect(
    host_reason("http://[::192.168.1.1]/"),
    content="private address 192.168.1.1 (IPv4-embedded)",
  )
  inspect(
    host_reason("http://[::ffff:7f00:1]/"),
    content="IPv4-embedded ::ffff:7f00:1",
  )
}

///|
test "url guard blocks nonstandard numeric hosts" {
  inspect(
    host_reason("http://2130706433/"),
    content="nonstandard numeric host 2130706433",
  )
  inspect(
    host_reason("http://127.1/"),
    content="nonstandard numeric host 127.1",
  )
  inspect(host_reason("http://10.1/"), content="nonstandard numeric host 10.1")
  inspect(
    host_reason("http://0177.0.0.1/"),
    content="nonstandard numeric host 0177.0.0.1",
  )
  inspect(
    host_reason("http://0x7f000001/"),
    content="nonstandard numeric host 0x7f000001",
  )
  inspect(
    host_reason("http://0x7f.0.0.1/"),
    content="nonstandard numeric host 0x7f.0.0.1",
  )
  inspect(
    host_reason("http://999.1.1.1/"),
    content="nonstandard numeric host 999.1.1.1",
  )
}

///|
test "url guard allows public hosts" {
  inspect(host_reason("http://example.com/"), content="ALLOWED")
  inspect(host_reason("https://Example.COM:443/"), content="ALLOWED")
  inspect(host_reason("http://sub.example.com/"), content="ALLOWED")
  inspect(host_reason("http://example.com./"), content="ALLOWED")
  inspect(host_reason("http://8.8.8.8/"), content="ALLOWED")
  inspect(host_reason("http://1.1.1.1/"), content="ALLOWED")
  inspect(host_reason("http://172.15.0.1/"), content="ALLOWED")
  inspect(host_reason("http://172.32.0.1/"), content="ALLOWED")
  inspect(host_reason("http://172.16.255.255.1/"), content="ALLOWED")
  inspect(host_reason("http://0xproject.com/"), content="ALLOWED")
  inspect(host_reason("http://01.org/"), content="ALLOWED")
  inspect(host_reason("http://[2606:4700::1111]/"), content="ALLOWED")
  inspect(host_reason("http://[2001:db8::1]/"), content="ALLOWED")
  inspect(host_reason("http://[::ffff:8.8.8.8]/"), content="ALLOWED")
}

///|
test "url same origin" {
  inspect(same_origin_str("http://a.com/x", "http://a.com/y"), content="SAME")
  inspect(
    same_origin_str("http://a.com:80/x", "http://a.com/y"),
    content="SAME",
  )
  inspect(same_origin_str("http://a.com/x", "http://A.COM/y"), content="SAME")
  inspect(
    same_origin_str("http://[::1]:99/x", "http://[::1]:99/y"),
    content="SAME",
  )
  inspect(same_origin_str("http://a.com/x", "https://a.com/x"), content="DIFF")
  inspect(
    same_origin_str("http://a.com:81/x", "http://a.com/y"),
    content="DIFF",
  )
  inspect(same_origin_str("http://a.com/x", "http://b.com/x"), content="DIFF")
  inspect(
    same_origin_str("http://a.com/x", "https://a.com:443/x"),
    content="DIFF",
  )
}

///|
test "url length bounds" {
  inspect(url_length_ok(""), content="true")
  inspect(url_length_ok("http://e.com/"), content="true")
  inspect(url_length_ok("http://e.com/\{repeat_a(1987)}"), content="true") // 2000 chars
  inspect(url_length_ok("http://e.com/\{repeat_a(1988)}"), content="false") // 2001 chars
}
