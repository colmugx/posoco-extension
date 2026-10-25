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
/// Wall-clock milliseconds for the relative labels on worker updates. Only the
/// views read it; a host without `Date` degrades to the epoch instead of
/// failing the render.
extern "js" fn browser_now_ms() -> Double =
  #|() => {
  #|  try { return Date.now(); } catch (_) { return 0; }
  #|}

///|
fn board_now_ms() -> Int64 {
  browser_now_ms().to_int64()
}

///|
fn connect(
  url : String,
  generation : Int32,
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
  generation : Int32,
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
        // Opening a layer is a DOM effect, so the keyboard path shows the
        // dialog here and lets update own the state.
        install_menu_dismiss()
        install_focus_return()
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
      // Window-level keyboard shortcuts ride a Rabbita subscription: the
      // document keydown listener is installed once and its emitted Cmds run
      // on the scheduler, so every message reaches the update loop.
      subscriptions=(_model, emit) => {
        @sub.on_key_down(key => {
          if keyboard_in_text_entry() ||
            keyboard_dialog_open() ||
            key.is_composing() {
            @rabbita.none
          } else {
            match key.key() {
              "n" | "N" => {
                ui_show("create-dialog")
                emit(CreateOpened)
              }
              "/" => {
                ui_focus("#board-search")
                @rabbita.none
              }
              "j" | "J" => emit(KeyboardMove(1))
              "k" | "K" => emit(KeyboardMove(-1))
              "Enter" =>
                if keyboard_selection_open() {
                  ui_show("detail-dialog")
                  @rabbita.none
                } else {
                  @rabbita.none
                }
              _ => @rabbita.none
            }
          }
        })
      },
    )
    model.view(model => view(model, emit))
  })
}
