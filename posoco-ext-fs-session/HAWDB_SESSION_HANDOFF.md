# HawDB SessionStore — B-stage integration gate

This branch contains the first prerequisite for a durable Posoco HawDB
SessionStore: lossless canonical Message serialization. The existing
`jsonl_session_serde.mbt` writes compatibility JSONL fields and an additional
version-2 `outcome_v2` envelope retaining the full kernel ToolOutcome ADT
including structured JSON and NotExecuted reason. It also retains
`FinishReason::Other("stop")` as distinct from `FinishReason::Stop`.

A malformed version-2 envelope fails a load rather than silently replacing
the original meaning with human-readable summary text.

A focused native check is in `.github/workflows/hawdb-session-codec.yml`.
It is separate from the existing repository-wide workflow, which currently
fails before MoonBit checks on an unrelated board-web missing npm lockfile.

**Not yet implemented:** `posoco-ext-session-hawdb`, async SessionStore trait,
atomic checkpoint, revision conflict strategy, durable process-restart
qualification, cross-platform tests, or a published extension.

## B0–B5 completion gates

B0: Create an independent MoonBit module that consumes current HawDB SDK and
Posoco SessionStore; compile against real dependencies on native.

B1: Verify complete lossless serialization for every canonical Message,
ToolOutcome, reasoning replay payload and non-BMP Unicode. Corrupted version
headers and partial messages must error, not silently clear state.

B2: Persist transcript tail and metadata replacement in **one** HawDB write
transaction; metadata `None` must keep the old metadata unchanged and the
logical from_index must not be confused with physical message count.

B3: Native append/truncate should avoid full-session rewrites, with specified
retries, cursor conflicts, and truncation clamping.

B4: Same Posoco contract suite against fs-session and HawDB implementation,
including crash/restart, two writers, multiple sessions, and bad JSON.

B5: Agent replay/compression/recovery drill and reproducible measurements.
No production claim until these gates pass.
