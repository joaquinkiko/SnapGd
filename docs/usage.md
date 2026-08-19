# How To Use

- [Quick Start](#Quick-Start)
- [Core Concepts](#Core-Concepts)
- [SnapAPI](#SnapAPI)
- [NetNode](#NetNode)
- [NetInterpolator](#NetInterpolator)
- [NetEvent](#NetEvent)
- [NetCompensator](#NetCompensator)
- [Example](#Example)

[Back](../README.md)

## Quick Start

1. On any node whose properties need to sync (position, health, etc.), add a `NetNode` child. Set `command_properties` (client → server, e.g. input-driven values) and/or `state_properties` (server → client, authoritative values) as `"NodePath:Property"` entries, relative to `root`.
2. Update `command_properties` in a function connected to the signal `SnapAPI.sample_input`.
3. Update `state_properties` in a function connected to the signal `SnapAPI.simulate_command` for peer owned nodes (e.g. player characters).
4. Update `state_properties` for NPCs and non-peer owned nodes in a function connected to the signal `SnapAPI.simulate_world`.
5. Add a `NetInterpolator` as a child of the `NetNode` and list properties you want smoothly interpolated in `interpolated_properties` (e.g. position, rotation).
6. For networked actions (like shooting), add a `NetEvent`, list function names in `events`, and use `call_event()` to call these functions.
7. For lag compensation on called events, add a `NetCompensator` to record compensated properties (e.g. `Hitbox:global_position`), and mark relevant `NetEvent`s with `lag_compensated = true`.

Remember to run your simulations through `SnapAPI.simulate_command` and `SnapAPI.simulate_world`, rather than `_process` and `_physics_process` so that they are properly synchronized.

For correct client-predictions it is important that all functions are deterministic, meaning that given the same `command_properties` values they always return the same `state_properties` values.

## Core Concepts

**Tick loop**: `SnapAPI` accumulates `_process(delta)` time and runs fixed-rate ticks at `tick_rate` hz. Each tick input is sampled and commands are simulated. At a frequency set by `snapshot_rate`, the server then send out a snapshot containing the current world state to all clients. Higher `tick_rate` and `snapshot_rate` will result in more accurate and responsive gameplay, but at the cost of performance and bandwidth.

**Authority model**: Every synced node has a Godot multiplayer authority. The peer who owns a `NetNode`/`NetEvent`/`NetCompensator` predicts/executes locally and is authoritative for `command_properties`. The server is authoritative for `state_properties`.

**Prediction & reconciliation**: Clients simulate their own commands immediately (prediction), buffer them, and rewind + replay when a correction arrives from the server. If a `NetInterpolator` is connected, then small corrections are cached by `SnapAPI.render_offset`, allowing them to be smoothly corrected over the next few frames, while larger corrections will instead be hard snapped to keep the simulation accurate.

## SnapAPI

### Configuration
| Property | Description |
|---|---|
| `tick_rate` | Simulation ticks/sec (30–128). Set before connecting. |
| `snapshot_rate` | Snapshots-sent/sec (30–128). Only relevant to server. |
| `interpolation_delay_msec` | How far in the past remote peers are rendered for client interpolation (50–150ms). |
| `max_rewind_msec` | Max lag-compensation window (200–300ms). |
| `is_client_server` | Whether the host also simulates its own commands as a player themselves. |

### Signals (lifecycle, in emission order per frame)
| Signal | When | Use for |
|---|---|---|
| `pre_tick_loop` | Once, before any ticks this frame | Sampling data that shouldn't change mid-frame. |
| `pre_tick(tick)` | Before each tick | Per-tick setup. |
| `sample_input(command: SnapCommand)` | Ran be clients each tick | Update input values before they're captured. |
| `simulate_command(command: SnapCommand)` | Whenever server simulates a peer command, or when you predict your own command | Move/update objects. |
| `simulate_world(delta)` | Once per server tick | Update non-peer-owned objects (platforms, projectiles, NPCs). |
| `post_tick(tick)` | After each tick | Per-tick cleanup. |
| `post_tick_loop` | Once, after all ticks this frame | Rendering-facing updates; `NetInterpolator` applies interpolation/smoothing here. |
| `pause_state_changed(paused)` | On pause toggle | UI/gameplay reaction to pause. |

### Pausing
Only the server may call `SnapAPI.set_paused(true/false)`. State syncs to all peers automatically. Commands and new ticks are not simulated when paused.

### Registration
`NetNode`, `NetEvent`, and `NetCompensator` self-register/unregister via `_enter_tree`/`_exit_tree`. Don't call this directly unless you know what you're doing.

## NetNode

Declares which properties of a node are networked.

### Configuration
| Property | Description |
|---|---|
| `root` | Root path for properties. |
| `command_properties` | Properties to be sent as commands from client -> server. |
| `state_properties` | Properties to be sent as world state from server -> clients. |

Entry format: `"NodePath:Property"`, e.g. `"CharacterBody:velocity"`, `".:rotation:x"`. Paths are resolved relative to `root`.

- **command_properties**: Owning peer has authority over these, and these values are stored for replay during reconciliation.
- **state_properties**: Server has authority over these and sends them as snapshots to all clients.

## NetInterpolator

Attach alongside a `NetNode` to smooth state updates.

### Configuration
| Property | Description |
|---|---|
| `net_node` | NetNode to smooth. This **must** be set. |
| `interpolated_properties` | These properties are smoothed on remotely owned nodes between snapshots. |
| `smoothed_properties` | These properties are smoothed on nodes owned by self when a prediction is incorrect by a small margin. |

## NetEvent

One-shot networked function calls (e.g. muzzle flash, lag-compensated shooting, a one-time sound effect).

### Configuration
| Property | Description |
|---|---|
| `root` | Root path for functions. |
| `events` | Callable functions on `root`. |
| `rule` | Who has permission to call these events (Owner, Server, Anyone)? |
| `lag_compensated` | Should lag-compensation be applied when these events are called? |

- `call_event(event_name, args := [])`: checks `rule` locally, runs the function on `root` **immediately** (for responsiveness), then queues it to be bundled and sent this tick.
- `apply_event(event_name, args)`: called by `SnapAPI` when a relayed event arrives from the network. Runs the function on `root`. Should not be called directly otherwise event won't be networked.
- `rule` who may call/trigger the event:
  - `OWNER`: only the `NetEvent`'s multiplayer authority.
  - `SERVER`: only the server.
  - `ANYONE`: any peer.
- `lag_compensated`: when a lag-compensated event fires, **all** registered `NetCompensator`s are rewound for its duration.

## NetCompensator

Records property history so lag-compensated events can rewind the world to how it looked at that moment (useful for events like accurate shooting).

### Configuration
| Property | Description |
|---|---|
| `root` | Root path for functions. |
| `compensated_properties` | Properties to record and rewind during lag-compensation. |
| `server_only` | If true, lag-compensation will only be ran for the server. |

- Records every tick automatically (no manual call needed)
- You don't call `rewind_to`/`restore` directly for events.`NetEvent` call these automatically.

## Example

```gdscript
# Player
# ├─ NetNode           (root: Player command_properties: [".:velocity"], state_properties: [".:global_position"])
# ├─ NetInterpolator   (root: Player interpolated_properties: [".:global_position"])
# ├─ NetEvent          (root: Player events: ["shoot"], rule: OWNER, lag_compensated: true)
# └─ Hitbox
#    └─ NetCompensator (root: Htbox compensated_properties: [".:global_position"], server_only: true)

func shoot() -> void:
    muzzle_flash.emit()
    if multiplayer.is_server():
        _hitscan()

# Called from input handling:
$NetEvent.call_event("_fire")
```

Player's owner controls the velocity, while the server has final say over the player's actual position. The position is then smoothly interpolated.

Shooting plays the muzzle flash instantly for the shooter, and repeats for all clients, while the server rewinds all `NetCompensator`s to the shooter's tick before running `shoot()`'s hit-detection, then restores the current positions.
