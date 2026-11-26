///|
// gzip -c of "hello gzip" with a zeroed mtime: header, deflate body, CRC, ISIZE.
const GZIP_HELLO = b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03\xcb\x48\xcd\xc9\xc9\x57\x48\xaf\xca\x2c\x00\x00\x19\x6a\xd2\xdf\x0a\x00\x00\x00"

///|
async test "default http io decodes a gzip response body transparently" {
  let server = @http.Server(@socket.Addr::resolve("127.0.0.1", port=0))
  let port = server.local_addr().port
  @async.with_task_group() <| group => {
    group.spawn_bg(async fn() {
      let conn = server.accept()
      let _ = conn.read_request()
      let extra : @http.Headers = Map([])
      extra[@http.CaseInsensitiveString("Content-Encoding")] = "gzip"
      conn.send_response(200, "OK", extra_headers=extra)
      conn.write(GZIP_HELLO)
      conn.end_response()
      conn.close()
    })
    let reply = default_http_io().fetch("http://127.0.0.1:\{port}/", 1024)
    assert_eq(reply.status, 200)
    assert_eq(reply.body, "hello gzip")
  }
  server.close()
}
