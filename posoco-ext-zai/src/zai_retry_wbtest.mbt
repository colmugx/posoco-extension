///|
test "retry policy: bounded attempts with short backoff" {
  assert_eq(ZAI_TRANSPORT_MAX_ATTEMPTS, 3)
  assert_eq(zai_transport_retry_delay_ms(2), 500)
  assert_eq(zai_transport_retry_delay_ms(3), 1000)
}

///|
async test "a connection dropped before the response head is re-dialed" {
  let hits = [0]
  @async.with_task_group() <| group => {
    let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
    let port = UInt16::to_int(server.addr.port)
    group.spawn_bg(no_wait=true) <| () => {
      server.run_forever() <| ((_request, conn) => {
        hits[0] += 1
        if hits[0] < 3 {
          // Abort the connection with the request already received: the
          // client sees EOF while finishing the request, the exact shape
          // of a provider dropping a dial.
          fail("flaky upstream")
        }
        conn.send_response(200, "OK")
      })
    }
    let (client, response) = zai_open_stream_with_retry(
      "http://127.0.0.1:\{port}/api/paas/v4/chat/completions",
      b"",
      Map([]),
    )
    defer client.close()
    assert_eq(response.code, 200)
    assert_eq(hits[0], 3)
  }
}
