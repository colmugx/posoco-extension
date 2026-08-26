# colmugx/posoco-devkit

Small helper layer for Posoco extension authors.

Core Posoco does not depend on this package. Extension authors can depend on it
for shared diagnostics helpers, gate classifiers, and cross-extension plumbing
instead of re-implementing them per extension.

## Logging context

`ExtContext` carries one `&Logger` through extension code. `NoopLogger` is the
default; `MemoryLogger` records events for tests. Devkit defines only the
trait and these two in-memory sinks — it binds no output backend, so hosts
stay free to wire logging (or omit it) at the product layer.

```moonbit
let logger = MemoryLogger()
let ctx = ExtContext(logger)
ctx.warn(source="my-ext", code="my.warn", message="something happened")
```

## Cross-extension event bus

`EventBus` is the product-level pub/sub channel: the host constructs one bus
and hands it to every extension that wants to publish or subscribe (`BusEvent`
carries `source`/`topic`/`data`). Publishing is fire-and-forget, dispatch is
synchronous and ordered, reentrant publishes queue behind the in-flight batch,
and a subscription registered mid-batch starts receiving with the next batch.

```moonbit
let bus = EventBus::EventBus()
bus.publish({ source: "posoco_ext_scrum", topic: "status", data: Json::null() })
```

## Read-before-modify freshness

`FreshnessGuard` is the ledger shared by the read/write/edit tool extensions:
reads record a `FileStamp` (mtime + size), and write/edit compare a fresh stat
against it so a write never silently clobbers content that changed since the
last read. Verdicts are `Fresh` / `NeverRead` / `Modified`, with
`freshness_hint` providing the plain-language error text.

```moonbit
let ledger = FreshnessGuard::FreshnessGuard()
ledger.note_read("/a.txt", stamp)
inspect(ledger.check("/a.txt", Some(stamp)), content="Fresh")
```

## Diagnostics sanitization

`sanitize_path` / `sanitize_label` keep user-controlled paths and names
bounded and single-line in tool error messages: truncation with a trailing
`...`, and every control character (newline, tab, escape sequence, DEL) is
replaced with a space so diagnostics cannot forge terminal output.

## Read-only shell classification

`shell_command_is_read_only(cmd)` is the conservative read-only shell
classifier used by posoco-ext-plan (and available to permission-style
extensions) — `ls -la` / `git status` / `grep … | head` classify as read-only,
while `rm`, redirects, and command substitution do not. It is a convenience
gate, not a security boundary; enforce with a permission layer.

```moonbit
assert_true(shell_command_is_read_only("git status && git diff --stat"))
assert_false(shell_command_is_read_only("cat a > b"))
```

## Context prompt envelopes

`render_context_envelope` builds one
`<{ns}-context type="…" trust="…" source="…">…</{ns}-context>` element with
XML-escaping of `source` and `content` — the same builder posoco-ext-context's
`ContextPromptContributor` uses, available to any host that assembles context
prompts. `ns` is the host's bare namespace (`"cetas"` renders `cetas-context`
elements); the `-context` suffix is appended by the builder.
