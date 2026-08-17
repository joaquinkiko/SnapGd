## Global API for SnapGd
extends Node

## Ticks-per-second
const _DEFAULT_TICK_RATE := 60
const _MIN_TICK_RATE := 30
const _MAX_TICK_RATE := 128
## Snapshots-per-second
const _DEFAULT_SNAPSHOT_RATE := 60
const _MIN_SNAPSHOT_RATE := 30
const _MAX_SNAPSHOT_RATE := 128
## Interpolation delay in msec
const _DEFAULT_LERP_DELAY := 100.0
const _MIN_LERP_DELAY := 50.0
const _MAX_LERP_DELAY := 150.0
## Max lag-compensation rewinding in msec
const _DEFAULT_REWIND_TIME := 250.0
const _MIN_REWIND_TIME := 200.0
const _MAX_REWIND_TIME := 300.0
## Sequence buffer size for outbound packets
const _SEQ_BUFFER_SIZE := 128 # (MUST be power of 2)
const _SEQ_BUFFER_MASK := _SEQ_BUFFER_SIZE - 1
## Prediction errors beyond this should be hard-snapped
const _RECONCILIATION_THRESHOLD := 1.0
## Prediction errors below this should be ignored (assume floating point noise)
const _RECONCILIATION_EPSILON := 0.001
## Max ticks to process per frame to prevent death loop
const _MAX_TICKS_PER_FRAME := 8

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
## Emitted on the client right before a new [SnapCommand] is captured.
## Client input should be sampled during this time.
signal sample_input(command: SnapCommand)
## Emitted whenever a peer-owned command should be simulated (client
## prediction, or server-side authoritative simulation of a peer's command).
signal simulate_command(command: SnapCommand)
## Emitted once per server tick for objects that aren't owned by any peer
## (e.g. moving platforms, projectiles, NPCs).
signal simulate_world(delta: float)

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
var _render_offsets: Dictionary[StringName, Variant]

# Server-side data

## While true, server will process input client commands for themselves.
var is_client_server: bool = true
## Commands that server needs to process next tick (peer : commands)
var _pending_commands: Dictionary[int, Array]
## Last command sequence processed (peer : sequence)
var _last_command_sequence: Dictionary[int, int]

# Shared server and client data

## All registered [NetNode]s to be handled.
var _net_nodes: Array[NetNode]

## Current simulation tick
var current_tick: int:
	get: return _current_tick
	set(value):
		push_warning("'_current_tick' should not be manually set")
var _current_tick: int = 0

# Configuration data

## How far in past (in msec) remote peers are rendered.
var interpolation_delay_msec: float:
	get: return _interpolation_delay_msec
	set(value): _interpolation_delay_msec = clampf(value, _MIN_LERP_DELAY, _MAX_LERP_DELAY)
var _interpolation_delay_msec: float = _DEFAULT_LERP_DELAY

## How far back (in msec) server allows for lag-compensation rewinding.
var max_rewind_msec: float:
	get: return _max_rewind_msec
	set(value): _max_rewind_msec = clampf(value, _MIN_REWIND_TIME, _MAX_REWIND_TIME)
var _max_rewind_msec: float = _DEFAULT_REWIND_TIME

## How often Snapshots should be sent from server to peers.
var snapshot_rate: float:
	get:
		return _tick_rate / float(maxi(1, _ticks_per_snapshot))
	set(value):
		var rate := clampf(value, _MIN_SNAPSHOT_RATE, _MAX_SNAPSHOT_RATE)
		_ticks_per_snapshot = maxi(1, roundi(_tick_rate / maxf(1.0, rate)))
var _ticks_per_snapshot: int = roundi(
	1e6 / ceili(1e6 / _DEFAULT_TICK_RATE) #_tick_rate
	/ maxf(1.0, _DEFAULT_SNAPSHOT_RATE)
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
		return 1e6 / float(maxi(1, _usecs_per_tick))
	set(value):
		var rate := clampf(value, _MIN_TICK_RATE, _MAX_TICK_RATE)
		_usecs_per_tick = maxi(1, ceili(1e6 / rate))
		_tick_delta = _usecs_per_tick / 1e6

# Time calculation data

## Current mircoseconds between ticks
var _usecs_per_tick: int = ceili(1e6 / _DEFAULT_TICK_RATE)
## Current seconds between ticks
var _tick_delta: float = ceili(1e6 / _DEFAULT_TICK_RATE) / 1e6
## Time accumulator in mircoseconds
var _usec_accumulator: int
## Carryover from delta float, to help keep precision
var _delta_carryover: float

func _ready() -> void:
	_command_history.resize(_SEQ_BUFFER_SIZE)
	_state_history.resize(_SEQ_BUFFER_SIZE)
	multiplayer.connected_to_server.connect(_timer_reset)

func _process(delta: float) -> void:
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
	for t in mini(_usec_accumulator / _usecs_per_tick, _MAX_TICKS_PER_FRAME):
		pre_tick.emit(_current_tick)
		_usec_accumulator -= _usecs_per_tick
		_current_tick += 1
		if multiplayer.is_server():
			_on_server_tick(_tick_delta)
			if is_client_server:
				_on_client_tick(_tick_delta)
		else:
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
	sample_input.emit(command)
	# Capture sampled data
	for node in _owned_net_nodes():
		node.capture_command(command)
	# Store command in buffer
	_command_history[command.sequence & _SEQ_BUFFER_MASK] = command
	# Send to server (unreliable)
	if multiplayer.is_server():
		_receive_command(
			command.sequence,
			command.tick,
			command.delta_time,
			command.data
		)
	else:
		_receive_command.rpc_id(1,
			command.sequence,
			command.tick,
			command.delta_time,
			command.data
		)
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
		while !queue.is_empty():
			# Pop command from front of queue
			var command: SnapCommand = _pending_commands.get(peer, []).pop_front()
			# Simulate this peer's world
			simulate_command.emit(command)
			# Update latest command processed for peer
			_last_command_sequence[peer] = command.sequence
	
	simulate_world.emit(delta)
	
	if _current_tick % _ticks_per_snapshot == 0:
		for peer in multiplayer.get_peers():
			var snapshot := _build_snapshot(peer)
			# Send to peer (unreliable)
			_receive_snapshot.rpc_id(
				peer,
				snapshot.server_tick,
				snapshot.baseline_tick,
				snapshot.last_command_sequence,
				_states_to_array(snapshot.states)
			)

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
	var authoritative_state: SnapState = snapshot.states.back()
	var acked_sequence: int = snapshot.last_command_sequence
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
	
	if error > _RECONCILIATION_THRESHOLD:
		# Large error, should be snapped to correction
		_render_offsets.clear()
	elif error > _RECONCILIATION_EPSILON:
		# Small error, can be blended over multiple ticks
		if predicted_state:
			for key in authoritative_state.data:
				if predicted_state.data.has(key):
					_render_offsets[key] = _variant_subtract(predicted_state.data[key], authoritative_state.data[key])

## Runs [param command] against every locally-owned [NetNode].
func _simulate_command(command: SnapCommand) -> void:
	for node in _owned_net_nodes():
		node.apply_command(command)
	simulate_command.emit(command)

## [NetNode]s owned by self.
func _owned_net_nodes() -> Array[NetNode]:
	var result: Array[NetNode] = []
	for node in _net_nodes:
		if is_instance_valid(node) and node.is_multiplayer_authority():
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
	var out: Array = []
	for state in states:
		out.append([state.sequence, state.data])
	return out

## Blends [member render_offsets] toward zero every client tick.
func _decay_render_offsets(delta: float) -> void:
	if _render_offsets.is_empty():
		return
	var decay: float = clampf(delta / 0.15, 0.0, 1.0)
	for key in _render_offsets.keys():
		var offset: Variant = _render_offsets[key]
		match typeof(offset):
			TYPE_FLOAT, TYPE_INT, TYPE_VECTOR2, TYPE_VECTOR3:
				offset = offset * (1.0 - decay)
				if _variant_distance(offset, _variant_zero(offset)) <= _RECONCILIATION_EPSILON:
					_render_offsets.erase(key)
				else:
					_render_offsets[key] = offset
			_:
				_render_offsets.erase(key) # not a smoothable type

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
func _receive_command(sequence: int, tick: int, delta_time: float, data: Dictionary) -> void:
	if not multiplayer.is_server(): return # Only peer -> server
	var peer := multiplayer.get_remote_sender_id()
	# Check if command is stale or duplicate
	if _last_command_sequence.get(peer, 0) >= sequence: return
	var command := SnapCommand.new()
	command.sequence = sequence
	command.tick = tick
	command.delta_time = delta_time
	command.data = data
	# Add command to be processed
	if not _pending_commands.has(peer):
		_pending_commands[peer] = []
	_pending_commands[peer].append(command)

@rpc("authority", "unreliable_ordered", "call_remote")
func _receive_snapshot(server_tick: int, baseline_tick: int, last_command_sequence: float, states_data: Array[Array]) -> void:
	if multiplayer.is_server(): return # Only server -> peer
	var snapshot := Snapshot.new()
	snapshot.server_tick = server_tick
	snapshot.baseline_tick = baseline_tick
	snapshot.last_command_sequence = last_command_sequence
	for entry in states_data:
		var state := SnapState.new()
		state.sequence = entry[0]
		state.data = entry[1]
		snapshot.states.append(state)
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
	## TODO: account for RTT
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

## TODO: Add interpolation handling (planned NetInterpolator node will read offsets
## plus buffered snapshots, to delay by interpolation_delay_msec to smooth rendering)

## TODO: Add delta compression handling (Snapshot.baseline_tick will
## eventually be used to compress states_data in _receive_snapshot
