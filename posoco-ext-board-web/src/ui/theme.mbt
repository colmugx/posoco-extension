// RUI bridge for the "Instrument" design system.
//
// RUI ships its own Nova-style inline recipes driven by `--rui-*` custom
// properties, so the only way to keep one visual identity is to hand RUI the
// Instrument palette instead of letting it fall back to its own defaults.
// Every token below points at an existing Instrument variable, which means the
// existing light/dark `prefers-color-scheme` block keeps working unchanged.

///|
/// Browser colour-scheme preference. Node-hosted tests have no `matchMedia`, so
/// a missing or throwing API reports light rather than failing the render.
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
/// RUI token overrides. Kept in one place so a component swap never invents a
/// second colour source; `--rui-primary` is the Instrument accent, not Nova's
/// near-black.
let instrument_tokens : Array[String] = [
  "--rui-radius: 8px",
  "--rui-background: var(--canvas)",
  "--rui-foreground: var(--ink)",
  "--rui-card: var(--surface)",
  "--rui-card-foreground: var(--ink)",
  "--rui-popover: var(--surface)",
  "--rui-popover-foreground: var(--ink)",
  "--rui-primary: var(--accent)",
  "--rui-primary-foreground: #ffffff",
  "--rui-secondary: var(--surface-2)",
  "--rui-secondary-foreground: var(--ink-2)",
  "--rui-muted: var(--surface-2)",
  "--rui-muted-foreground: var(--muted)",
  "--rui-accent: var(--accent-soft)",
  "--rui-accent-foreground: var(--accent)",
  "--rui-destructive: var(--danger)",
  "--rui-destructive-subtle: var(--danger-soft)",
  "--rui-border: var(--line)",
  "--rui-input: var(--line-strong)",
  "--rui-input-background: var(--surface)",
  "--rui-outline-background: var(--surface)",
  "--rui-outline-border: var(--line-strong)",
  "--rui-outline-hover-bg: var(--surface-2)",
  "--rui-ghost-hover-bg: var(--surface-2)",
  "--rui-ring: var(--accent)",
  "--rui-select-hover-bg: var(--surface-2)",
  "--rui-tabs-active-bg: var(--surface)",
  "--rui-tabs-active-border: transparent",
  // RUI's own root recipe asks for Inter first; the shell is rendered for
  // CJK-heavy board titles, so the Instrument stack must win. RUI appends
  // caller styles last, which is what makes this override safe.
  "font-family: var(--font-sans)",
]

///|
/// One `@rui.theme` root. RUI needs it once: the component emits the shared
/// hover/focus/motion stylesheet and the token scope every RUI component reads.
/// The wrapper adds no box of its own, so the `100dvh` app shell keeps sizing
/// the viewport exactly as before.
pub fn theme_root(children : @html.Html) -> @html.Html {
  @rui.theme(
    mode=rui_mode(),
    style=instrument_tokens,
    [children],
  )
}
