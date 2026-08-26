## Global API for SnapGd
extends Node

## Sequence buffer size for outbound packets
const _SEQ_BUFFER_SIZE := 128 # (MUST be power of 2)
const _SEQ_BUFFER_MASK := _SEQ_BUFFER_SIZE - 1
## Prediction errors below this should be ignored (assume floating point noise)
const _RECONCILIATION_EPSILON := 0.001
## Max redundant commands sent per bundle (includes the latest)
const _COMMAND_REDUNDANCY := 3

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
var render_offsets: Dictionary[StringName, Variant]
## Sequence of the last event processed by the client.
## NOT last event received, as some events may be queued for later.
var _last_processed_event_sequence: int
## Highest command sequence server has acknowledged via snapshot.
var _last_acked_command_sequence: int
## Highest command sequence queued server-side, per peer
## to prevents re-queueing overlap between bundles.
var _last_queued_command_sequence: Dictionary[int, int]

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

# Shared server and client data

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
	for event in upcoming_events:
		if event.tick > _current_tick:
			store_for_future_tick.append(event)
			continue # Don't erase yet
		# Ready to be simulated
		get_node(event.node_path).apply_event(event.event_name, event.args, event.caller, event.tick)
	upcoming_events = store_for_future_tick # Clean up queue with only future events
	# Send pending events and command (plus redundant commands)
	_collect_events()
	var bundle := SnapInputBundle.new()
	bundle.commands = _collect_redundant_commands(command.sequence)
	bundle.events = _outbound_events_for(1)
	bundle.ack_sequence = _last_processed_event_sequence
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
		for node in _not_owned_net_nodes():
			node.apply_command(command)
			node.simulate_command.emit(command)
		# Update latest command processed for peer
	# Run through events, ensuring only current or old ticks are simulated
	var store_for_future_tick: Array[SnapEvent] = []
	for event in upcoming_events:
		if event.tick > _current_tick:
			store_for_future_tick.append(event)
			continue # Don't erase yet
		# Ready to be simulated
		get_node(event.node_path).apply_event(event.event_name, event.args, event.caller, event.tick)
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
		for peer in multiplayer.get_peers():
			var snapshot := _build_snapshot(peer)
			snapshot.events = _outbound_events_for(peer)
			# Send to peer (unreliable)
			_receive_snapshot.rpc_id(peer,
				snapshot.encode()
			)

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

func _build_snapshot(peer: int) -> Snapshot:
	var snapshot := Snapshot.new()
	snapshot.server_tick = _current_tick
	snapshot.last_command_sequence = _last_command_sequence.get(peer, 0)
	var state := SnapState.new()
	state.sequence = snapshot.last_command_sequence
	for node in _net_nodes:
		if is_instance_valid(node):
			node.capture_state(state)
	snapshot.states.append(state)
	return snapshot

func _on_snapshot_received(snapshot: Snapshot) -> void:
	if snapshot.states.is_empty():
		return
	snapshot_received.emit(snapshot)
	for event in snapshot.events:
		_process_relayed_event(event)
	var authoritative_state: SnapState = snapshot.states.back()
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
	for event in bundle.events:
		_process_incoming_event(peer, event)

func _process_incoming_event(peer: int, event: SnapEvent) -> void:
	if not get_node(event.node_path).has_permission(peer):
		return # Silent return if not permission
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
	var start_sequence: int = maxi(_last_acked_command_sequence + 1, latest_sequence - _COMMAND_REDUNDANCY + 1)
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
	# Add command to be reconciled
	_pending_snapshot = snapshot

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
			event.node_path = net_event.get_path()
			event.event_name = pending_event[0]
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

## TODO: Add delta compression handling (Snapshot.baseline_tick will
## eventually be used to compress states_data in _receive_snapshot
