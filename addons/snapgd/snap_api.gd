## Global API for SnapGd
extends Node

## Sequence buffer size for outbound packets
const _SEQ_BUFFER_SIZE := 128 # (MUST be power of 2)
const _SEQ_BUFFER_MASK := _SEQ_BUFFER_SIZE - 1

const _ERROR_THRESHOLD := 1.0
const _EPSILON := 8.854 * 10e12

const _MAX_TICKS_PER_FRAME := 8

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
	## TODO: pre-tick loop signal
	for t in mini(_usec_accumulator / _usecs_per_tick, _MAX_TICKS_PER_FRAME):
		## TODO: pre-tick signal
		_usec_accumulator -= _usecs_per_tick
		current_tick += 1
		if multiplayer.is_server():
			_on_server_tick(_tick_rate)
		else:
			_on_client_tick(_tick_rate)
		## TODO: post-tick signal
	## TODO: post-tick loop signal

func _on_client_tick(delta: float) -> void:
	# Create new command and increment sequence
	var command := SnapCommand.new()
	# TODO: Sample input
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
		_last_command_sequence[peer] = command.sequence
	
	# Simulate non-peer owned objects
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
