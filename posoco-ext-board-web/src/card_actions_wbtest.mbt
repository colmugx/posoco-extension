///|
// Exercise the callback used by card action buttons without mounting a DOM.
// Restore the Node-only MouseEvent shim before the test returns.
extern "js" fn with_click_event(check : (@dom.Event) -> Unit) -> Unit =
  #|(check) => {
  #|  const previous = globalThis.MouseEvent;
  #|  if (typeof previous === "undefined") {
  #|    globalThis.MouseEvent = class MouseEvent {
  #|      constructor() { this.cancelBubble = false; }
  #|      stopPropagation() { this.cancelBubble = true; }
  #|    };
  #|  }
  #|  try { check(new MouseEvent("click", { bubbles: true })); }
  #|  finally { if (typeof previous === "undefined") delete globalThis.MouseEvent; }
  #|}

///|
extern "js" fn click_stopped(event : @dom.Event) -> Bool = "(event) => event.cancelBubble"

///|
test "card action callback stops propagation before emitting Edit or Move" {
  let messages : Array[Msg] = []
  for action in [EditOpened("t"), MoveRequested("t", Running)] {
    with_click_event(event => {
      let emit : @rabbita.Emit[Msg] = msg => {
        if !click_stopped(event) {
          abort("card click must stop before emit")
        }
        messages.push(msg)
        @rabbita.none
      }
      ignore(card_action_click(event.to_mouse_event().unwrap(), action, emit))
      if !click_stopped(event) {
        messages.push(TaskSelected("t"))
      }
    })
  }
  assert_eq(messages.length(), 2)
  assert_true(messages[0] is EditOpened("t"))
  assert_true(messages[1] is MoveRequested("t", Running))
  assert_false(messages.any(msg => msg is TaskSelected(_)))
}
