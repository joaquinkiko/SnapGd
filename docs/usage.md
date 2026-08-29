# How To Use

- [Quick Start](#Quick-Start)
- [Core Concepts](#Core-Concepts)
- [SnapAPI](#SnapAPI)
- [NetIdentifiable](#NetIdentifiable)
- [NetNode](#NetNode)
- [NetInterpolator](#NetInterpolator)
- [NetEvent](#NetEvent)
- [NetCompensator](#NetCompensator)
- [NetObserver](#NetObserver)
- [NetObservable](#NetObservable)
- [Example](#Example)

[Back](../README.md)

## Quick Start

1. On any node whose properties need to sync (position, health, etc.), add a `NetNode` child. Set `command_properties` (client → server, e.g. input-driven values) and/or `state_properties` (server → client, authoritative values) as `"NodePath:Property"` entries, relative to `root`.
2. Update `command_properties` in a function connected to your `NetNode`'s `sample_input` signal.
3. Update `state_properties` in a function connected to your `NetNode`'s `simulate_command` signal for peer owned nodes (e.g. player characters).
4. Update `state_properties` for NPCs and other non-peer-owned nodes directly from `SnapAPI.post_tick` (server-side), since these are not driven by any peer's command.
5. Add a `NetInterpolator` as a child of the `NetNode` and list properties you want smoothly interpolated in `interpolated_properties` (e.g. position, rotation).
6. For networked actions (like shooting), add a `NetEvent`, list function names in `events`, and use `call_event()` to call these functions.
7. For lag compensation on called events, add a `NetCompensator` to record compensated properties (e.g. `Hitbox:global_position`), and mark relevant `NetEvent`s with `lag_compensated = true`.
8. To scale sync priority by distance (e.g. don't waste bandwidth on far-away players), pair a `NetObserver` on each peer's camera/view root with `NetObservable`s wrapping the `NetNode`s you want scaled.

Remember to run your simulations through your `NetNode`'s `simulate_command` signal (or `SnapAPI.post_tick` for non-owned nodes), rather than `_process` and `_physics_process`, so that they are properly synchronized.

For correct client-predictions it is important that all functions are deterministic, meaning that given the same `command_properties` values they always return the same `state_properties` values.

## Core Concepts

**Tick loop**: `SnapAPI` accumulates `_process(delta)` time and runs fixed-rate ticks at `tick_rate` hz. Each tick input is sampled and commands are simulated. At a frequency set by `snapshot_rate`, the server then sends out a snapshot containing the current world state to all clients. Higher `tick_rate` and `snapshot_rate` will result in more accurate and responsive gameplay, but at the cost of performance and bandwidth.

**Authority model**: Every synced node has a Godot multiplayer authority. The peer who owns a `NetNode`/`NetEvent`/`NetCompensator` predicts/executes locally and is authoritative for `command_properties`. The server is authoritative for `state_properties`.

**Prediction & reconciliation**: Clients simulate their own commands immediately (prediction), buffer them, and rewind + replay when a correction arrives from the server. If a `NetInterpolator` is connected, then small corrections are cached and blended smoothly over the next few frames, while larger corrections are hard snapped to keep the simulation accurate.

**Delta encoding & byte limits**: Snapshots only include properties that changed since what a given peer has confirmed receiving, and each snapshot is capped to a byte limit (default 1200 bytes, customizable per peer). If more has changed than fits, lower-priority changes are simply held back and included in a later snapshot — nothing is lost, delivery is just delayed under heavy load.

**Priority & interest management**: When a snapshot can't fit everything, which properties get sent first is controlled by each `NetNode`'s `base_priority` and `priority_multiplier`, optionally scaled further by distance via `NetObserver`/`NetObservable`. Anything left out of a snapshot becomes higher priority next time, so nothing starves forever.

**Validation Check**: On connect, each peer sends info on their current protocol version and integer/float encoding settings. If these don't match the server's, the peer is disconnected. This catches mismatched builds or platform encoding differences before they cause silent data corruption.

## SnapAPI

### Configuration
| Property | Description |
|---|---|
| `tick_rate` | Simulation ticks/sec (30–128). Set before connecting. |
| `snapshot_rate` | Snapshots-sent/sec (15–64). Only relevant to server. |
| `input_send_rate` | How often clients send input bundles to the server. Lower rates reduce bandwidth but increase the redundant commands needed to cover the gap. |
| `max_ticks_per_frame` | Caps how many ticks may be processed in a single `_process` frame, to avoid spiral-of-death after a stall (1–16). |
| `interpolation_delay_msec` | How far in the past remote peers are rendered for client interpolation (50–150ms). Set on `NetInterpolator`. |
| `max_rewind_msec` | Max lag-compensation window (100–300ms). Set on `NetCompensator`. |
| `is_client_server` | Whether the host also simulates its own commands as a player themselves. |

### Signals (lifecycle, in emission order per frame)
| Signal | When | Use for |
|---|---|---|
| `pre_tick_loop` | Once, before any ticks this frame | Sampling data that shouldn't change mid-frame. |
| `pre_tick(tick)` | Before each tick | Per-tick setup. |
| `post_tick(tick)` | After each tick | Per-tick cleanup, and server-side simulation of non-peer-owned nodes (NPCs, platforms, projectiles). |
| `post_tick_loop` | Once, after all ticks this frame | Rendering-facing updates; `NetInterpolator` applies interpolation/smoothing here. |
| `snapshot_received(snapshot)` | Client-side, when a new snapshot arrives, before it's applied | Reacting to fresh server state before reconciliation runs. |
| `pause_state_changed(paused)` | On pause toggle | UI/gameplay reaction to pause. |

`sample_input` and `simulate_command` are signals on individual `NetNode`s, not on `SnapAPI` — see [NetNode](#NetNode).

### Pausing
Only the server may call `SnapAPI.set_paused(true/false)`. State syncs to all peers automatically, including peers that join while already paused. Commands and new ticks are not simulated when paused.

### Bandwidth & Diagnostics
| Method | Description |
|---|---|
| `set_snapshot_byte_limit(peer, limit)` | Overrides the default 1400-byte snapshot cap for a specific peer. Useful for adjusting per connection quality. |
| `get_peer_stats(peer)` | Server-only. Returns a `Dictionary` with `validated`, `rtt_msec`, `last_snapshot_bytes`, `snapshot_byte_limit`, `pending_commands`, `future_queued_events`, `most_starved_net_id`, and `most_starved_count`. Useful for debugging sync issues or building an in-game network stats display. |

### Registration
`NetIdentifiable` (and by extension `NetNode`/`NetEvent`), and `NetCompensator`/`NetObserver`/`NetObservable` self-register/unregister via `_enter_tree`/`_exit_tree` or `_ready`. Don't call registration functions directly unless you know what you're doing.

## NetIdentifiable

Base class for anything that needs a lightweight numeric ID over the network instead of a full `NodePath`. `NetNode` and `NetEvent` both extend this — you generally don't use it directly.

- On registration, the server assigns a `net_id` and broadcasts the ID→path mapping to all clients (bundled with any other identifiables registered the same tick).
- New peers are sent every currently active identifiable on connect.
- On removal, the ID is broadcast to all clients so they can drop the stale mapping.
- If a client receives data referencing an ID it hasn't resolved yet, that data is dropped for now (and not acknowledged, so it can safely be resent) rather than causing an error.

## NetNode

Declares which properties of a node are networked.

### Configuration
| Property | Description |
|---|---|
| `root` | Root path for properties. |
| `command_properties` | Properties to be sent as commands from client → server. Max 32 per node. |
| `state_properties` | Properties to be sent as world state from server → clients. Max 32 per node. |
| `base_priority` | Base weight for how urgently this node's changes should be included when a snapshot doesn't have room for everything. Higher sends sooner. |
| `priority_multiplier` | Runtime multiplier on top of `base_priority`, defaults to 1.0. Set to 0 to suppress sending entirely, or raise temporarily to boost urgency (e.g. right after a big state change). |

Entry format: `"NodePath:Property"`, e.g. `"CharacterBody:velocity"`, `".:rotation:x"`. Paths are resolved relative to `root`.

- **command_properties**: Owning peer has authority over these, and these values are stored for replay during reconciliation.
- **state_properties**: Server has authority over these and sends them as snapshots to all clients.

### Signals
| Signal | When |
|---|---|
| `sample_input(command)` | Ran by the owning client each tick, before the command is captured. Update input-driven values here. |
| `simulate_command(command)` | Whenever this node's command is simulated — by its owner (prediction) or by the server. Move/update the node here. |

### Validation
`validate_command(command)` / `validate_state(state)` check that incoming data matches this node's expected property types, and (for commands) that it actually belongs to a node the sending peer owns. These run automatically server-side; you don't need to call them yourself unless writing custom receive logic.

## NetInterpolator

Attach alongside a `NetNode` to smooth state updates.

### Configuration
| Property | Description |
|---|---|
| `net_node` | NetNode to smooth. Defaults to parent if unset. |
| `interpolated_properties` | These properties are smoothed on remotely owned nodes between snapshots. |
| `smoothed_properties` | These properties are smoothed on nodes owned by self when a prediction is incorrect by a small margin. |
| `interpolation_delay_msec` | How far in the past (ms) remote peers are rendered (50–150). |
| `snap_threshold` | If a smoothing offset's magnitude exceeds this, it snaps instantly instead of blending. Tune per-property based on typical movement scale. |

## NetEvent

One-shot networked function calls (e.g. muzzle flash, lag-compensated shooting, a one-time sound effect).

### Configuration
| Property | Description |
|---|---|
| `root` | Root path for functions. |
| `events` | Callable functions on `root`. Max 32 per node. |
| `rule` | Who has permission to call these events (Owner, Server, Anyone)? |
| `lag_compensated` | Should lag-compensation be applied when these events are called? |

- `call_event(event_name, args := [])`: checks `rule` locally, runs the function on `root` **immediately** (for responsiveness), then queues it to be bundled and sent this tick.
- `apply_event(event_index, args, caller, tick)`: called by `SnapAPI` when a relayed event arrives from the network. Runs the function on `root`. Should not be called directly otherwise the event won't be networked.
- `rule` who may call/trigger the event:
  - `OWNER`: only the `NetEvent`'s multiplayer authority.
  - `SERVER`: only the server.
  - `ANYONE`: any peer.
- `lag_compensated`: when a lag-compensated event fires, **all** registered `NetCompensator`s are rewound for its duration.

### Validation
Argument count and types for each event function are sampled once at `_ready` and checked automatically whenever an event is applied — mismatched or malformed arguments are dropped rather than crashing the target function. **For this to work, give your event functions typed parameters** (e.g. `func shoot(target: Vector3)` rather than `func shoot(target)`) — untyped parameters skip type checking.

## NetCompensator

Records property history so lag-compensated events can rewind the world to how it looked at that moment (useful for events like accurate shooting).

### Configuration
| Property | Description |
|---|---|
| `root` | Root path for functions. |
| `compensated_properties` | Properties to record and rewind during lag-compensation. |
| `max_rewind_msec` | How far back (ms) lag-compensation rewinding is allowed (100–300). |

- Records every tick automatically (no manual call needed).
- You don't call `rewind_to`/`restore` directly for events. `NetEvent` calls these automatically.

## NetObserver

Defines a peer's point of view for interest management, similar to a Camera. Attach to (or reference) a `Node2D`/`Node3D`.

### Configuration
| Property | Description |
|---|---|
| `root` | Node2D/Node3D to measure distance from. Defaults to parent. |
| `min_range` | Distance at or under which observed nodes get full priority (factor 1.0). |
| `max_range` | Distance at or beyond which observed nodes get zero priority. |
| `current` | Makes this the active observer for the peer that owns it. Only one observer is active per peer at a time, similar to `Camera3D.current`. |

## NetObservable

Wraps one or more `NetNode`s so their priority scales with distance to whichever `NetObserver` is currently active for each peer.

### Configuration
| Property | Description |
|---|---|
| `root` | Node2D/Node3D to measure distance from. Defaults to parent. |
| `net_nodes` | Paths to the `NetNode`s this observable manages. |

- Distance between a peer's active `NetObserver` and this observable's `root` is mapped to a 0–1 factor (1.0 inside `min_range`, 0.0 outside `max_range`, linear between), which multiplies on top of each managed `NetNode`'s `base_priority` and `priority_multiplier`.
- If a peer has no active observer, managed nodes are treated as full priority (factor 1.0) — this only restricts sync once observers are actually set up.

## Example

```gdscript
# Player
# ├─ NetNode           (root: Player command_properties: [".:velocity"], state_properties: [".:global_position"])
# ├─ NetInterpolator   (root: Player interpolated_properties: [".:global_position"])
# ├─ NetEvent          (root: Player events: ["shoot"], rule: OWNER, lag_compensated: true)
# ├─ NetObserver       (root: Player/Camera3D, min_range: 15, max_range: 60, current: true)
# ├─ NetObservable     (root: Player, net_nodes: ["../NetNode"])
# └─ Hitbox
#    └─ NetCompensator (root: Hitbox compensated_properties: [".:global_position"])

func shoot(target: Vector3) -> void:
    muzzle_flash.emit()
    if multiplayer.is_server():
        _hitscan(target)

# Called from input handling:
$NetEvent.call_event("shoot", [aim_target])
```

Player's owner controls the velocity, while the server has final say over the player's actual position. The position is then smoothly interpolated.

Shooting plays the muzzle flash instantly for the shooter, and repeats for all clients, while the server rewinds all `NetCompensator`s to the shooter's tick before running `shoot()`'s hit-detection, then restores the current positions.

The `NetObserver`/`NetObservable` pair means each remote player's position updates are prioritized based on how close they are to your own camera — distant players fall back on bandwidth when snapshots are tight, without ever fully stopping.
