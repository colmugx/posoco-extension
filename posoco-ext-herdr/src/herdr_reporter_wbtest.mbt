///|
fn recorder() -> (Array[String], (String, Array[String]) -> Unit) {
  let calls : Array[String] = []
  fn record(bin : String, args : Array[String]) -> Unit {
    calls.push(bin + " " + args.join(" "))
  }
  (calls, record)
}

///|
test "observer maps turn lifecycle onto herdr states" {
  let (calls, record) = recorder()
  let reporter : HerdrReporter = { pane: "1-2", bin: "herdr", spawn: record, }
  reporter.on_event(@posoco.TurnEvent::TurnStarted)
  reporter.on_event(@posoco.TurnEvent::TurnCompleted)
  reporter.on_event(@posoco.TurnEvent::TurnFailed("boom"))
  inspect(
    calls.join("\n"),
    content=(
      #|herdr pane report-agent 1-2 --source cetas --agent cetas --state working
      #|herdr pane report-agent 1-2 --source cetas --agent cetas --state idle
      #|herdr pane report-agent 1-2 --source cetas --agent cetas --state idle
    ),
  )
}

///|
test "emit builds the report-agent argv from pane and bin" {
  let (calls, record) = recorder()
  let reporter : HerdrReporter = {
    pane: "w1:p1",
    bin: "/usr/local/bin/herdr",
    spawn: record,
  }
  reporter.emit(Idle)
  inspect(
    calls[0],
    content="/usr/local/bin/herdr pane report-agent w1:p1 --source cetas --agent cetas --state idle",
  )
}

///|
test "extension manifest contributes exactly one observer" {
  let (_, record) = recorder()
  let reporter : HerdrReporter = { pane: "1-1", bin: "herdr", spawn: record, }
  inspect(reporter.extension_id(), content="posoco_ext_herdr")
  let m = reporter.manifest()
  inspect(m.id, content="posoco_ext_herdr")
  inspect(m.observers.length(), content="1")
  inspect(m.tools.length(), content="0")
  inspect(m.prompt_contributors.length(), content="0")
}

///|
test "shell quoting wraps args and escapes single quotes" {
  inspect(herdr_shell_quote("plain"), content="'plain'")
  inspect(herdr_shell_quote("it's"), content="'it'\\''s'")
  inspect(herdr_shell_quote(""), content="''")
}
