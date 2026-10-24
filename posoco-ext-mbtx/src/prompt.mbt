///|
/// Compact MoonBit primer for guest scripts, distilled from the working
/// guide and from real failed run_code sessions: the rules that decide
/// whether a submitted snippet compiles at all. Bunraku's system prompt
/// appends this; the extension's own manifest contributes it when composed
/// standalone.
pub fn syntax_primer() -> String {
  (
    #|## MoonBit and mbtx basics
    #|A .mbtx script is a whole program: an `import { "module@version" @alias, ... }` block, then code including `async fn main`.
    #|run_code's `code` is only the handler body: statements over `ctx` and `input`, and the last expression is the returned Json. No imports, no signature, no main, no semicolons.
    #|
    #|## Variables and operations
    #|Statements never end with `;`, and `if` / `for` take no parentheses: `if cond { ... } else { ... }`, `for name in names { ... }`.
    #|Bind with `let`; rebind with `let mut` (there is no `var`). Annotate when it clarifies: `let out : Array[Json] = []`.
    #|Arrays append with `xs.push(v)` — `+=` does not exist. Strings join with `+` and interpolate "\{expr}": plain "{name}" is literal text.
    #|Build text with `let buf = StringBuilder()`, `buf.write_string(s)`, then `buf.to_string()`.
    #|Build JSON with literals (`{ "key": value }`); a function's last expression is its return value, and it must be Json here.
    #|Errors are checked: `async fn` raises by default; `fail("message")` aborts with a message; handle at real boundaries with `catch`.
    #|
    #|## A complete handler
    #|let names = ["read", "glob"]
    #|let buf = StringBuilder()
    #|for name in names {
    #|  let r = ctx.call(name, {})
    #|  match r {
    #|    { "error": _, "content": message, .. } => buf.write_string("\{name} ERR \{message}\n")
    #|    value => buf.write_string("\{name} OK \{value.stringify()}\n")
    #|  }
    #|}
    #|{ "out": buf.to_string() }
    #|
    #|`ctx.call` returns Json: the success value, or {"error": code, "content": message} on failure — pattern-match it; there are no `.is_error` / `.value` fields.
    #|Async is contagious: helpers doing IO are `async fn`; there is no `await`. Import every package used by its real path (`moonbitlang/core/json` as `@json`); never import `moonbitlang/core` itself.
  )
}

///|
pub impl @posoco.SystemPromptContributor for MbtxExtension with fn system_prompt(
  _self : MbtxExtension,
) -> String {
  syntax_primer()
}

///|
pub extend MbtxExtension with @posoco.SystemPromptContributor::{system_prompt}
