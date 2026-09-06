# posoco-ext-todo

A TodoWrite-style task list extension for Posoco. The model maintains a
structured checklist through `todo_write` / `todo_read`; hosts learn about
the list through `UiPort::render` intents, and users can inspect it with
the `/todo` command.

## Shape

One struct (`TodoList`), several port views:

| Port | Contribution |
| --- | --- |
| `ToolProvider` | `todo_write` (full-replacement write with validation), `todo_read` |
| `CommandPort` | `/todo` — show the current list (pure read) |
| `SystemPromptContributor` | byte-stable usage guidance |
| `Lifecycle` | stores the composed UI delivered at `on_compose` |
| `Extension` | self-reporting manifest |

The extension **consumes** the composed UI (`requires: [Capability::Ui]`);
its manifest `ui` slot stays empty on purpose. Every accepted write pushes
one render intent — `UiSlot::Widget`, key `"todo"`, `UiBody::Lines` — and
the host decides whether and where to mount it. Hosts without any UI
backend compose `NoopUiPort`, so the pushes are silent no-ops.

## Tool contract

`todo_write` takes `{ todos: [{ content, status: pending | in_progress |
completed }] }` and validates: non-empty content, the status enum, a
50-entry limit (`MAX_TODOS`), and at most one `in_progress` task. Every
call replaces the whole list (empty array clears it). Validation failures
return to the model as `ToolReportedError` — correctable, the turn
continues. Successful results carry the rendered checklist as text and a
structured payload (`summary`, `revision`, counts, `items`).

## Usage

```mbt nocheck
let todos = TodoList::TodoList()
let agent = @posoco.Agent(exts=[todos], config=...)
```

State is in-process and session-scoped with a monotonic revision counter;
restarting the process starts from an empty list. File persistence is
deliberately left to a later milestone.
