// DOM-only helpers. Layers are native <dialog> elements, so the browser owns
// the top layer, focus trapping and Esc. Every call here happens inside a DOM
// event handler; `update` never touches the document.

///|
/// Show one dialog and move focus to the element marked `data-autofocus`.
/// The previously focused element is remembered on the dialog so the close
/// listener can hand focus back to the trigger.
extern "js" fn ui_show(id : String) -> Unit =
  #|(id) => {
  #|  const dialog = document.getElementById(id);
  #|  if (!dialog) return;
  #|  if (!dialog.open) {
  #|    dialog.__boardReturn = document.activeElement;
  #|    try { dialog.showModal(); } catch (_) { dialog.setAttribute("open", ""); }
  #|  }
  #|  requestAnimationFrame(() => {
  #|    const target = dialog.querySelector("[data-autofocus]") || dialog;
  #|    if (target && target.focus) target.focus();
  #|  });
  #|}

///|
/// Close one dialog. The element's `close` event settles the model, so this
/// helper never emits on its own.
extern "js" fn ui_close(id : String) -> Unit =
  #|(id) => {
  #|  const dialog = document.getElementById(id);
  #|  if (dialog && dialog.open) dialog.close();
  #|}

///|
extern "js" fn ui_focus(selector : String) -> Unit =
  #|(selector) => {
  #|  const element = document.querySelector(selector);
  #|  if (element && element.focus) element.focus();
  #|}

///|
/// True while the keyboard focus sits in a text entry control, so window
/// shortcuts must stand down.
extern "js" fn keyboard_in_text_entry() -> Bool =
  #|() => {
  #|  const target = document.activeElement;
  #|  return Boolean(target) && (target.isContentEditable ||
  #|    ["INPUT", "TEXTAREA", "SELECT"].includes(target.tagName));
  #|}

///|
extern "js" fn keyboard_dialog_open() -> Bool =
  #|() => Boolean(document.querySelector("dialog[open]"))

///|
/// Focus the selected card's title and report whether there is one. Focusing
/// before the sheet opens hands the close-time focus return the right target.
extern "js" fn keyboard_selection_open() -> Bool =
  #|() => {
  #|  const title = document.querySelector(".card.is-selected .card-title");
  #|  if (title && typeof title.focus === "function") {
  #|    title.focus();
  #|    return true;
  #|  }
  #|  return false;
  #|}

///|
/// When any dialog closes — button, Esc or programmatic — focus goes back to
/// the element that opened it. The `close` event does not bubble, so this
/// listens in the capture phase.
extern "js" fn install_focus_return() -> Unit =
  #|() => {
  #|  if (window.__boardFocusReturn) return;
  #|  window.__boardFocusReturn = true;
  #|  document.addEventListener("close", (event) => {
  #|    const dialog = event.target;
  #|    const back = dialog && dialog.__boardReturn;
  #|    if (back && typeof back.focus === "function") back.focus();
  #|    dialog.__boardReturn = null;
  #|  }, true);
  #|}

///|
/// Close an open card menu when the click lands outside it, or after one of
/// its menu items was chosen. The menu itself is a native <details>, so this
/// only removes the open attribute; the button semantics stay unchanged.
extern "js" fn install_menu_dismiss() -> Unit =
  #|() => {
  #|  if (window.__boardMenuDismiss) return;
  #|  window.__boardMenuDismiss = true;
  #|  document.addEventListener("click", (event) => {
  #|    const target = event.target;
  #|    for (const menu of document.querySelectorAll("details.card-menu[open]")) {
  #|      const item = target && target.closest ? target.closest(".menu-item") : null;
  #|      if (!menu.contains(target) || (item && menu.contains(item))) {
  #|        menu.removeAttribute("open");
  #|      }
  #|    }
  #|  }, true);
  #|}
