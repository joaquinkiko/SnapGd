##
class_name Snapshot extends SnapEncodable

##
var server_tick: int
##
var last_command_sequence: int
##
var state_delta: SnapStateDelta
## Relayed events piggybacking on this snapshot.
var events: Array[SnapEvent]

func encode() -> PackedByteArray:
	var raw := StreamPeerBuffer.new()
	write_int(raw, server_tick)
	write_variant(raw, last_command_sequence)
	write_bytes(raw, state_delta.encode())
	write_int(raw, events.size())
	for n in events.size():
		write_bytes(raw, events[n].encode())
	return raw.data_array

func decode(bytes: PackedByteArray) -> Snapshot:
	var buffer := StreamPeerBuffer.new()
	buffer.data_array = bytes
	server_tick = read_int(buffer)
	last_command_sequence = read_variant(buffer)
	state_delta = SnapStateDelta.new().decode(read_bytes(buffer))
	events.resize(read_int(buffer))
	for n in events.size():
		events[n] = SnapEvent.new().decode(read_bytes(buffer))
	return self
