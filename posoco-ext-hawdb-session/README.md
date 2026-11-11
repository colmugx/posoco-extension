# posoco-ext-hawdb-session (native development module)

Stage B0/B2 transactional correctness baseline built on the unpublished
HawDB MoonBit SDK and Posoco's `SessionStore` trait.

This module **is not yet a production SessionStore**. Its initial schema stores
one canonical JSONL document per session. All checkpoint changes (message tail
and optional metadata replacement) occur in the same write transaction.
`from_index` is a caller logical cursor, not enforced as physical row count.

The module depends on a rolling local checkout of
`colmugx/hawdb` at `_hawdb_checkout` when checked in CI. The linked
Rust static library must be rebuilt from that checkout for native consumers.
No HawDB engine version is pinned.

Follow-up requirements: replace full-document rewrites with incremental
ordered rows, formalize concurrent writer conflicts/idempotency and crash
injection, test complete lossy/corrupt payload handling, and qualify
Linux/macOS/Windows before publication.
