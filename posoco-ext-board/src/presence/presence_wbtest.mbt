///|
test "blocked wins over running and attention" {
  let presence = BoardPresence::project(running=2, waiting_input=1, attention=1)
  assert_eq(presence.state, Blocked)
  assert_eq(presence.message, Some("Board: waiting for your response"))
  assert_eq(presence.to_json(), {
    "state": "blocked",
    "running": Json::number(2),
    "waiting_input": Json::number(1),
    "attention": Json::number(1),
    "message": "Board: waiting for your response",
  })
}

///|
test "working reports attention or running count" {
  assert_eq(
    BoardPresence::project(running=2, waiting_input=0, attention=0).message,
    Some("Board: 2 running"),
  )
  assert_eq(
    BoardPresence::project(running=1, waiting_input=0, attention=1).message,
    Some("Board: attention needed"),
  )
}

///|
test "idle has no message" {
  let presence = BoardPresence::project(running=0, waiting_input=0, attention=0)
  assert_eq(presence.state, Idle)
  assert_eq(presence.message, None)
}
