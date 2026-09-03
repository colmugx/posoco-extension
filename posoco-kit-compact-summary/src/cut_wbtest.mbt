///|
/// Each fixture message below carries a 40-char text (10 estimated tokens)
/// unless stated otherwise.

///|
test "cut lands on user message without retreat" {
  let messages = [
    user_msg(String::make(40, 'a')),
    asst_msg(String::make(40, 'a'), []),
    tool_result("read", String::make(40, 'a')),
    user_msg(String::make(40, 'b')),
    asst_msg(String::make(40, 'b'), []),
    tool_result("read", String::make(40, 'b')),
  ]
  // Tail [3..6) totals 30 tokens; the budget runs out exactly on U3.
  assert_eq(select_cut(messages, 30), CutPoint::{
    head_end: 3,
    kept_from: 3,
    is_split_turn: false,
    turn_start_index: 3,
  })
}

///|
test "cut retreats before tool result to keep assistant+tool pair intact" {
  let messages = [
    user_msg(String::make(40, 'a')),
    asst_msg(String::make(40, 'a'), [
      tool_call("read_file", args_json([("path", "x")])),
    ]),
    tool_result("read_file", String::make(40, 'a')),
    asst_msg(String::make(40, 'b'), []),
    tool_result("bash", String::make(40, 'b')),
  ]
  // Tail [2..5) reaches the budget on the T2 tool result; the boundary must
  // not fall between A1 and T2, so it retreats onto A1 (turn-head assistant).
  let cut = select_cut(messages, 25)
  assert_eq(cut.head_end, 1)
  assert_eq(cut.kept_from, 1)
  // The single turn is 50 tokens, above the 25 budget: split turn.
  assert_true(cut.is_split_turn)
  assert_eq(cut.turn_start_index, 0)
}

///|
test "cut accepts candidate directly on turn-head assistant" {
  let messages = [
    user_msg(String::make(40, 'a')),
    asst_msg(String::make(40, 'a'), []),
    tool_result("read", String::make(40, 'a')),
    asst_msg(String::make(40, 'b'), []),
    tool_result("read", String::make(40, 'b')),
  ]
  let cut = select_cut(messages, 35)
  assert_eq(cut.kept_from, 1)
  assert_eq(cut.head_end, 1)
}

///|
test "protect_prefix keeps background out of the summary range" {
  let messages = [
    user_msg(String::make(40, 's')),
    asst_msg(String::make(40, 's'), []),
    tool_result("read", String::make(40, 's')),
    user_msg(String::make(3000, 'b')),
    asst_msg(String::make(40, 't'), []),
    tool_result("read", String::make(40, 't')),
  ]
  let cut = select_cut(messages, 100, protect_prefix=3)
  assert_eq(cut.head_end, 3)
  assert_eq(cut.kept_from, 3)
  assert_true(cut.is_split_turn)
  assert_eq(cut.turn_start_index, 3)
}

///|
test "protect_prefix above everything leaves nothing to summarize" {
  let messages = [
    user_msg(String::make(40, 'a')),
    asst_msg(String::make(40, 'a'), []),
    tool_result("read", String::make(40, 'a')),
    user_msg(String::make(40, 'b')),
    asst_msg(String::make(40, 'b'), []),
    tool_result("read", String::make(40, 'b')),
  ]
  assert_eq(select_cut(messages, 1000, protect_prefix=3), CutPoint::{
    head_end: 3,
    kept_from: 3,
    is_split_turn: false,
    turn_start_index: 3,
  })
  // Without protection the whole span fits too.
  assert_eq(select_cut(messages, 1000), CutPoint::{
    head_end: 0,
    kept_from: 0,
    is_split_turn: false,
    turn_start_index: 0,
  })
}

///|
test "protect_prefix clamps an unsafe retreat at the boundary" {
  // A tool result sits right at the protected boundary; the retreat cannot
  // cross it, so the head range collapses to empty and nothing is summarized.
  let messages = [
    user_msg(String::make(40, 'a')),
    tool_result("read", String::make(40, 'a')),
  ]
  let cut = select_cut(messages, 5, protect_prefix=1)
  assert_eq(cut.head_end, 1)
  assert_eq(cut.kept_from, 1)
}

///|
test "split turn is flagged with its user message index" {
  let messages = [
    user_msg(String::make(24000, 'b')),
    asst_msg(String::make(40, 'a'), []),
    tool_result("read", String::make(40, 'a')),
  ]
  let cut = select_cut(messages, 1000)
  assert_eq(cut, CutPoint::{
    head_end: 0,
    kept_from: 0,
    is_split_turn: true,
    turn_start_index: 0,
  })
}

///|
test "split turn before an oversized turn leaves earlier turns summarizable" {
  let messages = [
    system_msg("system"),
    user_msg(String::make(40, 'a')),
    asst_msg(String::make(40, 'a'), []),
    tool_result("read", String::make(40, 'a')),
    user_msg(String::make(8000, 'b')),
    asst_msg(String::make(40, 'c'), []),
    tool_result("read", String::make(40, 'c')),
  ]
  let cut = select_cut(messages, 1000)
  assert_eq(cut.head_end, 4)
  assert_eq(cut.kept_from, 4)
  assert_true(cut.is_split_turn)
  assert_eq(cut.turn_start_index, 4)
}

///|
test "empty transcript produces a no-op cut" {
  assert_eq(select_cut([], 100), CutPoint::{
    head_end: 0,
    kept_from: 0,
    is_split_turn: false,
    turn_start_index: 0,
  })
}
