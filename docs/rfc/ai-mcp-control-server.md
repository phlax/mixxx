# RFC: AI / MCP Control Server for Mixxx

**Status:** Draft / Exploratory  
**Repo:** `phlax/mixxx` (research fork — do not upstream without discussion)  
**Date:** 2025-05

---

## TL;DR

This RFC describes what Mixxx upstream would need to support an external
**MCP (Model Context Protocol) server** that lets an LLM agent autonomously
plan and perform DJ sets — harmonic mixing, transition selection, beat-accurate
drop alignment, etc.  The LLM is the *slow planner*; a deterministic scheduler
inside the MCP server is the *fast executor*; Mixxx remains the *sample-accurate
audio engine*.  No Mixxx C++/JS/QML sources are modified by this RFC.

---

## Table of Contents

1. [Background: What already exists in Mixxx upstream](#1-background-what-already-exists-in-mixxx-upstream)
2. [Gap analysis — what is missing for an MCP/AI use case](#2-gap-analysis--what-is-missing-for-an-mcpai-use-case)
3. [Latency budget analysis](#3-latency-budget-analysis)
4. [Proposed upstream changes](#4-proposed-upstream-changes)
5. [Recommended path](#5-recommended-path)
6. [External MCP server architecture](#6-external-mcp-server-architecture)
7. [Open questions for upstream](#7-open-questions-for-upstream)
8. [References](#8-references)

---

## 1. Background: What already exists in Mixxx upstream

### 1.1 ControlObject system

Every tuneable parameter in Mixxx — deck play/pause, playposition, BPM,
sync-enable, crossfader position, EQ bands, effect parameters, hot-cue jumps,
loop in/out — is represented as a
[`ControlObject`](https://github.com/mixxxdj/mixxx/blob/main/src/control/controlobject.h).
ControlObjects:

- are identified by `(group, key)` pairs, e.g. `[Channel1], play`;
- are written/read atomically from any thread via
  [`ControlProxy`](https://github.com/mixxxdj/mixxx/blob/main/src/control/controlproxy.h),
  which marshals values safely across the audio/GUI thread boundary;
- can be "scripted" (connected to JS callbacks) via
  [`ControlObjectScript`](https://github.com/mixxxdj/mixxx/blob/main/src/control/controlobjectscript.h),
  which queues cross-thread callbacks through Qt's event system.

Representative deck controls (all under `[Channel1]` / `[Channel2]` etc.):

```
play              playposition      bpm               rate
sync_enabled      quantize          beats_distance    loop_enabled
loop_in_position  loop_out_position hotcue_1_activate pregain
filterLow         filterMid         filterHigh        crossfader
```

The ControlObject system is the single authoritative state hub for everything
that matters to a DJ agent.

### 1.2 Controller scripting

Controller scripts run inside a
[`QJSEngine`](https://doc.qt.io/qt-6/qjsengine.html) per controller, hosted by
[`ControllerScriptEngineBase`](https://github.com/mixxxdj/mixxx/blob/main/src/controllers/scripting/controllerscriptenginebase.h).
The legacy `engine` object is exposed to JS scripts via
[`ControllerScriptInterfaceLegacy`](https://github.com/mixxxdj/mixxx/blob/main/src/controllers/scripting/legacy/controllerscriptinterfacelegacy.h),
which provides the full DJ-control surface:

| Category | Methods |
|----------|---------|
| **ControlObject I/O** | `getValue`, `setValue`, `getParameter`, `setParameter` |
| **Subscriptions** | `makeConnection`, `makeUnbufferedConnection`, `connectControl`, `trigger` |
| **Timers** | `beginTimer`, `stopTimer` |
| **Scratching** | `scratchEnable`, `scratchTick`, `scratchDisable` |
| **Transport effects** | `brake`, `spinback`, `softStart` |
| **Soft-takeover** | `softTakeover`, `softTakeoverIgnoreNextValue` |

The `ControllerScriptEngineBase` also registers the
`TrackCollectionManager` into the engine, giving scripts direct access to
library metadata (track BPM, key, cue points) without touching the database
directly.

### 1.3 AutoDJ

`src/library/autodj/` implements a queue-based automatic DJ with a fixed
crossfade transition. Key classes:

- `AutoDJProcessor` — manages deck handoff, fade start/end beats, and track
  loading.
- `DlgAutoDJ` — GUI for the queue and configuration.

AutoDJ is functional but limited: transitions are fixed-curve crossfades with
no API for external scripts to influence the shape. Transition templates and
beat-accurate hand-offs are tracked in issues
[#10753](https://github.com/mixxxdj/mixxx/issues/10753) and
[#14067](https://github.com/mixxxdj/mixxx/issues/14067).

### 1.4 OSC / external control history

OSC (Open Sound Control) parameter access has been an open *Confirmed* feature
request since 2009: [issue #5082](https://github.com/mixxxdj/mixxx/issues/5082).
Community scripts provide partial coverage, but there is no officially
maintained, full-parity OSC binding.

Generative-DJ and AI use cases are already appearing from users:
[issue #14129](https://github.com/mixxxdj/mixxx/issues/14129) documents a
ComfyUI integration that drives AutoDJ. AutoDJ quantizing improvements are
tracked in [#15169](https://github.com/mixxxdj/mixxx/issues/15169).

### 1.5 Library database

The Mixxx library lives in `~/.mixxx/mixxxdb.sqlite`. It stores per-track BPM,
musical key, cue points, beatgrid, analysed loudness, crates, and playlist
membership. `TrackCollectionManager` is the live C++ owner; the database is
written during analysis and modified when the user edits metadata.

---

## 2. Gap analysis — what is missing for an MCP/AI use case

| Capability needed | Current state | Gap |
|-------------------|---------------|-----|
| External process reads/writes ControlObjects | Only inside QJSEngine | No IPC/network primitive in JS engine |
| Subscribe to ControlObject changes from outside | `connectControl` in JS only | No push channel to external process |
| Query library / crate data live | Read sqlite directly | Risk of corruption; no live notification |
| Script transition *shape* (EQ, filter, echo) | Fixed crossfade in AutoDJ | No API; must use raw `setValue` calls in a controller script |
| Beat-accurate event scheduling from outside | `quantize` / `beatloop` ControlObjects exist | No external scheduler API; external timer is jittery |
| MCP tool call interface | Nothing | Entire layer missing |

### 2.1 No network primitives in QJSEngine

`QJSEngine` does not expose `QTcpSocket`, `QLocalSocket`, `QWebSocket`, or
any equivalent to `fetch()`. A controller script cannot open a socket, bind a
port, or accept connections from an external process. This is the root blocker
for everything else.

### 2.2 MIDI/HID transport limitations

Virtual MIDI loopback can carry control messages, but:

- MIDI CC is 7-bit (128 steps) — inadequate for fader or pitch precision.
- MIDI has one-way semantics for state queries; polling is required.
- MIDI SysEx can carry arbitrary bytes but is awkward and non-standard.

HID is bidirectional and higher bandwidth, but the mapping overhead is
significant and HID devices are not universally available.

### 2.3 No external ControlObject subscription

The `connectControl` callback mechanism works only inside the `QJSEngine`.
There is no way for an external process to register for push notifications
when a ControlObject changes — e.g. `[Channel1],playposition` changes every
audio buffer (~5 ms at 44.1 kHz / 256 samples).

### 2.4 Library access without live notifications

An external process can read `mixxxdb.sqlite` directly, but:

- Writing while Mixxx is running risks WAL corruption.
- There are no change notifications (no `NOTIFY`-equivalent for SQLite).
- `TrackCollectionManager` caches state in memory; direct DB reads may be
  stale.

### 2.5 Fixed-curve AutoDJ transitions

AutoDJ's crossfade is a linear or equal-power curve controlled by a single
duration parameter. There is no API surface for an external planner to express:
"at beat 200 of deck A, kill deck A's lows, start deck B, ramp crossfader
over 32 beats while sweeping a high-pass filter on deck B."

---

## 3. Latency budget analysis

An LLM planner round-trips in hundreds of milliseconds (inference + network).
Beat-accurate scheduling requires sub-10 ms jitter. These two requirements
**must** be separated: the LLM does slow planning; a deterministic scheduler
in the MCP server does fast execution. Only the scheduler needs a low-latency
transport into Mixxx.

| Rank | Transport | Typical latency | Notes |
|------|-----------|-----------------|-------|
| 1 | In-process controller script → `engine.setValue` | < 0.1 ms | Direct C++ call into ControlObject. Requires the MCP server to *be* the script, which defeats the purpose of a separate process. |
| 2 | **Unix domain socket / loopback WebSocket → controller script bridge** | ~0.1–1 ms | Best balance: process isolation, full ControlObject API, bidirectional. **Recommended.** |
| 3 | Virtual MIDI loopback | ~1–3 ms | Fire-and-forget fine; 7-bit precision, no state query. |
| 4 | OSC over UDP | ~1–5 ms | Good semantics, no parity community script today. |
| 5 | HTTP/REST | 5–50 ms | Fine for "load track X"; unusable for live fader or cue control. |
| 6 | Direct SQLite poking | Not realtime | Library metadata only; no playback state. |

**Key argument:** since the LLM planner is hundreds of milliseconds anyway, the
latency budget of the *scheduler* is what matters for beat accuracy. Option 2
(UDS / loopback WS) delivers ~1 ms round-trip — more than fast enough for
32-beat transitions — without any modification to Mixxx's audio path.

---

## 4. Proposed upstream changes

Proposals are ordered by increasing intrusiveness. Each is self-contained and
additive.

---

### Proposal A (minimal): JS-side local socket primitive

**Scope:** controller scripting only.  
**Risk:** low — no audio path changes, opt-in only.  
**Could be a mapping (no new C++ subsystem)?** Yes — one new header/source pair
in the scripting layer; rest is JS.

#### Rationale

Add `Q_INVOKABLE` methods to
[`ControllerScriptInterfaceLegacy`](https://github.com/mixxxdj/mixxx/blob/main/src/controllers/scripting/legacy/controllerscriptinterfacelegacy.h)
(and the new module engine) exposing a minimal **local socket** abstraction
backed by `QLocalServer` / `QLocalSocket`, restricted to the abstract
Unix-domain namespace (Linux) or a named pipe under a Mixxx-owned temp
directory (macOS / Windows). No external network connectivity.

A user-installed controller mapping (`res/controllers/AI-Bridge.js`) then:

1. Calls `engine.createLocalServer("mixxx-rpc")` — returns a server object.
2. Accepts connections; on each connection, registers a `onMessage` callback.
3. Forwards incoming JSON messages to `engine.setValue` / `engine.getValue` /
   `engine.makeConnection`.
4. Pushes ControlObject change callbacks back over the socket to the MCP server.

#### Touch points

```
src/controllers/scripting/legacy/controllerscriptinterfacelegacy.h   // new Q_INVOKABLE methods
src/controllers/scripting/legacy/controllerscriptinterfacelegacy.cpp  // implementation
res/controllers/AI-Bridge.js                                          // user-space mapping
```

New JS API surface (illustrative):

```javascript
// In a Mixxx controller script
var server = engine.createLocalServer("mixxx-rpc");

server.clientConnected.connect(function(socket) {
    socket.messageReceived.connect(function(data) {
        var msg = JSON.parse(data);
        if (msg.method === "setValue") {
            engine.setValue(msg.group, msg.key, msg.value);
            socket.write(JSON.stringify({ id: msg.id, result: true }));
        } else if (msg.method === "getValue") {
            var val = engine.getValue(msg.group, msg.key);
            socket.write(JSON.stringify({ id: msg.id, result: val }));
        } else if (msg.method === "subscribe") {
            engine.makeConnection(msg.group, msg.key, function(value) {
                socket.write(JSON.stringify({ event: "change",
                                              group: msg.group,
                                              key: msg.key,
                                              value: value }));
            });
        }
    });
});
```

#### Security

- Gated behind `[Controller] EnableLocalSockets=1` in `mixxx.cfg`, **default
  off**.
- Socket path contains the Mixxx PID to prevent cross-session access.
- Document clearly: enabling allows any local process to control Mixxx.

#### Pros / cons

| Pros | Cons |
|------|------|
| Tiny diff (< 300 lines C++) | Requires a controller mapping to be loaded |
| Reuses entire existing ControlObject API | Not auto-discoverable (user must enable + load mapping) |
| Unblocks OSC, web dashboards, and MCP via user-space code | One mapping at a time; no multi-client without explicit JS multiplexing |
| No new subsystem to maintain | |

---

### Proposal B (medium): dedicated `mixxx-rpc` C++ subsystem

**Scope:** new `src/rpc/` module owned by `CoreServices`.  
**Risk:** medium — new subsystem, but isolated from audio path.  
**Could be a mapping?** No — requires C++ changes and a new preferences page.

#### Rationale

A proper `src/rpc/` subsystem, modelled on `BroadcastManager`, opens a local
WebSocket server (and optionally a TCP-loopback server on a configured port)
at startup. It speaks a documented JSON-RPC 2.0 schema covering all
integration surfaces.

#### JSON-RPC schema (illustrative)

```json
// control.get
{ "method": "control.get", "params": { "group": "[Channel1]", "key": "bpm" } }
// → { "result": 128.0 }

// control.set
{ "method": "control.set",
  "params": { "group": "[Channel1]", "key": "play", "value": 1 } }

// control.subscribe — server pushes { "event": "change", ... } on each change
{ "method": "control.subscribe",
  "params": { "group": "[Channel1]", "key": "playposition" } }

// library.search
{ "method": "library.search",
  "params": { "query": "artist:Bicep bpm:[120 TO 130]" } }
// → { "result": [ { "id": 42, "title": "Glue", "bpm": 126.0, "key": "6A" }, ... ] }

// autodj.queue
{ "method": "autodj.queue", "params": { "track_id": 42 } }
```

#### Touch points

```
src/rpc/rpcserver.h / rpcserver.cpp      // WebSocket server, session lifecycle
src/rpc/rpcsession.h / rpcsession.cpp    // per-client session, JSON-RPC dispatch
src/rpc/rpccontrolhandler.h/.cpp         // control.get/set/subscribe via ControlProxy
src/rpc/rpclibrary handler.h/.cpp        // library.search/crates/track
src/rpc/rpcautodj handler.h/.cpp         // autodj.queue/skip/enable
src/engine/enginemaster.h                // hook for sample-accurate timestamps
src/preferences/                         // new RPC preferences page
```

#### Implementation notes

- `ControlProxy` already handles audio-thread → GUI-thread safety; RPC thread
  reads/writes go through the same path.
- Use `QWebSocketServer` (already a Qt dependency) rather than adding a new
  library.
- Authentication: HMAC-SHA256 shared secret generated at first launch, stored
  in `mixxx.cfg`, sent as a bearer token on upgrade. Off by default.
- Push events carry a monotonic sample counter alongside wall-clock time so
  the MCP scheduler can correlate with the beatgrid.

#### Pros / cons

| Pros | Cons |
|------|------|
| Clean, discoverable API | Larger diff; new subsystem to maintain |
| No controller mapping required | More surface area for security bugs |
| Multi-client, versioned schema | |
| Resolves the 15-year-old OSC request (#5082) as a side-effect | |
| Preferences UI for discoverability | |

---

### Proposal C (broader): first-class transition API

**Scope:** AutoDJ + engine thread.  
**Risk:** higher — touches audio path scheduling.  
**Addresses:** [#10753](https://github.com/mixxxdj/mixxx/issues/10753),
[#14067](https://github.com/mixxxdj/mixxx/issues/14067).

#### Rationale

Even with Proposal A or B, an external scheduler firing individual
`engine.setValue` calls over a socket will have ~1 ms jitter per command. For
a 32-beat blend that's fine. For a precise double-drop alignment (two tracks
must hit their downbeats on exactly the same sample), it is not. The only
solution is a **beat-indexed event scheduler inside Mixxx's engine thread**
that consumes a pre-submitted plan.

#### `TransitionPlan` object

```json
{
  "deck_a": "[Channel1]",
  "deck_b": "[Channel2]",
  "events": [
    { "at_beat_of": "a", "beat": 200, "action": "load",
      "args": { "track_id": 42, "deck": "b" } },
    { "at_beat_of": "a", "beat": 208, "action": "set_sync",
      "args": { "deck": "b", "value": 1 } },
    { "at_beat_of": "a", "beat": 216, "action": "play",
      "args": { "deck": "b" } },
    { "at_beat_of": "a", "beat": 216, "action": "crossfade_ramp",
      "args": { "from": 0.0, "to": 1.0, "over_beats": 32 } },
    { "at_beat_of": "a", "beat": 224, "action": "eq_ramp",
      "args": { "deck": "a", "band": "low", "from": 1.0, "to": 0.0, "over_beats": 8 } },
    { "at_beat_of": "a", "beat": 248, "action": "stop",
      "args": { "deck": "a" } }
  ]
}
```

Supported actions: `load`, `play`, `stop`, `set_sync`, `crossfade_ramp`,
`eq_ramp`, `cue_jump`, `brake`, `loop`, `effect_param`.

#### Touch points

```
src/library/autodj/autodjprocessor.h/.cpp    // TransitionPlan submission + execution
src/engine/enginemaster.h/.cpp               // beat-indexed scheduler callback
src/rpc/rpcsession.cpp                       // transition.submit RPC method (Proposal B)
src/controllers/scripting/legacy/            // engine.submitTransition() (Proposal A path)
```

The scheduler runs in the engine callback, consumes events whose target beat
has been crossed, and fires the corresponding ControlObject writes — all
sample-accurately. No timer resolution involved.

---

### Proposal D (orthogonal): land OSC support (#5082)

A generic OSC bridge can be built on top of Proposal B's `control.*` methods
with minimal additional code: OSC address `/mixxx/Channel1/bpm` maps directly
to `control.get { group: "[Channel1]", key: "bpm" }`. This would resolve a
15-year-old community request. Mention here but do not block on it — Proposal B
must land first.

---

## 5. Recommended path

```
Phase 1 (1–2 weeks):  Proposal A — JS socket primitive
Phase 2 (4–8 weeks):  Proposal B — mixxx-rpc subsystem
Phase 3 (ongoing):    Proposal C — TransitionPlan API
Phase 4 (parallel):   Proposal D — OSC on top of B
```

**Phase 1 first** because:

- It is a tiny, reviewable diff that does not introduce a new subsystem.
- It immediately unblocks: MCP server, OSC bridges, web dashboards, the
  ComfyUI crowd ([#14129](https://github.com/mixxxdj/mixxx/issues/14129)) —
  all via user-installed mappings.
- It lets the community converge on a protocol before it is frozen into a C++
  API.
- It can ship as an experimental opt-in without any stability promise.

**Phase 2** provides the clean long-term home with versioned schema,
multi-client support, and no "you must load this mapping" friction.

**Phase 3** is the only path to phase-locked double-drops and other
sample-accurate multi-track transitions. It is a dependency for a truly
professional AI DJ, but not for the MVP.

---

## 6. External MCP server architecture

> This section describes the MCP server that lives **outside** Mixxx. It is
> not an upstream concern, but is included to motivate the transport
> requirements above.

```
┌─────────────────────────────────────────────────────────────────────────┐
│  LLM (Claude / GPT / local model)                                        │
│  slow planner: crate analysis, set ordering, transition template choice  │
└───────────────────────────┬─────────────────────────────────────────────┘
                            │  MCP (stdio / SSE)  — hundreds of ms
                            ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  mixxx-mcp  (Python / TypeScript, separate process)                      │
│                                                                          │
│  ┌──────────────────────────────────────────────────────┐               │
│  │  Planner tools                                        │               │
│  │  list_crates  analyze_track  plan_set  get_metadata   │               │
│  └──────────────────────────────────────────────────────┘               │
│                                                                          │
│  ┌──────────────────────────────────────────────────────┐               │
│  │  Scheduler (asyncio event loop)                       │               │
│  │  beat-indexed event queue                             │               │
│  │  subscribed to [Channel1],playposition                │               │
│  │  fires: load / play / crossfade_ramp / eq_ramp / stop │               │
│  └──────────────────────────────────────────────────────┘               │
└────────────────────────┬────────────────────────────────────────────────┘
                         │  UDS / loopback WS  — ~1 ms
                         ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  Mixxx                                                                   │
│  ControlObject system  ◀──── setValue / getValue / subscribe ────────▶  │
│  engine.makeConnection push ──────────────────────────────────────────▶ │
└─────────────────────────────────────────────────────────────────────────┘
```

### Scheduler pattern

The scheduler maintains a beat-indexed priority queue. It subscribes to
`[Channel1],playposition` at startup; each callback converts playposition →
current beat using the stored beatgrid and fires any due events:

```python
# pseudocode — mixxx_mcp/scheduler.py
async def execute_transition(plan: TransitionPlan):
    await wait_for_beat(deck="a", beat=plan.load_beat)
    await mixxx.control_set("[Channel2]", "LoadSelectedTrackAndPlay", 0)
    await mixxx.control_set("[Channel2]", "sync_enabled", 1)

    await wait_for_beat(deck="a", beat=plan.play_beat)
    await mixxx.control_set("[Channel2]", "play", 1)

    async with crossfade_ramp(from_val=0.0, to_val=1.0,
                               start_beat=plan.play_beat,
                               over_beats=32, clock_deck="a"):
        await wait_for_beat(deck="a", beat=plan.eq_kill_beat)
        async with eq_ramp("[Channel1]", band="low",
                           from_val=1.0, to_val=0.0, over_beats=8):
            pass

    await wait_for_beat(deck="a", beat=plan.stop_beat)
    await mixxx.control_set("[Channel1]", "play", 0)
```

`wait_for_beat` is an `asyncio.Event` set by the `playposition` callback —
no polling, no drift, no LLM in the hot path.

### MCP tools exposed to the LLM

| Tool | Description |
|------|-------------|
| `list_crates` | Return crates and track counts from library |
| `get_track_metadata` | BPM, key, duration, beatgrid confidence, cue points |
| `search_tracks` | Full-text + BPM/key filter search |
| `plan_set` | LLM helper: given N tracks, return ordered set + transition templates |
| `load_track` | Load a track onto a deck |
| `execute_transition` | Submit a `TransitionPlan` to the scheduler |
| `now_playing` | Current deck states (BPM, position, track title) |
| `abort` | Emergency stop — fade out both decks |

---

## 7. Open questions for upstream

1. **Legacy vs. module engine:** Should the socket primitive (Proposal A) go
   into `ControllerScriptInterfaceLegacy` only, or into both legacy and the new
   QML/module-based `ControllerScriptModuleEngine`? The module engine is the
   future; adding it only to legacy creates tech debt.

2. **Security model:** Controller scripts today are trusted by the user (they
   load a `.js` file manually). Adding socket capability means a malicious
   mapping could exfiltrate audio or control Mixxx remotely. Options:
   - Explicit opt-in toggle (preferred, see Proposal A).
   - Signed/sandboxed scripts (significant work, out of scope for MVP).

3. **ControlProxy thread safety for writes:** `ControlProxy::set(value)` posts
   via Qt's event system and is safe from any thread. This should be confirmed
   for the RPC thread case before Proposal B lands.  
   See [`controlproxy.h`](https://github.com/mixxxdj/mixxx/blob/main/src/control/controlproxy.h).

4. **Beatgrid confidence exposure:** The beatgrid analyzer stores a confidence
   score but it is not currently exposed as a ControlObject or library field.
   For the planner to choose between blend vs. cut transitions, it needs to
   know whether the beatgrid is reliable. This is a small but important
   addition.

5. **Multi-deck setups:** The proposals above use `[Channel1]`/`[Channel2]`.
   Four-deck setups (`[Channel3]`/`[Channel4]`) and sampler decks should be
   supported in the schema from day one to avoid breaking changes later.

6. **AutoDJ coexistence:** If both AutoDJ and an external MCP server are
   active, they will race to control the decks. A mutex or "AutoDJ disabled
   when RPC client is connected" guard is needed.

---

## 8. References

### Source files (mixxxdj/mixxx @ main)

| File | Relevance |
|------|-----------|
| [`src/control/controlobject.h`](https://github.com/mixxxdj/mixxx/blob/main/src/control/controlobject.h) | Core state hub; `(group, key)` paradigm |
| [`src/control/controlproxy.h`](https://github.com/mixxxdj/mixxx/blob/main/src/control/controlproxy.h) | Thread-safe cross-thread read/write |
| [`src/control/controlobjectscript.h`](https://github.com/mixxxdj/mixxx/blob/main/src/control/controlobjectscript.h) | JS-side ControlObject binding |
| [`src/controllers/scripting/controllerscriptenginebase.h`](https://github.com/mixxxdj/mixxx/blob/main/src/controllers/scripting/controllerscriptenginebase.h) | QJSEngine host; registers `engine` global |
| [`src/controllers/scripting/legacy/controllerscriptinterfacelegacy.h`](https://github.com/mixxxdj/mixxx/blob/main/src/controllers/scripting/legacy/controllerscriptinterfacelegacy.h) | Full JS `engine.*` API surface |

### Issues (mixxxdj/mixxx)

| Issue | Summary |
|-------|---------|
| [#5082](https://github.com/mixxxdj/mixxx/issues/5082) | OSC parameter access — open since 2009, *Confirmed* |
| [#10753](https://github.com/mixxxdj/mixxx/issues/10753) | Transition templates for AutoDJ |
| [#14067](https://github.com/mixxxdj/mixxx/issues/14067) | AutoDJ beatmatch with marker-driven transitions |
| [#14129](https://github.com/mixxxdj/mixxx/issues/14129) | ComfyUI / generative-DJ integration |
| [#15169](https://github.com/mixxxdj/mixxx/issues/15169) | AutoDJ quantizing improvements |

### External

- [Model Context Protocol specification](https://spec.modelcontextprotocol.io/)
- [Qt QLocalServer documentation](https://doc.qt.io/qt-6/qlocalserver.html)
- [Qt QWebSocketServer documentation](https://doc.qt.io/qt-6/qwebsocketserver.html)
- [JSON-RPC 2.0 specification](https://www.jsonrpc.org/specification)
