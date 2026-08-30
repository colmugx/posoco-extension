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

## Behavior

- **Session ids are filename stems** — validated at the storage boundary
  (`validate_session_id`): non-empty, no path separators, no `.`/`..`, so a
  caller cannot escape the root directory.
- **`save`** rewrites the whole file; the root directory is created lazily
  and must be a directory if it already exists.
- **`append_messages`** appends only the new message lines to an existing
  file; on first persistence for an id it writes a full JSONL file instead,
  so the first append behaves like a save.
- Malformed message lines abort the load loudly (`SessionError::Load`) rather
  than being skipped.
