# WebSocket v3 Refactor Plan (Ghostty + Unified Transport)

Goal: same terminal I/O tech on Web + iOS (Ghostty), keep thumbnails, collapse today’s split transports into **one WebSocket** with a **single framed binary protocol**.

This doc is a refactor plan (not an API contract). Expect iteration.

## Current State (Code Reality)

### Web (interactive session view)
- Output: SSE `/api/sessions/:id/stream` (asciinema JSON) via `EventSource`
  - Server: `web/src/server/routes/sessions.ts:794`
  - Client: `web/src/client/components/session-view/connection-manager.ts`
  - Decoder: `web/src/client/utils/cast-converter.ts`
- Input: WS `/ws/input` (raw string; special keys wrapped as `\x00key\x00`)
  - Server: `web/src/server/routes/websocket-input.ts`
  - Client: `web/src/client/services/websocket-input-client.ts`
- Resize: HTTP POST `/api/sessions/:id/resize`
  - Client: `web/src/client/components/session-view/terminal-lifecycle-manager.ts`
  - Server: `web/src/server/routes/sessions.ts`

### Web (thumbnails + “binary mode”)
- Output: WS `/buffers` (binary snapshots with `0xBF` + sessionId + `VT` buffer)
  - Server: `web/src/server/services/buffer-aggregator.ts`
  - Client: `web/src/client/services/buffer-subscription-service.ts`
  - Snapshot encoder: `web/src/server/services/terminal-manager.ts`

### iOS
- Output (main terminal + previews): WS `/buffers` binary snapshots (same `0xBF` framing)
  - Client: `ios/VibeTunnel/Services/BufferWebSocketClient.swift`
  - Terminal view: `ios/VibeTunnel/Views/Terminal/TerminalView.swift`
  - Preview throttling: `ios/VibeTunnel/Services/LivePreviewManager.swift`

### Node internal IPC
- Length-prefixed framed binary protocol (unix socket per session): `web/src/server/pty/socket-protocol.ts`
  - Used for stdin/control/status/git (not stdout streaming)
  - Frame format: `[type: u8][len: u32 BE][payload]`

## Target State (Long-Term Maintenance First)

### High-level design
- **One WebSocket connection per client** (web UI, iOS app).
- One endpoint (proposal): `GET /ws` (or `/ws/v3`) negotiated via subprotocol: `vibetunnel.v3`.
- One framing layer (binary) for everything:
  - subscribe/unsubscribe
  - stdout bytes (interactive)
  - buffer snapshots (thumbnails + resync)
  - input + resize + control (kill/reset-size)
  - server events (exit/bell/title change)

### Rendering model
Hybrid (recommended):
- Interactive terminal view: **client-emulated** using Ghostty; server sends **stdout bytes**.
- Thumbnails/previews: **server-emulated** using Ghostty; server sends **binary snapshots** (existing `VT` buffer).
- Interactive clients also receive periodic snapshots for **fast join + resync** (optional; can be opt-in).

This keeps the binary snapshot protocol as a first-class tool without forcing the entire UI onto “snapshot cadence”.

## v3 Wire Protocol (Proposal)

### Principles
- Multiplex all sessions over one socket → every message must carry `sessionId` (or allow “global” sessionId = empty).
- Payloads are either:
  - raw bytes (stdout)
  - `VT` snapshot bytes (existing format from `TerminalManager.encodeSnapshot`)
  - compact binary structs (resize, subscribe flags)
  - small JSON blobs only where necessary (debug/compat; keep off hot paths)

### Frame (binary)
Proposed frame:
```
u16  magic = 0x5654   // "VT" LE
u8   version = 3
u8   type
u32  sessionIdLenLE
u8[] sessionId (UTF-8)
u32  payloadLenLE
u8[] payload
```

Notes:
- Keep existing `/buffers` v2 (`0xBF`) for a transition window; v3 replaces it.
- Endianness: LE everywhere (matches Swift decoding style today; avoids BE/LE split).

### Message types (v3)
Initial set (IDs are placeholders; assign once implementation starts):
- `HELLO` (client→server): capabilities + auth mode (optional)
- `WELCOME` (server→client): server version + auth status
- `SUBSCRIBE` (client→server): request streams for session
  - payload (binary):
    - `u32 flagsLE`
      - bit0: wantStdout
      - bit1: wantSnapshots
      - bit2: wantEvents (exit/bell/title)
    - `u32 snapshotMinIntervalMsLE` (0 = server default)
    - `u32 snapshotMaxIntervalMsLE` (0 = server default)
- `UNSUBSCRIBE` (client→server): stop streams for session
- `STDOUT` (server→client): PTY output bytes (UTF-8 bytes)
- `SNAPSHOT_VT` (server→client): binary snapshot bytes (existing `VT` buffer; *payload = TerminalManager.encodeSnapshot output*)
- `INPUT` (client→server): bytes to write to PTY
  - payload: raw bytes (UTF-8). No special-key wrappers; send escape sequences directly.
- `RESIZE` (client→server): `u32 colsLE` + `u32 rowsLE`
- `KILL` (client→server): `u8 signalLen` + `signal UTF-8` (or fixed enum later)
- `RESET_SIZE` (client→server): empty payload
- `EVENT` (server→client): small binary or JSON (exit/bell/title)
  - v1 payload (JSON) acceptable: `{ kind: 'exit'|'bell'|'title', ... }`
  - later: compact binary enums
- `PING` / `PONG` (either direction): keep-alive + latency stats
- `ERROR` (server→client): code + message

## Server Architecture Changes

### 1) New unified WS router
- Replace `/buffers` + `/ws/input` with one WS handler.
- Reuse WS auth handshake from `web/src/server/server.ts` upgrade handler (already authenticates `/buffers` + `/ws/input`).
- Add subprotocol negotiation and reject if mismatched, so v2/v3 can coexist.

### 2) SessionStreamHub (new server component)
Responsibilities:
- Track per-client subscriptions: sessionId → flags (stdout/snapshot/events).
- Fanout:
  - stdout frames from `PtyManager` output
  - snapshots from `TerminalManager` (thumbnails/resync)
  - exit/bell/title events from existing sources
- Backpressure:
  - drop/merge snapshots when client can’t keep up
  - stdout must be ordered; if client is slow, apply bounded buffering or disconnect

### 3) Feed TerminalManager from PTY output (reduce drift)
Today server-side Ghostty for snapshots is maintained by parsing session `stdout` cast files (fs.watch + JSON parse) in `TerminalManager`.

Change:
- Add a direct ingest API, e.g. `terminalManager.ingestOutput(sessionId, bytesOrString)`:
  - called from `ptyProcess.onData` in `web/src/server/pty/pty-manager.ts:641`
  - this keeps thumbnails/resync in lockstep with what clients saw
- Keep file-based rebuild as fallback:
  - server restart / late attach can still rebuild by reading cast file once (no watcher required)

### 4) Recording remains asciinema
- Keep `AsciinemaWriter` as the durable ground truth.
- Do not make recording a dependency for live transport.

### 5) HQ mode (remotes)
Today:
- `/buffers` is proxied/aggregated by `BufferAggregator` (WS to remote).
- `/ws/input` proxies to remote in `WebSocketInputHandler`.

v3:
- replace both with one “remote transport” connection per remote server.
- HQ server:
  - one upstream WS to each remote (or lazy per subscribed session)
  - forwards `SUBSCRIBE/UNSUBSCRIBE/INPUT/RESIZE/...`
  - forwards downstream `STDOUT/SNAPSHOT/EVENT`

## Client Changes

### Web frontend
Replace 3 transports with one:
- Remove SSE usage for live terminal output in `ConnectionManager` and `CastConverter.connectToStream`.
- Remove `/ws/input` client (`websocket-input-client.ts`).
- Remove resize HTTP calls from `TerminalLifecycleManager` and send `RESIZE` frames instead.

Implement a single client transport:
- `TerminalSocketClient` (new):
  - maintains one WS connection
  - exposes:
    - `subscribe(sessionId, { stdout, snapshots, events })`
    - `sendInput(sessionId, bytes)`
    - `resize(sessionId, cols, rows)`
  - handles reconnect + re-subscribe
  - handles auth token (query param like today; headers not required)

Terminal component integration:
- `vibe-terminal` emits `onData` text today; convert to bytes and send `INPUT`.
- `STDOUT` frames are written into Ghostty terminal via `terminal.write(Uint8Array | string)`.
- Snapshots:
  - optional for interactive view: use snapshot as “hard resync” (clear + apply snapshot)
  - required for thumbnails: still used as today (but now over v3 frames)

### iOS
Unify terminal + previews on the same v3 socket:
- Replace `BufferWebSocketClient` with `TerminalSocketClient` equivalent (shared across app).
- Terminal view:
  - subscribe with `{ stdout: true, snapshots: true(events optional) }`
  - feed stdout bytes into Ghostty (WKWebView bridge or future native libghostty)
  - use snapshots for:
    - fast paint on connect
    - periodic resync when drift detected
- Session list thumbnails:
  - subscribe with `{ snapshots: true }` and throttle updates (keep `LivePreviewManager` behavior)

## Migration / Refactor Phases

### Phase 0: Prep (no behavior change)
- Add v3 protocol docs (this file).
- Add shared constants/types for v3 framing (server + web client + iOS).
- Add integration tests for the frame parser/serializer (Node + Swift).

### Phase 1: Server v3 endpoint (parallel run)
- Implement WS v3 endpoint (new path or subprotocol on existing).
- Implement SessionStreamHub with:
  - subscribe/unsubscribe
  - stdout streaming for one local session
  - snapshot streaming by calling existing `TerminalManager.encodeSnapshot`
- Keep existing `/buffers`, `/ws/input`, SSE untouched.

### Phase 2: Web interactive switched to v3 (stdout + input + resize)
- Feature-flag in UI:
  - connect via v3; fall back to SSE + `/ws/input` if v3 not available
- Keep thumbnails still on `/buffers` until Phase 3.

### Phase 3: iOS switched to v3
- Replace `/buffers` usage in iOS terminal + previews with v3.
- Keep `/buffers` alive for older app versions during rollout.

### Phase 4: Thumbnails moved to v3; retire `/buffers`
- Web thumbnails switch to v3 snapshots.
- Remove `BufferAggregator` (or fold into SessionStreamHub as HQ module).
- Keep `/buffers` only behind a compatibility flag; remove after deprecation window.

### Phase 5: Retire SSE `/stream` + `/ws/input` + resize HTTP
- Remove SSE terminal streaming path from web UI.
- Keep HTTP resize endpoint for external integrations only if needed; otherwise deprecate.

## Drift / Resync Strategy (Client-emulated + Server-emulated)

We will have two emulators in play:
- client Ghostty (web, iOS) for interactive view
- server Ghostty for thumbnails + resync

Resync mechanisms:
- periodic snapshots (interactive clients opt-in)
- client can request an immediate snapshot (`SUBSCRIBE` with 0 interval + `REQUEST_SNAPSHOT` message if needed)
- if drift is observed (UI glitch, cursor mismatch, etc.), client:
  - clears terminal
  - applies snapshot to rebuild visible state

## Scrollback / “never stream full scrollback”
Not required for initial v3.

Future phases:
- add `HISTORY_RANGE` request:
  - `fromLine..toLine` (server returns rendered lines or VT-chunks)
  - or `castByteRange` based on asciinema offsets (cheap; uses existing pruning offset logic)

## Security / Auth
- Reuse current token-in-query approach for WS (works across browser + iOS).
- Keep server-side auth gate in `web/src/server/server.ts` upgrade handler; extend to v3.
- Consider WS subprotocol version pinning to avoid silent format mismatches.

## Testing Plan
- Protocol codec unit tests:
  - Node: frame encode/decode roundtrip
  - Swift: frame decode of golden fixtures (store fixtures in `web/src/test/fixtures`)
- E2E:
  - web: interactive session works (type, output, resize)
  - iOS simulator: connect, type, see output, preview updates
- HQ:
  - subscribe to remote session; validate stdout + snapshots traverse HQ correctly

## Deprecation Plan
- Maintain v2 (`/buffers` + SSE + `/ws/input`) until:
  - latest web UI defaults to v3 for 1–2 releases
  - iOS app minimum version includes v3 client
- Then:
  - remove `/ws/input`
  - remove `/api/sessions/:id/stream` (keep cast download endpoints for export/playback)
  - remove `/buffers`

## Open Questions (to resolve before Phase 1)
- Output bytes source: node-pty exposes output as `string` (`ptyProcess.onData((data: string) => ...)` in `web/src/server/pty/pty-manager.ts:641`). v3 `STDOUT` will encode that string as UTF-8 bytes; confirm this is acceptable for Ghostty on all platforms.
- Special keys: move fully to “raw bytes” (preferred) or keep “key names” for compatibility?
- Snapshot cadence defaults:
  - interactive: none by default vs 2–5s safety snapshot
  - thumbnails: 1s (matches iOS), or adaptive based on CPU

