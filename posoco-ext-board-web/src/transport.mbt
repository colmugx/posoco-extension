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
pub fn app() -> @rabbita.App {
  let url = location_socket_url()
  @rabbita.new(() => {
    let (model, _) = @rabbita.create_state_with_init(
      init=emit => {
        let model = Model::empty(url != "")
        (model, if url == "" { @rabbita.none } else { connect(url, 0, emit) })
      },
      update=(model, msg, emit) => update(model, msg, emit, url),
    )
    model.view(view)
  })
}
