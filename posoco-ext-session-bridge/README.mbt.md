# Posoco Session Bridge

This is an optional, host-neutral **Session observer contract** for Posoco multi-surface clients. It is **not** Cetas Malphite, which is reserved for optional remote relay. Go, Bun/JS and Web surfaces use the same Session/Owner semantics.

It reduces existing EventHub frames to the only state needed to safely join a live Session: `runtime_epoch`, per-session `cursor`, and the authoritative `working` flag. It does **not** instantiate an Agent, read/write a journal, handle approvals, elect an owner, create a daemon, or transport messages.

A host-specific local transport must:
- Resolve the Session's **existing writer** before allowing a writable attach. Failure to find an owner cannot make that Session writable in another process.
- Authenticate same-user peers using Unix peer credentials/private socket directory or Windows named-pipe ACLs. No TCP or Malphite.
- Subscribe to EventHub **before** taking its snapshot to avoid a hole; deliver the snapshot before buffered live events.
- Retain EventHub frames unchanged, apply the reducer, and force fresh owner snapshot on cursor gaps, event overflow, or epoch change.
- Route any mutations to the existing Owner, with operation IDs and owner-side authorization; never replay an accepted-but-unacknowledged request.
- Keep unrelated local Cetas Sessions working when IPC is absent or fails.

## Required real-process acceptance

These are integration acceptance cases, **not claims this domain module alone passes them**:

1. Go owner working in Session S; second Go `/session` S sees `working` immediately and live output.
2. Go owner; Bun/JS observer joins S and sees the same live state/output.
3. Two Go surfaces attached to S: a turn started in one marks both working and streams the same events.
4. Bun/JS owner; Go observer joins S and sees the same live state/output.

The implementation boundary is deliberate: `posoco/ext-session-bridge` owns the model-independent replica and continuity rules; Go/Bun OS transports and UI routing remain thin host adapters. Existing Cetas EventHub and Posoco Agent remain the only event/authority sources. This code does not provide IPC on its own.
