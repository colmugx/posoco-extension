# Board architecture

The three board projects are primarily **MoonBit**, with TypeScript used only for Vite configuration. Apply TypeScript architectural principles (feature cohesion, clear boundaries, dependency direction, minimal exports) **without changing language**.

## Browser board (`posoco-ext-board-web/src`)

All files below remain in the **same MoonBit package**. File boundaries denote responsibility, not importable submodules.

- `model.mbt`: application model, messages, connection lifecycle and initialization
- `ticket_types.mbt`: ticket, team, model selection and run data types
- `board_ui_types.mbt`: editor drafts, notices and local UI interaction types
- `ticket_codec.mbt`: host ticket JSON/frame decoding
- `ticket_commands.mbt`: command payloads and transport dispatch
- `ticket_progress.mbt`: progress and inbox projections
- `ticket.mbt`: ticket state application and outcome handling
- `ticket_run_view.mbt`: run actions and run-card presentation
- `ticket_inbox_view.mbt`: question and progress inbox presentation
- `board_header.mbt`: navigation, toolbar, filters and connection status
- `board_editor_view.mbt`: editor and confirmation dialogs
- `board_canvas.mbt`: task cards, lanes and board canvas
- `board_overlays.mbt`: archives and status overlays
- `board_team_view.mbt`: team configuration UI
- `view.mbt`: root page composition
- `update.mbt`: message processing with shared editable-role validation

## Native board (`posoco-ext-board-native/src`)

- `server.mbt`: server lifecycle, composition, app wiring
- `request_security.mbt`: request source, token and security middleware
- `static_assets.mbt`: protected paths and static asset routing

## Domain (`posoco-ext-board/src/domain`)

- `state.mbt`: encapsulated authoritative state and mutation primitives
- `state_copy.mbt`: detached record/state copies and deterministic sorting

## Boundaries

Domain rules and state remain authoritative in `posoco-ext-board`. Protocol code owns wire contracts. Web and native modules are adapters, not additional sources of truth. Preserve the package public API, protocol payloads and generated signatures. Keep adapters thin; favor small, cohesive functions, explicit domain types and pure transformations.

This refactoring is source organization only. It introduces **no tests**. Use existing `moon check`, `moon build` and repository workflows to verify behavior.
