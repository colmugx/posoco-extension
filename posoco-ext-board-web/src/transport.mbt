///|
/// Rabbita has no location accessor. This helper only reads location and uses
/// browser URL parsing; tokens never enter storage, rendered output or logs.
extern "js" fn location_socket_url() -> String =
  #|() => {
  #|  const { protocol, host, search } = window.location;
  #|  const token = new URLSearchParams(search).get("token");
  #|  if (!token || !host || (protocol !== "http:" && protocol !== "https:")) return "";
  #|  return (protocol === "https:" ? "wss:" : "ws:") + "//" + host + "/ws?token=" + encodeURIComponent(token);
  #|}

///|
/// Browser `crypto.randomUUID`. Returns the empty string when the API is
/// missing or throws; `browser_uuid` maps that to `None` so the app never
/// fabricates a weak fallback identifier.
extern "js" fn browser_random_uuid() -> String =
  #|() => {
  #|  try {
  #|    if (typeof crypto === "undefined" || typeof crypto.randomUUID !== "function") return "";
  #|    return crypto.randomUUID();
  #|  } catch (_) {
  #|    return "";
  #|  }
  #|}

///|
fn browser_uuid() -> String? {
  let uuid = browser_random_uuid()
  if uuid == "" {
    None
  } else {
    Some(uuid)
  }
}

///|
fn connect(
  url : String,
  generation : Int,
  emit : @rabbita.Emit[Msg],
) -> @rabbita.Cmd {
  @websocket.connect(
    "board",
    url,
    on_event=event => emit(SocketEvent(generation, event)),
    failed=_ => emit(TransportFailed(generation)),
  )
}

///|
fn hello_payload(replica : @client.BoardReplica) -> String {
  @protocol.encode_client_frame(Hello(replica.hello()))
}

///|
/// Pure frame encoding for one command, kept separate so tests can pin the
/// exact wire payload.
fn command_payload(command : @protocol.BoardClientCommand) -> String {
  @protocol.encode_client_frame(Command(command))
}

///|
/// Send one encoded command on the `board` socket. The failure callback
/// correlates both the connection generation and the command id, so a late
/// failure can never clear a newer pending command.
fn send_command(
  generation : Int,
  command : @protocol.BoardClientCommand,
  emit : @rabbita.Emit[Msg],
) -> @rabbita.Cmd {
  @websocket.send("board", Text(command_payload(command)), failed=_ => {
    emit(SendFailed(generation, command.command_id))
  })
}

///|
/// Mount this browser-only application with Rabbita's `mount` entry point.
/// The compiled `cmd/browser` entry demonstrates the DOM-dependent setup.
pub fn app() -> @rabbita.App {
  let env : Env = { url: location_socket_url(), uuid: browser_uuid, }
  @rabbita.new(() => {
    let (model, emit) = @rabbita.create_state_with_init(
      init=emit => {
        let model = Model::empty(env.url != "")
        (
          model,
          if env.url == "" {
            @rabbita.none
          } else {
            connect(env.url, 0, emit)
          },
        )
      },
      update=(model, msg, emit) => update(model, msg, emit, env),
    )
    model.view(model => view(model, emit))
  })
}
