## Global API for SnapGd
extends Node

## Sequence buffer size for outbound packets
const _SEQ_BUFFER_SIZE := 128 # (MUST be power of 2)
const _SEQ_BUFFER_MASK := _SEQ_BUFFER_SIZE - 1
## Prediction errors below this should be ignored (assume floating point noise)
const _RECONCILIATION_EPSILON := 0.001

## Emitted once before any ticks are processed this frame. Any data
## that doesn't change more than once per frame should be sampled here.
signal pre_tick_loop
## Emitted once after all ticks this frame have been processed.
## Rendering updates should be done here.
signal post_tick_loop
## Emitted before a single tick is simulated.
signal pre_tick(tick: int)
## Emitted after a single tick has been fully simulated.
signal post_tick(tick: int)
## Emitted whenever paused state changes
signal pause_state_changed(paused: bool)
## Emitted on client whenever a new snapshot is received (and before handled)
signal snapshot_received(snapshot: Snapshot)

# Client-side data

## Client current command sequence
var _command_sequence: int
## Client command history buffer of size [member _SEQ_BUFFER_SIZE]
var _command_history: Array[SnapCommand]
## Client state history buffer of size [member _SEQ_BUFFER_SIZE]
var _state_history: Array[SnapState]
## Latest snapshot received, waiting to be reconciled on the next tick.
var _pending_snapshot: Snapshot
## Leftover visual-only properties after soft correction.
## Decays toward empty every client tick.
var render_offsets: Dictionary[int, Variant]
## Sequence of the last event processed by the client.
## NOT last event received, as some events may be queued for later.
var _last_processed_event_sequence: int
## Highest command sequence server has acknowledged via snapshot.
var _last_acked_command_sequence: int
## Highest command sequence queued server-side, per peer
## to prevents re-queueing overlap between bundles.
var _last_queued_command_sequence: Dictionary[int, int]
## Path->id mappings received before the node existed locally yet
var _pending_path_ids: Dictionary[NodePath, int]
## Client's last fully reconstructed world state (merged deltas applied).
var _last_full_state: SnapState
## Tick [member _last_full_state] corresponds to. 0 = none yet.
var _last_full_state_tick: int

# Server-side data

## While true, server will process input client commands for themselves.
var is_client_server: bool = true
## Commands that server needs to process next tick (peer : commands)
var _pending_commands: Dictionary[int, Array]
## Last command simulated by peer (peer : command)
var _previous_command: Dictionary[int, SnapCommand]
## Last command sequence processed (peer : sequence)
var _last_command_sequence: Dictionary[int, int]
## Client sequence of last event received from remote peer, sorted {peer : sequence}.
## This is the client's sequence for events they generate, not to be confused with
## server sequence for relayed events (see [member _last_acked_event_sequence]).
var _last_received_client_event_sequence: Dictionary[int, int]
## Next ID to assign to a new identifiable.
var _next_net_id: int = 1
## Identifiables registered since last broadcast.
var _pending_identifiables: Array[NetIdentifiable]
## Identifiable IDs removed since last broadcast.
var _pending_removed_identifiables: Array[int]
## Per-peer confirmed state, key : value. Only holds values we know arrived.
var _peer_confirmed_state: Dictionary[int, Dictionary]
## Per-peer state sent-but-unconfirmed, by tick: {tick: {key: value}}.
var _peer_pending_sends: Dictionary[int, Dictionary]
## Per-peer override for snapshot byte limit
var _peer_snapshot_byte_limits: Dictionary[int, int]
## Snapshots since last send, per peer, per net_id, for nodes with pending changes.
var _peer_priority_state: Dictionary[int, Dictionary]

# Shared server and client data

## Registered identifiables (id : node).
var _net_identifiables: Dictionary[int, NetIdentifiable]
## All registered [NetNode]s to be handled.
var _net_nodes: Array[NetNode]
## All registered [NetEvent]s to be handled.
var _net_events: Array[NetEvent]
## All registered [NetCompensator]s to be handled.
var _net_compensators: Array[NetCompensator]
## Current outbound event sequence.
var _event_sequence: int = 1
## Events pending broadcast on next tick, sorted as {sequence : event}.
## Sequences only cleared once they are acknowledged by all receivers.
## This means they may be sent redundently.
var _pending_out_events: Dictionary[int, SnapEvent]
## Events queued for processing, sorted {peer : {sequence : event}}.
## This is used for future events received out of order (example:
## seq 3, received before seq 2 has been received).
var _future_queued_events: Dictionary[int, Dictionary]
## Last acknowledged event sequence sorted {peer : sequence}.
## This ensures that peers do not skip a sequence number.
## This is server sequence for relayed events, not individual client
## sequence for events they generate (see [emember _last_received_client_event_sequence]).
var _last_acked_event_sequence: Dictionary[int, int]
## Events queued to be processed on future tick matching, or newer than their tick.
var upcoming_events: Array[SnapEvent]

## Current simulation tick
var current_tick: int:
	get: return _current_tick
	set(value):
		push_warning("'_current_tick' should not be manually set")
var _current_tick: int = 0

# Configuration data

## How often Snapshots should be sent from server to peers.
var snapshot_rate: float:
	get:
		return _tick_rate / float(maxi(1, _ticks_per_snapshot))
	set(value):
		var rate := maxf(1, value)
		_ticks_per_snapshot = maxi(1, roundi(_tick_rate / maxf(1.0, rate)))
var _ticks_per_snapshot: int = roundi(
	1e6 / ceili(1e6 / ProjectSettings.get_setting("SnapAPI/tick_rate", 60)) #_tick_rate
	/ maxf(1.0, ProjectSettings.get_setting("SnapAPI/snapshot_rate", 30))
	)

## How often input bundles should be sent from client to server.
var input_send_rate: float:
	get:
		return _tick_rate / float(maxi(1, _ticks_per_input_send))
	set(value):
		var rate := maxf(1, value)
		_ticks_per_input_send = maxi(1, roundi(_tick_rate / maxf(1.0, rate)))
var _ticks_per_input_send: int = roundi(
	1e6 / ceili(1e6 / ProjectSettings.get_setting("SnapAPI/tick_rate", 60)) #_tick_rate
	/ maxf(1.0, ProjectSettings.get_setting("SnapAPI/input_send_rate", 30))
	)

## Simulation tick rate in ticks per second
var tick_rate: float:
	get: return _tick_rate
	set(value):
		if multiplayer.has_multiplayer_peer():
			push_warning("Cannot set tick_rate while actively connected")
		else:
			_tick_rate = value
var _tick_rate: float:
	get:
		return 1e6 / float(maxf(1, _usecs_per_tick))
	set(value):
		var rate := maxi(1, value)
		_usecs_per_tick = maxi(1, ceili(1e6 / rate))
		_tick_delta = _usecs_per_tick / 1e6

## Max ticks that may be processed per frame
var max_ticks_per_frame: int:
	get: return _max_ticks_per_frame
	set(value):
		_max_ticks_per_frame = maxi(1, value)
var _max_ticks_per_frame: int = ProjectSettings.get_setting("SnapAPI/max_tick_per_frame", 8)

## Max events that can be simulated in a single tick, to avoid overload
var max_events_per_tick: int:
	get: return _max_events_per_tick
	set(value): _max_events_per_tick = maxi(1, _max_events_per_tick)
var _max_events_per_tick: int = ProjectSettings.get_setting("SnapAPI/max_events_per_tick", 64)

## Max redundant commands sent per bundle (to help with packet loss)
var max_redundant_commands: int:
	get: return _max_redundant_commands
	set(value):
		_max_redundant_commands = clampi(value, 0, _SEQ_BUFFER_SIZE - 1)
var _max_redundant_commands: int = ProjectSettings.get_setting("SnapAPI/max_redundant_commands", 3)

## Default max bytes per outbound snapshot payload
var base_snapshot_byte_limit: int:
	get: return _base_snapshot_byte_limit
	set(value):
		_base_snapshot_byte_limit = maxi(1, value)
var _base_snapshot_byte_limit: int = ProjectSettings.get_setting("SnapAPI/snapshot_byte_limit", 1200)

# Time calculation data

## Current mircoseconds between ticks
var _usecs_per_tick: int = ceili(1e6 / ProjectSettings.get_setting("SnapAPI/tick_rate", 60))
## Current seconds between ticks
var _tick_delta: float = ceili(1e6 / ProjectSettings.get_setting("SnapAPI/tick_rate", 60)) / 1e6
## Time accumulator in mircoseconds
var _usec_accumulator: int
## Carryover from delta float, to help keep precision
var _delta_carryover: float
## Whether the simulation is currently paused. Only the server may change this.
var is_paused: bool:
	get:
		return _is_paused
	set(value):
		push_warning("is_paused cannot be manually set, please use set_paused()")
var _is_paused: bool = false

func _ready() -> void:
	_command_history.resize(_SEQ_BUFFER_SIZE)
	_state_history.resize(_SEQ_BUFFER_SIZE)
	multiplayer.connected_to_server.connect(_timer_reset)
	multiplayer.peer_connected.connect(_send_identifiables_to_new_peer)
	pre_tick_loop.connect(_broadcast_pending_identifiables)
	pre_tick_loop.connect(_broadcast_pending_identifiable_removals)

func _process(delta: float) -> void:
	if not _is_paused:
		_handle_time(delta)
		_process_ticks()

## Updates [member _usec_accumulator] and [member _delta_carryover]
func _handle_time(delta) -> void:
	# Convert delta to usecs
	var _delta_usecs: int = delta * 1e6
	# Carryover excess float precision
	_delta_carryover += (delta * 1e6) - _delta_usecs
	while _delta_carryover >= 1.0:
		_delta_usecs += 1
		_delta_carryover -= 1.0
	# Add converted time to accumulator
	_usec_accumulator += _delta_usecs

## Looks to [member _usec_accumulator] and [member _usecs_per_tick] to
## determine if new ticks should be processed
func _process_ticks() -> void:
	if _usec_accumulator < _usecs_per_tick: return # Ignore if no ticks queued
	pre_tick_loop.emit()
	for t in mini(_usec_accumulator / _usecs_per_tick, max_ticks_per_frame):
		pre_tick.emit(_current_tick)
		_usec_accumulator -= _usecs_per_tick
		_current_tick += 1
		if multiplayer.is_server():
			_on_server_tick(_tick_delta)
		elif multiplayer.multiplayer_peer is OfflineMultiplayerPeer || multiplayer.multiplayer_peer == null:
			_on_offline_tick(_tick_delta)
		elif multiplayer.get_peers().has(1):
			_on_client_tick(_tick_delta)
			if _pending_snapshot:
				_on_snapshot_received(_pending_snapshot)
				_pending_snapshot = null
			_decay_render_offsets(_tick_delta)
		post_tick.emit(_current_tick)
	post_tick_loop.emit()

func _on_client_tick(delta: float) -> void:
	# Create new command and increment sequence
	var command := SnapCommand.new()
	_command_sequence += 1
	command.sequence = _command_sequence
	command.tick = _current_tick
	command.delta_time = delta
	# Ensure input data is populated before capturing commands
	for node in _owned_net_nodes():
		node.sample_input.emit(command)
	# Capture sampled data
	for node in _owned_net_nodes():
		node.capture_command(command)
	# Store command in buffer
	_command_history[command.sequence & _SEQ_BUFFER_MASK] = command
	# Run through events, ensuring only current or old ticks are simulated
	var store_for_future_tick: Array[SnapEvent] = []
	var events_simulated: int
	for event in upcoming_events:
		if event.tick > _current_tick:
			store_for_future_tick.append(event)
			continue # Don't erase yet
		# Ready to be simulated
		var net_event := _net_identifiables.get(event.net_id) as NetEvent
		if net_event == null: continue # Unresolved identifiable, drop for now
		net_event.apply_event(event.event_index, event.args, event.caller, event.tick)
		events_simulated += 1
		if events_simulated >= max_events_per_tick: break
	upcoming_events = store_for_future_tick # Clean up queue with only future events
	# Send pending events and command (plus redundant commands)
	if _current_tick % _ticks_per_input_send == 0:
		_collect_events()
		var bundle := SnapInputBundle.new()
		bundle.commands = _collect_redundant_commands(command.sequence)
		bundle.events = _outbound_events_for(1)
		bundle.ack_sequence = _last_processed_event_sequence
		bundle.last_received_snapshot_tick = _last_full_state_tick
		_receive_input_bundle.rpc_id(1, bundle.encode())
	# Predict command
	_simulate_command(command)
	# Store in state history
	var state := SnapState.new()
	state.sequence = command.sequence
	for node in _owned_net_nodes():
		node.capture_state(state)
	_state_history[command.sequence & _SEQ_BUFFER_MASK] = state

func _on_server_tick(delta: float) -> void:
	# Simulate all commands...
	for peer in multiplayer.get_peers():
		var queue: Array = _pending_commands.get(peer, [])
		var command: SnapCommand
		# Only 1 Command will be processed per tick
		# If no command is queued, then reuse last command received
		# This ensures consistent simulation timing between all peers
		if !queue.is_empty(): # Grab next command
			# Pop command from front of queue
			command = _pending_commands.get(peer, []).pop_front()
			_last_command_sequence[peer] = command.sequence
		else: # Reuse last command, or default to blank command
			command = _previous_command.get(peer, SnapCommand.new())
			command.tick = _current_tick
			command.delta_time = delta
			_previous_command[peer] = command
		# Simulate this peer's world
		for node in _peer_net_nodes(peer):
			node.apply_command(command)
			node.simulate_command.emit(command)
		# Update latest command processed for peer
	# Run through events, ensuring only current or old ticks are simulated
	var store_for_future_tick: Array[SnapEvent] = []
	var events_simulated: int
	for event in upcoming_events:
		if event.tick > _current_tick:
			store_for_future_tick.append(event)
			continue # Don't erase yet
		# Ready to be simulated
		var net_event := _net_identifiables.get(event.net_id) as NetEvent
		if net_event == null: continue # Unresolved identifiable, drop for now
		net_event.apply_event(event.event_index, event.args, event.caller, event.tick)
		events_simulated += 1
		if events_simulated >= max_events_per_tick: break
	upcoming_events = store_for_future_tick # Clean up queue with only future events
	# Send pending events
	_collect_events() # collect only once prior to loop
	# Client-Server simulates their own commands
	if is_client_server:
		var command := SnapCommand.new()
		command.sequence = _command_sequence
		command.tick = _current_tick
		command.delta_time = _tick_delta
		for node in _owned_net_nodes():
			node.sample_input.emit(command)
		for node in _owned_net_nodes():
			node.capture_command(command)
		_simulate_command(command)
	
	if _current_tick % _ticks_per_snapshot == 0:
		var world_state := SnapState.new()
		for node in _net_nodes:
			if is_instance_valid(node):
				node.capture_state(world_state)
		for peer in multiplayer.get_peers():
			var snapshot := _build_snapshot_for_peer(peer, world_state.data)
			snapshot.events = _outbound_events_for(peer)
			_receive_snapshot.rpc_id(peer, snapshot.encode())

func _on_offline_tick(delta: float) -> void:
	# Simulate local commands
	var command := SnapCommand.new()
	command.sequence = _command_sequence
	command.tick = _current_tick
	command.delta_time = _tick_delta
	for node in _owned_net_nodes():
		node.sample_input.emit(command)
	for node in _owned_net_nodes():
		node.capture_command(command)
	_simulate_command(command)

## Diffs current world data against peer's confirmed state, ordered owned-first.
func _build_snapshot_for_peer(peer: int, current_data: Dictionary) -> Snapshot:
	var snapshot := Snapshot.new()
	snapshot.server_tick = _current_tick
	snapshot.last_command_sequence = _last_command_sequence.get(peer, 0)
	var confirmed: Dictionary = _peer_confirmed_state.get(peer, {})
	var changed: Dictionary[int, Dictionary] = {} # net_id : {index: value}, unordered for now
	for key in current_data:
		if not confirmed.has(key) or confirmed[key] != current_data[key]:
			var net_id := NetIdentifiable.id_from_key(key)
			var index: int = key & 0xFFFF
			if not changed.has(net_id): changed[net_id] = {}
			changed[net_id][index] = current_data[key]
	var ordered := _order_by_priority(peer, changed)
	var limit: int = _peer_snapshot_byte_limits.get(peer, _base_snapshot_byte_limit)
	var included := _fit_groups_to_limit(ordered, limit)
	_update_priority_state(peer, changed, included)
	var delta := SnapStateDelta.new()
	delta.data = included
	snapshot.state_delta = delta
	# Track what we attempted to send this tick, pending confirmation
	if not delta.data.is_empty():
		var flat := delta.flatten()
		if not _peer_pending_sends.has(peer): _peer_pending_sends[peer] = {}
		_peer_pending_sends[peer][_current_tick] = flat
	return snapshot


## Includes whole net_id groups in order until adding the next would exceed [param limit].
## Always includes at least the first group, even if it alone exceeds the limit,
## this ensures an oversized group doesn't stall forever, never being sent.
func _fit_groups_to_limit(ordered: Dictionary[int, Dictionary], limit: int) -> Dictionary[int, Dictionary]:
	var included: Dictionary[int, Dictionary] = {}
	var running_size := 4 # group count header (u32)
	for net_id in ordered:
		var group_bytes: int = _encode_group(net_id, ordered[net_id]).size()
		if not included.is_empty() and running_size + group_bytes > limit:
			break
		running_size += group_bytes
		included[net_id] = ordered[net_id]
	return included

## Encodes a single [param net_id]'s property group, matching SnapStateDelta's per-group format.
func _encode_group(net_id: int, indices: Dictionary) -> PackedByteArray:
	var raw := StreamPeerBuffer.new()
	raw.put_32(net_id)
	var bitmask := 0
	for index in indices:
		bitmask |= (1 << index)
	raw.put_32(bitmask)
	for index in range(32):
		if bitmask & (1 << index):
			SnapEncodable.write_variant(raw, indices[index])
	return raw.data_array

## Orders changed groups by [param peer]'s owned nodes, and then by:
## [member NetNode.base_priority] * [member NetNode.multiplier] * snapshots-since-last-send.
func _order_by_priority(peer: int, changed: Dictionary[int, Dictionary]) -> Dictionary[int, Dictionary]:
	if not _peer_priority_state.has(peer): _peer_priority_state[peer] = {}
	var state: Dictionary = _peer_priority_state[peer]
	var scored: Array[Array] = []
	for net_id in changed:
		var node: NetNode = _net_identifiables.get(net_id)
		if node.get_multiplayer_authority() == peer:
			# Peer's owned nodes are always forced to top
			scored.append([net_id, INF])
		else: # Unowned
			var base_priority: float = node.base_priority
			var multiplier: float = node.priority_multiplier
			var starved_count: int = state.get(net_id, 1)
			scored.append([net_id, base_priority * multiplier * starved_count])
	scored.sort_custom(func(a, b): return a[1] > b[1])
	var ordered: Dictionary[int, Dictionary] = {}
	for entry in scored:
		ordered[entry[0]] = changed[entry[0]]
	return ordered

## Resets starve counters for sent groups, increments for skipped ones.
func _update_priority_state(peer: int, changed: Dictionary[int, Dictionary], included: Dictionary[int, Dictionary]) -> void:
	var state: Dictionary = _peer_priority_state[peer]
	for net_id in changed:
		if included.has(net_id):
			state.erase(net_id) # sent, restarts at 1 next time it has pending changes
		else:
			state[net_id] = state.get(net_id, 1) + 1

func _on_snapshot_received(snapshot: Snapshot) -> void:
	snapshot_received.emit(snapshot)
	for event in snapshot.events:
		_process_relayed_event(event)
	if snapshot.state_delta.data.is_empty():
		return
	var authoritative_state := SnapState.new()
	authoritative_state.sequence = snapshot.last_command_sequence
	authoritative_state.data = snapshot.state_delta.flatten()
	var acked_sequence: int = snapshot.last_command_sequence
	_last_acked_command_sequence = maxi(_last_acked_command_sequence, acked_sequence)
	# Discard history up to last processed sequence to avoid stale reads
	if acked_sequence >= 0:
		var acked_slot := acked_sequence & _SEQ_BUFFER_MASK
		if _command_history[acked_slot] != null and _command_history[acked_slot].sequence <= acked_sequence:
			_command_history[acked_slot] = null
	# Measure error as distance between prediction and server authority
	var predicted_state: SnapState = _state_history[acked_sequence & _SEQ_BUFFER_MASK]
	if predicted_state == null || predicted_state.sequence != acked_sequence:
		predicted_state = null
	var error := 0.0
	if predicted_state:
		for key in authoritative_state.data:
			if predicted_state.data.has(key):
				error = maxf(error, _variant_distance(predicted_state.data[key], authoritative_state.data[key]))
	
	# Rewind nodes to authoritative state...
	for node in _owned_net_nodes():
		node.apply_state(authoritative_state)
	
	# ...replay every command since, to catch up to present
	for seq in range(acked_sequence + 1, _command_sequence + 1):
		var command: SnapCommand = _command_history[seq & _SEQ_BUFFER_MASK]
		if command == null || command.sequence != seq:
			continue # fell out of buffer or was never sent
		_simulate_command(command)
		var state := SnapState.new()
		state.sequence = seq
		for node in _owned_net_nodes():
			node.capture_state(state)
		_state_history[seq & _SEQ_BUFFER_MASK] = state
	
	# Errors smaller than _RECONCILIATION_EPSILON can be ignored (floating point noise)
	if error > _RECONCILIATION_EPSILON:
		# Small error, can be blended over multiple ticks
		if predicted_state:
			for key in authoritative_state.data:
				if predicted_state.data.has(key):
					render_offsets[key] = _variant_subtract(predicted_state.data[key], authoritative_state.data[key])
	
	# Placeholder until interpolation is implemented
	for node in _not_owned_net_nodes():
		node.apply_state(authoritative_state)

## Applies a relayed event from the server, respecting sequence ordering.
func _process_relayed_event(event: SnapEvent) -> void:
	if event.sequence == _last_processed_event_sequence + 1: # Next event in sequence
		if event.caller != multiplayer.get_unique_id(): # Don't play if relayed from self
			upcoming_events.append(event)
		_last_processed_event_sequence = event.sequence
		var next_sequence := _last_processed_event_sequence + 1
		while _future_queued_events.has(1) and _future_queued_events[1].has(next_sequence):
			if event.caller != multiplayer.get_unique_id():
				upcoming_events.append(_future_queued_events[1][next_sequence])
			_last_processed_event_sequence = next_sequence
			_future_queued_events[1].erase(next_sequence)
			next_sequence += 1
	elif event.sequence < _last_processed_event_sequence: # Old sequence (junk it)
		return
	else: # Future sequence, arrived out-of-order
		if not _future_queued_events.has(1): _future_queued_events[1] = {}
		_future_queued_events[1][event.sequence] = event

## Runs [param command] against every locally-owned [NetNode].
func _simulate_command(command: SnapCommand) -> void:
	for node in _owned_net_nodes():
		node.apply_command(command)
		node.simulate_command.emit(command)

## [NetNode]s owned by self.
func _owned_net_nodes() -> Array[NetNode]:
	var result: Array[NetNode] = []
	for node in _net_nodes:
		if is_instance_valid(node) and node.is_multiplayer_authority():
			result.append(node)
	return result

## [NetNode]s NOT owned by self.
func _not_owned_net_nodes() -> Array[NetNode]:
	var result: Array[NetNode] = []
	for node in _net_nodes:
		if is_instance_valid(node) and node.is_multiplayer_authority():
			continue
		result.append(node)
	return result


## [NetNode]s owned by [param peer].
func _peer_net_nodes(peer: int) -> Array[NetNode]:
	var result: Array[NetNode] = []
	for node in _net_nodes:
		if is_instance_valid(node) and node.get_multiplayer_authority() == peer:
			result.append(node)
	return result

## Registers [param node] for handling. Typically called when it enters tree.
func register_net_node(node: NetNode) -> void:
	if !_net_nodes.has(node):
		_net_nodes.append(node)

## Unregisters [param node] from handling. Typically called when it exits tree.
func unregister_net_node(node: NetNode) -> void:
	_net_nodes.erase(node)

## Prep for sending over RPC. Each entry is Array of [sequence: int, data: Dictionary].
func _states_to_array(states: Array[SnapState]) -> Array[Array]:
	var out: Array[Array] = []
	for state in states:
		out.append([state.sequence, state.data])
	return out

## Blends [member render_offsets] toward zero every client tick.
func _decay_render_offsets(delta: float) -> void:
	if render_offsets.is_empty():
		return
	var decay: float = clampf(delta / 0.15, 0.0, 1.0)
	for key in render_offsets.keys():
		var offset: Variant = render_offsets[key]
		match typeof(offset):
			TYPE_FLOAT, TYPE_INT, TYPE_VECTOR2, TYPE_VECTOR3:
				offset = offset * (1.0 - decay)
				if _variant_distance(offset, _variant_zero(offset)) <= _RECONCILIATION_EPSILON:
					render_offsets.erase(key)
				else:
					render_offsets[key] = offset
			_:
				render_offsets.erase(key) # not a smoothable type

func _variant_zero(sample: Variant) -> Variant:
	match typeof(sample):
		TYPE_VECTOR2: return Vector2.ZERO
		TYPE_VECTOR3: return Vector3.ZERO
		_: return 0.0

func _variant_distance(a: Variant, b: Variant) -> float:
	match typeof(a):
		TYPE_FLOAT, TYPE_INT:
			return absf(float(a) - float(b))
		TYPE_VECTOR2:
			return (a as Vector2).distance_to(b)
		TYPE_VECTOR3:
			return (a as Vector3).distance_to(b)
		_:
			return 0.0 if a == b else INF

func _variant_subtract(a: Variant, b: Variant) -> Variant:
	match typeof(a):
		TYPE_FLOAT, TYPE_INT, TYPE_VECTOR2, TYPE_VECTOR3:
			return a - b
		_:
			return null

@rpc("any_peer", "unreliable_ordered", "call_remote")
func _receive_input_bundle(encoded_bundle: PackedByteArray) -> void:
	if not multiplayer.is_server(): return # Only peer -> server
	if _is_paused: return # Shouldn't queue commands while paused
	var peer := multiplayer.get_remote_sender_id()
	var bundle := SnapInputBundle.new().decode(encoded_bundle)

	# Queue new commands only, skipping anything already simulated or already queued
	var last_queued: int = _last_queued_command_sequence.get(peer, _last_command_sequence.get(peer, 0))
	for command in bundle.commands:
		if command.sequence <= last_queued:
			continue # Already simulated or already queued from an earlier bundle
		if not _pending_commands.has(peer):
			_pending_commands[peer] = []
		_pending_commands[peer].append(command)
		last_queued = command.sequence
	_last_queued_command_sequence[peer] = last_queued

	# Ack once for the whole bundle, then process events in order
	_last_acked_event_sequence[peer] = bundle.ack_sequence
	_confirm_peer_snapshot(peer, bundle.last_received_snapshot_tick)
	for event in bundle.events:
		_process_incoming_event(peer, event)

func _process_incoming_event(peer: int, event: SnapEvent) -> void:
	var net_event := _net_identifiables.get(event.net_id) as NetEvent
	if net_event == null: return # Unresolved identifiable, ignore for now
	if not net_event.has_permission(peer):
		return
	var expected_sequence: int = _last_received_client_event_sequence.get(peer, 0) + 1
	if event.sequence == expected_sequence:
		_last_received_client_event_sequence[peer] = event.sequence
		expected_sequence += 1
		event.sequence = _event_sequence
		_event_sequence += 1
		upcoming_events.append(event)
		_pending_out_events[event.sequence] = event
		while _future_queued_events.has(peer) and _future_queued_events[peer].has(expected_sequence):
			_last_received_client_event_sequence[peer] = expected_sequence
			event = _future_queued_events[peer][expected_sequence]
			_future_queued_events[peer].erase(expected_sequence)
			event.sequence = _event_sequence
			_event_sequence += 1
			upcoming_events.append(event)
			_pending_out_events[_event_sequence] = event
			expected_sequence += 1
	elif event.sequence < expected_sequence:
		return # Outdated sequence, ignore
	else:
		if not _future_queued_events.has(peer): _future_queued_events[peer] = {}
		_future_queued_events[peer][event.sequence] = event # Future sequence, queue for later

## Gathers latest command + redundant unacked commands, oldest to newest.
func _collect_redundant_commands(latest_sequence: int) -> Array[SnapCommand]:
	var out: Array[SnapCommand] = []
	var span: int = _ticks_per_input_send + _max_redundant_commands
	var start_sequence: int = maxi(_last_acked_command_sequence + 1, latest_sequence - span + 1)
	for seq in range(start_sequence, latest_sequence + 1):
		var command: SnapCommand = _command_history[seq & _SEQ_BUFFER_MASK]
		if command != null and command.sequence == seq:
			out.append(command)
	return out

## Events not yet acknowledged by [param peer].
func _outbound_events_for(peer: int) -> Array[SnapEvent]:
	var out: Array[SnapEvent] = []
	for sequence in _pending_out_events:
		if sequence < _last_acked_event_sequence.get(peer, 0):
			continue
		out.append(_pending_out_events[sequence])
	return out

@rpc("authority", "unreliable_ordered", "call_remote")
func _receive_snapshot(encoded_snapshot) -> void:
	if multiplayer.is_server(): return # Only server -> peer
	# Decode
	var snapshot := Snapshot.new().decode(encoded_snapshot)
	var flat := snapshot.state_delta.flatten()
	if _has_unresolved_identifiables(flat):
		# Unknown net_id referenced, skip and don't ack
		return
	if _last_full_state == null:
		_last_full_state = SnapState.new()
	for key in flat:
		_last_full_state.data[key] = flat[key]
	_last_full_state.sequence = snapshot.last_command_sequence
	_last_full_state_tick = snapshot.server_tick
	# Add command to be reconciled
	_pending_snapshot = snapshot

## Check if snapshot contains reference to unknown ID
func _has_unresolved_identifiables(data: Dictionary) -> bool:
	for key in data:
		if not _net_identifiables.has(NetIdentifiable.id_from_key(key)):
			return true
	return false

## Sets up time when connecting to server
func _timer_reset() -> void:
	_current_tick = 0
	_usec_accumulator = 0
	_delta_carryover = 0.0
	if not multiplayer.is_server():
		_request_time.rpc_id(1, Time.get_ticks_usec())

@rpc("any_peer", "reliable", "call_remote")
func _request_time(client_send_time: int) -> void:
	if not multiplayer.is_server(): return # Only peer -> server
	var peer := multiplayer.get_remote_sender_id()
	_receive_time.rpc_id(peer,
		_tick_rate,
		_usec_accumulator,
		_current_tick,
		client_send_time
	)

@rpc("authority", "reliable", "call_remote")
func _receive_time(server_rate: int, accumulator: int, tick: int, client_send_time: int) -> void:
	if multiplayer.is_server(): return # Only server -> peer
	# Estimate RTT from original request send time
	var rtt_usec := Time.get_ticks_usec() - client_send_time
	# Ensure we are synced with server rate
	_tick_rate = server_rate
	# Get time based on sent time plus estimated RTT
	var total_usecs := (tick * _usecs_per_tick) + accumulator + maxi(0, rtt_usec / 2)
	_current_tick = total_usecs / _usecs_per_tick
	_usec_accumulator = total_usecs % _usecs_per_tick

func set_paused(paused: bool) -> void:
	# Clients cannot pause
	if not multiplayer.is_server()\
	|| multiplayer.multiplayer_peer is OfflineMultiplayerPeer or multiplayer.multiplayer_peer == null:
		push_warning("Clients cannot pause simulation")
		return
	_is_paused = paused
	# Don't allow commands captured before the pause to execute afterward
	if paused:
		_pending_commands.clear()
	# Server and clients need to agree on the exact pause time
	_sync_pause_state.rpc(
		_is_paused,
		_current_tick,
		_usec_accumulator
	)
	
	pause_state_changed.emit(paused)

@rpc("authority", "reliable", "call_remote")
func _sync_pause_state(paused: bool, server_tick: int, server_accumulator: int) -> void:
	if multiplayer.is_server(): return # Only server -> peers
	_is_paused = paused
	
	# Match server clock
	if paused: # Time is fixed, no need to account for RTT
		_current_tick = server_tick
		_usec_accumulator = server_accumulator
	else: # Must send request to account for RTT when unpausing
		_request_time.rpc_id(1, Time.get_ticks_usec())
	
	# Clear history
	_command_history.fill(null)
	_state_history.fill(null)
	_pending_snapshot = null
	render_offsets.clear()
	
	pause_state_changed.emit(paused)

## Registers [param node] for handling. Typically called when it enters tree.
func register_net_event(node: NetEvent) -> void:
	if !_net_events.has(node):
		_net_events.append(node)

## Unregisters [param node] from handling. Typically called when it exits tree.
func unregister_net_event(node: NetEvent) -> void:
	_net_events.erase(node)

## Collects all pending events and adds them to [member _pending_out_events].
func _collect_events() -> Dictionary[int, SnapEvent]:
	for net_event in _net_events:
		for pending_event in net_event.consume_pending():
			var event := SnapEvent.new()
			event.sequence = _event_sequence
			_event_sequence += 1
			event.tick = _current_tick
			event.net_id = net_event.net_id
			event.event_index = pending_event[0]
			event.args = pending_event[1]
			event.caller = multiplayer.get_unique_id()
			_pending_out_events[event.sequence] = event
	return _pending_out_events

## Registers [param node] for handling. Typically called when it enters tree.
func register_net_compensator(node: NetCompensator) -> void:
	if !_net_compensators.has(node):
		_net_compensators.append(node)

## Unregisters [param node] from handling. Typically called when it exits tree.
func unregister_net_compensator(node: NetCompensator) -> void:
	_net_compensators.erase(node)

## Rewinds all [member _net_compensator]s to [param tick].
func rewind_compensators(tick: int) -> void:
	for comp in _net_compensators:
		comp.rewind_to(tick)

## Restores all [member _net_compensator]s after [method rewind_compensators] is called.
func restore_compensators() -> void:
	for comp in _net_compensators:
		comp.restore()

## Registers [param node] for identification. Typically called when it enters tree.
func register_net_identifiable(node: NetIdentifiable) -> void:
	if multiplayer.is_server() \
	|| multiplayer.multiplayer_peer is OfflineMultiplayerPeer \
	|| multiplayer.multiplayer_peer == null:
		node.net_id = _next_net_id
		_next_net_id += 1
		_net_identifiables[node.net_id] = node
		_pending_identifiables.append(node)
	else: # Client may have received the ID before the node existed
		var path := node.get_path()
		if _pending_path_ids.has(path):
			node.net_id = _pending_path_ids[path]
			_net_identifiables[node.net_id] = node
			_pending_path_ids.erase(path)

## Unregisters [param node] from identification. Typically called when it exits tree.
func unregister_net_identifiable(node: NetIdentifiable) -> void:
	if _pending_identifiables.has(node):
		_pending_identifiables.erase(node) # Never broadcast, nothing to remove
	elif node.net_id != -1:
		_pending_removed_identifiables.append(node.net_id) # Already known to peers, must notify
	if node.net_id != -1:
		_net_identifiables.erase(node.net_id)

## Sends newly registered identifiables to all peers, bundled into one packet.
func _broadcast_pending_identifiables() -> void:
	if not multiplayer.is_server(): return # Only server broadcasts
	if _pending_identifiables.is_empty(): return # Nothing to broadcast
	var identification := SnapIdentification.new()
	for node in _pending_identifiables:
		if not is_instance_valid(node): continue
		identification.ids.append(node.net_id)
		identification.paths.append(node.get_path())
	_pending_identifiables.clear()
	if identification.ids.is_empty(): return
	for peer in multiplayer.get_peers():
		_receive_identification.rpc_id(peer, identification.encode())

## Sends every currently active identifiable to a newly connected peer.
func _send_identifiables_to_new_peer(peer: int) -> void:
	if not multiplayer.is_server(): return
	var identification := SnapIdentification.new()
	for id in _net_identifiables:
		var node := _net_identifiables[id]
		if not is_instance_valid(node): continue
		identification.ids.append(id)
		identification.paths.append(node.get_path())
	if identification.ids.is_empty(): return
	_receive_identification.rpc_id(peer, identification.encode())

@rpc("authority", "reliable", "call_remote")
func _receive_identification(encoded_identification: PackedByteArray) -> void:
	if multiplayer.is_server(): return # Only server -> peer
	var identification := SnapIdentification.new().decode(encoded_identification)
	for n in identification.ids.size():
		var id: int = identification.ids[n]
		var path: NodePath = identification.paths[n]
		var node := get_node_or_null(path)
		if node is NetIdentifiable:
			node.net_id = id
			_net_identifiables[id] = node
		else: # Node hasn't spawned yet, resolve when it registers
			_pending_path_ids[path] = id

## Sends removed identifiable IDs to all peers, bundled into one packet.
func _broadcast_pending_identifiable_removals() -> void:
	if not multiplayer.is_server(): return # Server -> peer only
	if _pending_removed_identifiables.is_empty(): return # Nothing to broadcast
	var raw := StreamPeerBuffer.new()
	raw.put_32(_pending_removed_identifiables.size())
	for id in _pending_removed_identifiables:
		raw.put_32(id)
	_pending_removed_identifiables.clear()
	for peer in multiplayer.get_peers():
		_receive_identification_removal.rpc_id(peer, raw.data_array)

@rpc("authority", "reliable", "call_remote")
func _receive_identification_removal(encoded_ids: PackedByteArray) -> void:
	if multiplayer.is_server(): return # Only server -> peer
	var buffer := StreamPeerBuffer.new()
	buffer.data_array = encoded_ids
	var count := buffer.get_32()
	for n in count:
		_net_identifiables.erase(buffer.get_32())

## Merges a peer's confirmed tick into their confirmed state and clears earlier pending entries.
func _confirm_peer_snapshot(peer: int, tick: int) -> void:
	if not _peer_pending_sends.has(peer): return
	if not _peer_pending_sends[peer].has(tick): return
	if not _peer_confirmed_state.has(peer): _peer_confirmed_state[peer] = {}
	for key in _peer_pending_sends[peer][tick]:
		_peer_confirmed_state[peer][key] = _peer_pending_sends[peer][tick][key]
	for pending_tick in _peer_pending_sends[peer].keys():
		if pending_tick <= tick:
			_peer_pending_sends[peer].erase(pending_tick)

## Sets a custom snapshot byte limit for [param peer]. Overrides the default.
func set_snapshot_byte_limit(peer: int, limit: int) -> void:
	_peer_snapshot_byte_limits[peer] = maxi(1, limit)
