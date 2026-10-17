# posoco-ext-fs-session

A [Posoco](https://mooncakes.io/docs/colmugx/posoco) `SessionStore` that
persists sessions as deterministic JSONL files — one `<session-id>.jsonl`
per session under a root directory.

## Ports contributed

| Port | Contribution |
|------|--------------|
| `SessionStore` | `load` / `save` / `append_messages`, async, raising typed `SessionError` values |
| `Extension` | composes into `Agent(exts=[...])` as a session extension |

## Usage

```bash
moon add colmugx/posoco-ext-fs-session
```

```moonbit nocheck
// moon.pkg: "colmugx/posoco-ext-fs-session" @fs_session

///|
let store = @fs_session.JsonlSessionStore(home + "/.cetas/sessions")

///|
let agent = @posoco.Agent(exts=[store, ..other_extensions], config~)
```

## File format

The first line is the session metadata object; every following line is one
message. Output always ends with `\n`, so a full rewrite is a single write
call. Image content is written with kernel field names (`media_type`/`data`);
the reader also accepts the legacy `url`/`mime` shape so older files keep
loading.

## Target contract

- **Native** implements the store with `moonbitlang/x/fs`.
- **Bun/js** implements the same trait directly with Promise-based filesystem
  APIs (`Bun.file` / `Bun.write` for load and full writes — writes
  auto-create parent directories — and `fs.promises.appendFile` for
  `append_messages` on an existing file).

Both targets return an empty session when the requested file does not exist.
Filesystem and codec failures remain observable as typed `SessionError`
values.

## Listing sessions

`JsonlSessionStore::list_ids()` (inherent method, both targets) returns every
persisted session id: the stems of the `<id>.jsonl` entries in the root,
re-checked by `validate_session_id`, deduplicated, and sorted
character-lexicographically — clock-minted ids (`cetas-<ms>`) therefore sort
chronologically. A missing root directory is an empty list, the same
missing-means-empty rule `load` applies; entries that are not `<id>.jsonl`
files or whose stem fails validation are ignored.

## Session titles

`JsonlSessionStore::summary()` exposes host-facing session presentation
metadata. Explicit `metadata["name"]` wins; otherwise new sessions use
Posoco's stable `metadata[@posoco.SESSION_TITLE_METADATA_KEY]` value, derived
from the first admitted caller input before memory or hook injection. Journals
created before that metadata key existed retain a compatibility-only fallback
to their first user-role message. Hosts should consume `display_title()`
instead of inferring human provenance from transcript roles.

## Versioned model selection through a neutral control

Hosts may inject `selection_control : &ModelManagerControl` when constructing
`JsonlSessionStore`. At each save or append, the store snapshots
`active_selection` and `manager_id` **through that interface**, writes
owner-qualified `posoco.model_selection_v2`, and increments its local revision
only when the logical selection changes. The store never inspects a concrete
manager type, provider name, model ID syntax, or upstream routing decision.

The v2 owner is required during restoration: `selection_for_owner` refuses
a mismatched owner even when the model ID happens to match. Existing legacy
sessions remain readable. The historical bus-only recording path is retained
for hosts that do not inject a control. An optional manual
`observe_selection_v2` injection remains supported for existing callers.

The append fast path also tracks the **journal ID**, not merely the last
model value. A failed metadata rewrite remains pending for a later attempt;
no session's model record is assumed to match a different journal.

## Model selection record

When the store is composed with the shared `EventBus`, it subscribes to the
ext-llm router's `model_selection` events and records the active slot id and
explicit reasoning effort into the metadata line under
`posoco.model_selection` (shape `{"slot_id": ..., "effort": ... | null}`).
The record reflects the selection at the moment of the last persist — the
model that produced the transcript's tail — so a switch that is never
followed by a persist is not recorded. Stores composed without a bus never
observe anything and never decorate, leaving legacy journals untouched.
`summary()` projects the record as `model`/`effort` fields, and
`model_selection_from_metadata()` reads it from an already-loaded session;
hosts use these to restore the session's model on resume.

## Behavior

- **Session ids are filename stems** — validated at the storage boundary
  (`validate_session_id`): non-empty, no path separators, no `.`/`..`, so a
  caller cannot escape the root directory.
- **`save`** rewrites the whole file; the root directory is created lazily
  and must be a directory if it already exists.
- **`append_messages`** appends only the new message lines to an existing
  file; on first persistence for an id it writes a full JSONL file instead,
  so the first append behaves like a save.
- Malformed complete message lines abort the load loudly (`SessionError::Load`).
  A malformed final physical line is ignored only when the file does not end
  in `\n`, recovering the last complete checkpoint after a process dies
  during an append.
