///|
test "framing preserves structured data across split UTF-8 chunks" {
  let decoder = @protocol.Decoder(max_frame_bytes=256)
  let frames = decoder.feed(b"{\"message\":\"\xe4\xb8")
  assert_eq(frames.length(), 0)
  let frames = decoder.feed(b"\xad\"}\n{\"value\":42}\n")
  assert_eq(frames.length(), 2)
  json_inspect(frames[0], content={ "message": "中" })
  json_inspect(frames[1], content={ "value": 42 })
  decoder.finish()
}
