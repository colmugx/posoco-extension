///|
test "file ops classify read vs write/edit tool names" {
  let messages = [
    user_msg("go"),
    asst_msg("reading", [tool_call("read_file", args_json([("path", "a.txt")]))]),
    tool_result("read_file", "content"),
    asst_msg("writing", [
      tool_call("write_file", args_json([("file_path", "b.txt")])),
      tool_call(
        "edit_file",
        args_json([("old_file_path", "c.txt"), ("new_file_path", "d.txt")]),
      ),
    ]),
    tool_result("write_file", "ok"),
  ]
  assert_eq(extract_file_ops(messages), FileOps::{
    read_files: ["a.txt"],
    modified_files: ["b.txt", "c.txt", "d.txt"],
  })
}

///|
test "files array elements contribute their path" {
  let messages = [
    asst_msg("batch", [
      tool_call(
        "read_many",
        parse_json("{\"files\":[{\"path\":\"e.txt\"},{\"path\":\"f.txt\"}]}"),
      ),
    ]),
  ]
  assert_eq(extract_file_ops(messages), FileOps::{
    read_files: ["e.txt", "f.txt"],
    modified_files: [],
  })
}

///|
test "paths dedupe keeping first-occurrence order" {
  let messages = [
    asst_msg("first", [
      tool_call("read_file", args_json([("path", "a.txt")])),
      tool_call("read_file", args_json([("path", "z.txt")])),
    ]),
    asst_msg("again", [
      tool_call("read_file", args_json([("path", "a.txt")])),
      tool_call("write_file", args_json([("target_file", "a.txt")])),
    ]),
  ]
  assert_eq(extract_file_ops(messages), FileOps::{
    read_files: ["a.txt", "z.txt"],
    modified_files: ["a.txt"],
  })
}

///|
test "tool name match prefers read over write when both appear" {
  let messages = [
    asst_msg("hybrid", [
      tool_call("read_and_write", args_json([("path", "both.txt")])),
    ]),
  ]
  assert_eq(extract_file_ops(messages), FileOps::{
    read_files: ["both.txt"],
    modified_files: [],
  })
}

///|
test "non-string values, unrelated tools, and empty input are skipped" {
  let messages = [
    asst_msg("misc", [
      tool_call("bash", parse_json("{\"path\": 1}")),
      tool_call("grep", args_json([("path", "ignored.txt")])),
    ]),
    user_msg("no tool calls here"),
  ]
  assert_eq(extract_file_ops(messages), FileOps::{
    read_files: [],
    modified_files: [],
  })
  assert_eq(extract_file_ops([]), FileOps::{
    read_files: [],
    modified_files: [],
  })
}
