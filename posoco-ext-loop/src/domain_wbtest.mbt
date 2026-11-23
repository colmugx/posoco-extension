///|
test "interval parser is bounded, explicit and deterministic" {
  assert_true(parse_loop_interval("1s") is Ok(1000L))
  assert_true(parse_loop_interval("5m") is Ok(300000L))
  assert_true(parse_loop_interval("1h") is Ok(3600000L))
  assert_true(parse_loop_interval("1d") is Ok(86400000L))
  assert_true(parse_loop_interval("0s") is Err(_))
  assert_true(parse_loop_interval("25h") is Err(_))
  assert_true(parse_loop_interval("1ms") is Err(_))
  assert_true(parse_loop_interval("1e3s") is Err(_))
  assert_true(parse_loop_interval("-2m") is Err(_))
  assert_true(parse_loop_interval("9999999999999999999999999d") is Err(_))
  assert_true(parse_loop_interval("abc") is Err(_))
}

///|
test "loop command preserves task text and rejects malformed controls" {
  match parse_loop_action("5m check CI and run tests") {
    Ok(CreateJob(interval_ms~, prompt~)) => {
      assert_eq(interval_ms, 300000L)
      assert_eq(prompt, "check CI and run tests")
    }
    _ => fail("expected create"),
  }
  assert_true(parse_loop_action("") is Ok(ListJobs))
  assert_true(parse_loop_action("list") is Ok(ListJobs))
  assert_true(parse_loop_action("pause loop_1") is Ok(PauseJob(id="loop_1")))
  assert_true(parse_loop_action("resume loop_1") is Ok(ResumeJob(id="loop_1")))
  assert_true(parse_loop_action("stop loop_1") is Ok(StopJob(id="loop_1")))
  assert_true(parse_loop_action("5m") is Err(_))
  assert_true(parse_loop_action("stop") is Err(_))
  assert_true(parse_loop_action("stop loop_1 extra") is Err(_))
}

///|
test "extension contributes the command and a lifecycle, never a tool" {
  let loop = LoopExtension()
  let manifest = loop.manifest()
  assert_eq(manifest.id, "posoco_ext_loop")
  assert_eq(manifest.commands.length(), 1)
  assert_eq(manifest.lifecycle.length(), 1)
  assert_eq(manifest.tools.length(), 0)
  assert_eq(manifest.requires.length(), 0)
  let command : &@posoco.CommandPort = loop
  assert_eq(command.commands()[0].id, "loop")
}

///|
test "command input supports raw and structured JSON" {
  assert_true(loop_raw_args(Json::string("5m check CI")) is Ok("5m check CI"))
  assert_true(
    loop_raw_args(Json::object({ "input": Json::string("1h inspect") })) is
    Ok("1h inspect"),
  )
  assert_true(
    loop_raw_args(Json::object({
      "_positional": Json::string("pause loop_1"),
    })) is Ok("pause loop_1"),
  )
  assert_true(loop_raw_args(Json::number(3.0)) is Err(_))
}
