## Global API for SnapGd
extends Node

## TODO: Settings for tick-rate  (30-128hz), max ticks per frame, and snapshot-rate(10-30hz)
## TODO: Settings for interpolation-delay (50-150ms), reconciliation threshold, max-rewind (200-300ms)

## Sequence buffer size for outbound packets
const _SEQ_BUFFER_SIZE := 128 # (MUST be power of 2)
const _SEQ_BUFFER_MASK := _SEQ_BUFFER_SIZE - 1

const _ERROR_THRESHOLD := 1.0
const _EPSILON := 8.854 * 10e12

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

var _command_sequence: int
var _command_history: Array[SnapCommand]
var _state_history: Array[SnapState]

var _pending_commands: Dictionary[int, Array]
var _last_command_sequence: Dictionary[int, int]

var ticks_per_snapshot: int

var current_tick: int

## Simulation tick rate in ticks per second
var _tick_rate: float:
	get: return 1e6 / float(maxi(1, _usecs_per_tick))
	set(value): _usecs_per_tick = maxi(1, ceili(1e6 / float(value)))
## Current mircoseconds between ticks
var _usecs_per_tick: int = 16667 # 60/s

## Time accumulator in mircoseconds
var _usec_accumulator: int
## Carryover from delta float, to help keep precision
var _delta_carryover: float

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
	var tick_delta: float = _usecs_per_tick / 1e6 # convert mircoseconds to seconds
	pre_tick_loop.emit()
	for t in mini(_usec_accumulator / _usecs_per_tick, _MAX_TICKS_PER_FRAME):
		pre_tick.emit(current_tick)
		_usec_accumulator -= _usecs_per_tick
		current_tick += 1
		if multiplayer.is_server():
			## TODO: check for new packets to apply / update acks
			_on_server_tick(_tick_rate)
			## TODO: store snapshot history
		else:
			_on_client_tick(_tick_rate)
			## TODO: check for new packets to reconicle/interpolate
			## TODO: blend reconciled-packets
		post_tick.emit(current_tick)
	post_tick_loop.emit()

func _on_client_tick(delta: float) -> void:
	# Create new command and increment sequence
	var command := SnapCommand.new()
	# Ensure input data is populated before capturing commands
	sample_input.emit(command)
	_command_sequence += 1
	command.sequence = _command_sequence
	command.tick = current_tick
	command.delta_time = delta
	# Add command to back of queue
	_command_history.push_back(command)
	# TODO: send to server
	# TODO: simulate command
	# TODO: push state history
	# TODO: finish rendering simulation

func _on_server_tick(delta: float) -> void:
	# Simulate all commands...
	for peer in multiplayer.get_peers():
		# Pop command from front of queue
		var command: SnapCommand = _pending_commands.get(peer, []).pop_front()
		if command == null:
			continue # No comman arrived
		# Simulate this peer's world
		simulate_command.emit(command)
		# Update latest command processed for peer
		_last_command_sequence[peer] = command.sequence
	
	simulate_world.emit(delta)
	
	current_tick += 1
	
	if current_tick % ticks_per_snapshot == 0:
		for peer in multiplayer.get_peers():
			var snapshot := _build_snapshot(peer)
			# TODO: send to clients

func _build_snapshot(peer: int) -> Snapshot:
	var snapshot := Snapshot.new()
	snapshot.server_tick = current_tick
	snapshot.last_command_sequence = _last_command_sequence[peer]
	# TODO: Record snapshot data
	return snapshot

func _on_snapshot_received(snapshot: Snapshot) -> void:
	# TODO: discard history up to last processed sequence
	
	var error: float
	# TODO: Measure error distance
	
	# TODO: rewind
	
	for command in _command_history:
		pass
		# TODO: simulate state
		# TODO: update state history
	
	if error > _ERROR_THRESHOLD:
		pass
		# TODO: hard snap
	elif error > _EPSILON:
		pass
		# TODO: offset rendering, but NOT simulation

## TODO: Add interpolation handling

## TODO: Add delta compression handling
