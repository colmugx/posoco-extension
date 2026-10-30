///|
fn view(model : Model, emit : @rabbita.Emit[Msg]) -> @html.Html {
  @ui.theme_root(@html.main_(class="app", [
    topbar(model, emit),
    toolbar(model, emit),
    connection_banner(model, emit),
    @html.div(class="workspace", [board(model, emit)]),
    editor_dialog(model, emit),
    detail_dialog(model, emit),
    inbox_dialog(model, emit),
    ticket_activity_dialog(model, emit),
    archive_dialog(model, emit),
    live_dialog(model, emit),
    team_dialog(model, emit),
    confirm_dialog(model, emit),
    notice_toast(model.notice, emit),
  ]))
}
