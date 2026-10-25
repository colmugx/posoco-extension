// DOM-only helpers. Layers are native <dialog> elements, so the browser owns
// the top layer, focus trapping and Esc. Every call here happens inside a DOM
// event handler; `update` never touches the document.

///|
/// Show one dialog and move focus to the element marked `data-autofocus`.
extern "js" fn ui_show(id : String) -> Unit =
  #|(id) => {
  #|  const dialog = document.getElementById(id);
  #|  if (!dialog) return;
  #|  if (!dialog.open) {
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

///|
/// One window-level key listener. It reports only keys that are unambiguous
/// outside text entry; open dialogs keep their native Esc and consume keys.
extern "js" fn install_shortcuts(on_key : (String) -> Unit) -> Unit =
  #|(onKey) => {
  #|  if (window.__boardShortcuts) return;
  #|  window.__boardShortcuts = true;
  #|  window.addEventListener("keydown", (event) => {
  #|    if (event.defaultPrevented || event.metaKey || event.ctrlKey || event.altKey) return;
  #|    if (document.querySelector("dialog[open]")) return;
  #|    const target = event.target;
  #|    const typing = Boolean(target) && (target.isContentEditable ||
  #|      ["INPUT", "TEXTAREA", "SELECT"].includes(target.tagName));
  #|    if (typing) return;
  #|    if (event.key === "n" || event.key === "N") {
  #|      event.preventDefault();
  #|      onKey("new-task");
  #|    } else if (event.key === "/") {
  #|      event.preventDefault();
  #|      onKey("search");
  #|    }
  #|  }, true);
  #|}
