// Component colors inherit the application palette in both color schemes.

///|
/// Missing browser color preferences default to the light scheme.
extern "js" fn prefers_dark_scheme() -> Bool =
  #|() => {
  #|  try {
  #|    return typeof window !== "undefined" &&
  #|      typeof window.matchMedia === "function" &&
  #|      window.matchMedia("(prefers-color-scheme: dark)").matches;
  #|  } catch (_) {
  #|    return false;
  #|  }
  #|}

///|
pub fn rui_mode() -> @rui.ColorMode {
  if prefers_dark_scheme() {
    @rui.ColorMode::Dark
  } else {
    @rui.ColorMode::Light
  }
}

///|
/// Components must not introduce a second color palette.
let instrument_tokens : Array[String] = [
  "--rui-radius: 8px", "--rui-background: var(--canvas)", "--rui-foreground: var(--ink)",
  "--rui-card: var(--surface)", "--rui-card-foreground: var(--ink)", "--rui-popover: var(--surface)",
  "--rui-popover-foreground: var(--ink)", "--rui-primary: var(--accent)", "--rui-primary-foreground: #ffffff",
  "--rui-secondary: var(--surface-2)", "--rui-secondary-foreground: var(--ink-2)",
  "--rui-muted: var(--surface-2)", "--rui-muted-foreground: var(--muted)", "--rui-accent: var(--accent-soft)",
  "--rui-accent-foreground: var(--accent)", "--rui-destructive: var(--danger)", "--rui-destructive-subtle: var(--danger-soft)",
  "--rui-border: var(--line)", "--rui-input: var(--line-strong)", "--rui-input-background: var(--surface)",
  "--rui-outline-background: var(--surface)", "--rui-outline-border: var(--line-strong)",
  "--rui-outline-hover-bg: var(--surface-2)", "--rui-ghost-hover-bg: var(--surface-2)",
  "--rui-ring: var(--accent)", "--rui-select-hover-bg: var(--surface-2)", "--rui-tabs-active-bg: var(--surface)",
  "--rui-tabs-active-border: transparent",
  // The application font stack must win for multilingual content.
   "font-family: var(--font-sans)",
]

///|
/// Share interactive styles and token scope without changing viewport geometry.
pub fn theme_root(children : @html.Html) -> @html.Html {
  @rui.theme(mode=rui_mode(), style=instrument_tokens, [children])
}
