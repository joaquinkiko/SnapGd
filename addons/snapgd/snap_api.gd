## Global API for SnapGd
extends Node

## Sequence buffer size for outbound packets
const _SEQ_BUFFER_SIZE := 128 # (MUST be power of 2)
const _SEQ_BUFFER_MASK := _SEQ_BUFFER_SIZE - 1

const _ERROR_THRESHOLD := 1.0
const _EPSILON := 8.854 * 10e12

var _command_sequence: int
var _command_history: Array[SnapCommand]
var _state_history: Array[SnapState]

var _pending_commands: Dictionary[int, Array]
var _last_command_sequence: Dictionary[int, int]

var ticks_per_snapshot: int

var current_tick: int

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
