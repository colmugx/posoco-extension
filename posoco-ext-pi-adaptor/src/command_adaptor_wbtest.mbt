///|
/// Whitebox helper: register a pi command whose handler captures its args and
/// context, then returns `feedback` (or throws when feedback is "__throw__").
extern "js" fn wbtest_register_pi_command(
  host : JsPiHost,
  name : String,
  description : String,
  feedback : String,
  capture : (String) -> Unit,
) -> Unit =
  #| (host, name, description, feedback, capture) => {
  #|   host.state.commands.push({
  #|     name, description,
  #|     handler: async (args, ctx) => {
  #|       capture(JSON.stringify({ args, cwd: ctx.cwd }));
  #|       if (feedback === "__throw__") throw new Error("command exploded");
  #|       return feedback;
  #|     },
  #|   });
  #| }

///|
extern "js" fn wbtest_register_pi_shortcut(
  host : JsPiHost,
  key : String,
  description : String,
  capture : (String) -> Unit,
) -> Unit =
  #| (host, key, description, capture) => {
  #|   host.state.shortcuts.push({
  #|     key, description,
  #|     handler: async (ctx) => { capture(JSON.stringify({ cwd: ctx.cwd })) },
  #|   });
  #| }

///|
test "pi command surface projects onto the pi: namespace" {
  let adaptor = pi_adaptor_new()
  wbtest_register_pi_command(
    adaptor.host,
    "deploy",
    "Deploy the workspace",
    "deployed",
    fn(_captured) { () },
  )
  let port : &@posoco.CommandPort = adaptor.commands as &@posoco.CommandPort
  let defs = port.commands()
  inspect(defs.length(), content="1")
  let def = defs[0]
  inspect(def.id, content="pi:deploy")
  inspect(def.label, content="deploy")
  inspect(def.description, content="Deploy the workspace")
  inspect(def.category, content="pi")
  inspect(def.ctype is @posoco.CommandType::Action, content="true")
  inspect(def.visible, content="true")
  inspect(def.shortcut is None, content="true")
}

///|
test "pi shortcuts project as invisible shortcut-only defs" {
  let adaptor = pi_adaptor_new()
  wbtest_register_pi_shortcut(
    adaptor.host,
    "ctrl+shift+f9",
    "Fixture shortcut",
    fn(_captured) { () },
  )
  let port : &@posoco.CommandPort = adaptor.commands as &@posoco.CommandPort
  let defs = port.commands()
  inspect(defs.length(), content="1")
  let def = defs[0]
  inspect(def.id, content="pi:#ctrl+shift+f9")
  inspect(def.shortcut is Some("ctrl+shift+f9"), content="true")
  inspect(def.visible, content="false")
  inspect(def.description, content="Fixture shortcut")
}

///|
async test "pi invoke normalizes handler results into CommandOutcome" {
  let adaptor = pi_adaptor_new()
  let captured : Array[String] = []
  wbtest_register_pi_command(adaptor.host, "ping", "echoes args", "pong", fn(
    line : String,
  ) {
    captured.push(line)
  })
  let port : &@posoco.CommandPort = adaptor.commands as &@posoco.CommandPort
  // Handler feedback rides Success.feedback; args pass through as the
  // positional string; ctx is the shared makeContext.
  let ok = port.invoke(
    "pi:ping",
    Json::object(Map::from_array([("_positional", Json::string("prod"))])),
  )
  inspect(ok is @posoco.CommandOutcome::Success(..), content="true")
  let feedback = match ok {
    @posoco.CommandOutcome::Success(feedback~, ..) => feedback
    _ => fail("expected Success")
  }
  inspect(feedback, content="pong")
  inspect(captured.length(), content="1")
  inspect(
    captured[0].contains("\"args\":\"prod\"") &&
    captured[0].contains("\"cwd\":"),
    content="true",
  )
  // Unknown names, throwing handlers, and non-pi ids all degrade to Failure.
  let missing = port.invoke("pi:missing", Json::object(Map::from_array([])))
  inspect(missing is @posoco.CommandOutcome::Failure(..), content="true")
  wbtest_register_pi_command(adaptor.host, "boom", "throws", "__throw__", fn(
    _captured,
  ) {
    ()
  })
  let failed = port.invoke("pi:boom", Json::object(Map::from_array([])))
  match failed {
    @posoco.CommandOutcome::Failure(reason~) =>
      inspect(reason, content="command exploded")
    _ => fail("expected Failure")
  }
  let foreign = port.invoke("deploy", Json::object(Map::from_array([])))
  inspect(foreign is @posoco.CommandOutcome::Failure(..), content="true")
}

///|
test "manifest contributes the command port" {
  let adaptor = pi_extension()
  inspect(adaptor.manifest().commands.length(), content="1")
}
