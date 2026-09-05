///|
/// posoco_ext_mbtx_wbtest.mbt — white-box tests for the mbtx tool surface:
/// tool listing/schema, argument decode (native target rejection, escalated
/// gating), decode-before-execute ordering, the exemptions self-report, and
/// the description/system-prompt contract.

///|
fn mbtx_args_obj(pairs : Array[(String, Json)]) -> Json {
  Json::object(Map::from_array(pairs))
}

///|
fn mbtx_schema_properties(schema : Json) -> Map[String, Json] raise {
  match schema {
    Json::Object(map) =>
      if map.contains("properties") {
        match map["properties"] {
          Json::Object(props) => props
          _ => fail("schema 'properties' must be an object")
        }
      } else {
        fail("schema must declare 'properties'")
      }
    _ => fail("input_schema must be a JSON object")
  }
}

///|
fn mbtx_schema_required(schema : Json) -> Array[String] raise {
  match schema {
    Json::Object(map) =>
      if map.contains("required") {
        match map["required"] {
          Json::Array(items) => {
            let out : Array[String] = []
            for item in items {
              match item {
                Json::String(s) => out.push(s)
                _ => fail("required entries must be strings")
              }
            }
            out
          }
          _ => fail("schema 'required' must be an array")
        }
      } else {
        fail("schema must declare 'required'")
      }
    _ => fail("input_schema must be a JSON object")
  }
}

///|
async test "list_tools exposes the single mbtx tool" {
  let defs = MbtxTools().list_tools()
  assert_eq(defs.length(), 1)
  assert_eq(defs[0].name.to_string(), "mbtx")
  assert_true(defs[0].description.length() > 0)
  match defs[0].provenance {
    Some(s) => assert_eq(s, "posoco_ext_mbtx")
    None => fail("expected provenance to be set")
  }
  assert_true(defs[0].policy is @posoco.ExecutionPolicy::Parallel)
}

///|
async test "schema exposes source and target but not escalated by default" {
  let defs = MbtxTools().list_tools()
  let schema = defs[0].input_schema
  let props = mbtx_schema_properties(schema)
  assert_true(props.contains("source"))
  assert_true(props.contains("target"))
  assert_false(props.contains("escalated"))
  assert_eq(mbtx_schema_required(schema), ["source"])
  match props["target"] {
    Json::Object(target) =>
      if target.contains("enum") {
        match target["enum"] {
          Json::Array(items) => assert_eq(items.length(), 4)
          _ => fail("target enum must be an array")
        }
      } else {
        fail("target must declare an enum")
      }
    _ => fail("target property must be an object")
  }
}

///|
async test "schema exposes escalated only when constructed with escalation" {
  let defs = MbtxTools(escalation=true).list_tools()
  let props = mbtx_schema_properties(defs[0].input_schema)
  assert_true(props.contains("escalated"))
  assert_true(props.contains("source"))
}

///|
async test "decode accepts minimal args with target default" {
  let tools = MbtxTools()
  let args = tools.decode_args(
    mbtx_args_obj([("source", Json::string("fn main { println(42) }"))]),
  )
  assert_eq(args.source, "fn main { println(42) }")
  assert_eq(args.target, "wasm")
  assert_false(args.escalated)
}

///|
async test "decode accepts every documented target" {
  let tools = MbtxTools()
  for t in ["wasm", "wasm-gc", "js", "llvm"] {
    let args = tools.decode_args(
      mbtx_args_obj([("source", Json::string("s")), ("target", Json::string(t))]),
    )
    assert_eq(args.target, t)
  }
}

///|
async test "decode rejects native target with policy explanation" {
  let tools = MbtxTools()
  let result = Ok(
    tools.decode_args(
      mbtx_args_obj([
        ("source", Json::string("s")),
        ("target", Json::string("native")),
      ]),
    ),
  ) catch {
    e => Err(e)
  }
  match result {
    Err(@posoco.RuntimeError::UnknownTool(msg)) => {
      assert_true(msg.contains("native"))
      assert_true(msg.contains("policy"))
    }
    _ => fail("expected native target rejection")
  }
}

///|
async test "decode rejects unknown target values" {
  let tools = MbtxTools()
  let result = Ok(
    tools.decode_args(
      mbtx_args_obj([
        ("source", Json::string("s")),
        ("target", Json::string("wat")),
      ]),
    ),
  ) catch {
    e => Err(e)
  }
  match result {
    Err(@posoco.RuntimeError::UnknownTool(msg)) =>
      assert_true(msg.contains("must be one of"))
    _ => fail("expected unknown target rejection")
  }
}

///|
async test "decode source is required and must be a non-empty string" {
  let tools = MbtxTools()
  let result = Ok(tools.decode_args(mbtx_args_obj([]))) catch { e => Err(e) }
  match result {
    Err(@posoco.RuntimeError::UnknownTool(msg)) =>
      assert_true(msg.contains("missing 'source'"))
    _ => fail("expected missing source rejection")
  }
  let result = Ok(
    tools.decode_args(mbtx_args_obj([("source", Json::string(""))])),
  ) catch {
    e => Err(e)
  }
  match result {
    Err(@posoco.RuntimeError::UnknownTool(msg)) =>
      assert_true(msg.contains("non-empty"))
    _ => fail("expected empty source rejection")
  }
  let result = Ok(
    tools.decode_args(mbtx_args_obj([("source", Json::number(1.0))])),
  ) catch {
    e => Err(e)
  }
  match result {
    Err(@posoco.RuntimeError::UnknownTool(msg)) =>
      assert_true(msg.contains("'source' must be a string"))
    _ => fail("expected non-string source rejection")
  }
  let result = Ok(tools.decode_args(Json::null())) catch { e => Err(e) }
  match result {
    Err(@posoco.RuntimeError::UnknownTool(msg)) =>
      assert_true(msg.contains("JSON object"))
    _ => fail("expected non-object rejection")
  }
}

///|
async test "decode escalated requires constructor opt-in" {
  let off = MbtxTools()
  let result = Ok(
    off.decode_args(
      mbtx_args_obj([
        ("source", Json::string("s")),
        ("escalated", Json::boolean(true)),
      ]),
    ),
  ) catch {
    e => Err(e)
  }
  match result {
    Err(@posoco.RuntimeError::UnknownTool(msg)) =>
      assert_true(msg.contains("escalated"))
    _ => fail("expected escalated rejection when not configured")
  }
  let on = MbtxTools(escalation=true)
  let args = on.decode_args(
    mbtx_args_obj([
      ("source", Json::string("s")),
      ("escalated", Json::boolean(true)),
    ]),
  )
  assert_true(args.escalated)
  let args = on.decode_args(
    mbtx_args_obj([
      ("source", Json::string("s")),
      ("escalated", Json::boolean(false)),
    ]),
  )
  assert_false(args.escalated)
  let args = off.decode_args(
    mbtx_args_obj([
      ("source", Json::string("s")),
      ("escalated", Json::boolean(false)),
    ]),
  )
  assert_false(args.escalated)
  let result = Ok(
    on.decode_args(
      mbtx_args_obj([
        ("source", Json::string("s")),
        ("escalated", Json::string("yes")),
      ]),
    ),
  ) catch {
    e => Err(e)
  }
  match result {
    Err(@posoco.RuntimeError::UnknownTool(msg)) =>
      assert_true(msg.contains("boolean"))
    _ => fail("expected non-boolean escalated rejection")
  }
}

///|
async test "decode errors surface before the execution pipeline" {
  let tools = MbtxTools()
  let call : @posoco.ToolCall = {
    call_id: @posoco.CallId::unchecked("tc_mbtx_2"),
    name: @posoco.ToolName::unchecked("mbtx"),
    arguments: mbtx_args_obj([
      ("source", Json::string("s")),
      ("target", Json::string("native")),
    ]),
  }
  let result = Ok(tools.execute("mbtx", call)) catch { e => Err(e) }
  match result {
    Err(@posoco.RuntimeError::UnknownTool(msg)) =>
      assert_true(msg.contains("native"))
    _ => fail("expected the decode error, not the stub failure")
  }
}

///|
priv struct ExemptionRecorder {
  events : Array[@devkit.BusEvent]
}

///|
impl @devkit.BusSubscriber for ExemptionRecorder with fn on_bus_event(
  self : ExemptionRecorder,
  event : @devkit.BusEvent,
) -> Unit {
  self.events.push(event)
}

///|
async test "constructor publishes tool_exemptions self-report" {
  let bus = @devkit.EventBus::EventBus()
  let recorder : ExemptionRecorder = { events: [], }
  bus.subscribe(recorder)
  ignore(MbtxTools(bus=Some(bus)))
  assert_eq(recorder.events.length(), 1)
  let event = recorder.events[0]
  assert_eq(event.source, "posoco_ext_mbtx")
  assert_eq(event.topic, "tool_exemptions")
  json_inspect(event.data, content={ "tools": ["mbtx"] })
}

///|
async test "constructor without bus is a no-op" {
  ignore(MbtxTools())
}

///|
async test "description carries charter allowlist substitutions boundary and targets" {
  let desc = MbtxTools().list_tools()[0].description
  assert_true(desc.contains("no shell"))
  assert_true(desc.contains("- moon — any arguments"))
  assert_true(desc.contains("- git — any arguments"))
  assert_true(desc.contains("- gh — any arguments"))
  assert_true(desc.contains("- rg — any arguments"))
  assert_true(desc.contains("- diff — any arguments"))
  assert_true(desc.contains("sh, bash, zsh, fish, python, node, deno"))
  assert_true(desc.contains("xargs"))
  assert_true(desc.contains("not a security perimeter"))
  assert_true(desc.contains("- ls -> @fs.readdir(path)"))
  assert_true(desc.contains("- find -> @shell.glob(pattern)"))
  assert_true(desc.contains("- grep -> MoonBit core regex matching"))
  assert_true(desc.contains("MoonBit itself"))
  assert_true(desc.contains("temporary directory"))
  assert_true(desc.contains("write/edit"))
  assert_true(desc.contains("defaults to wasm"))
  assert_true(desc.contains("native is not available"))
}

///|
async test "description allowlist follows constructor configuration" {
  let desc = MbtxTools(allowlist_without=["git"]).list_tools()[0].description
  assert_false(desc.contains("- git — any arguments"))
  assert_true(desc.contains("- moon — any arguments"))
}

///|
async test "system prompt mirrors allowlist substitutions and offline note" {
  let text = MbtxTools(escalation=true).system_prompt()
  assert_true(text.contains("- moon — any arguments"))
  assert_true(text.contains("- diff — any arguments"))
  assert_true(text.contains("@shell.glob"))
  assert_true(text.contains("moon update"))
  assert_true(text.contains("write/edit"))
}

///|
async test "system prompt is byte-stable across calls" {
  let tools = MbtxTools()
  assert_eq(tools.system_prompt(), tools.system_prompt())
}
