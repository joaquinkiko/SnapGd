## Bundles outbound commands and events into a single client->server packet.
class_name SnapInputBundle extends SnapEncodable

## Latest command plus redundant unacked commands, oldest to newest.
var commands: Array[SnapCommand]
## Events pending server acknowledgment.
var events: Array[SnapEvent]
## Last relayed event sequence this client has processed.
var ack_sequence: int
## Highest snapshot tick this client has successfully reconstructed.
var last_received_snapshot_tick: int


func encode() -> PackedByteArray:
	var raw := StreamPeerBuffer.new()
	write_int(raw, commands.size())
	for command in commands:
		write_bytes(raw, command.encode())
	write_int(raw, events.size())
	for event in events:
		write_bytes(raw, event.encode())
	write_int(raw, ack_sequence)
	write_int(raw, last_received_snapshot_tick)
	return raw.data_array

func decode(bytes: PackedByteArray) -> SnapInputBundle:
	var buffer := StreamPeerBuffer.new()
	buffer.data_array = bytes
	commands.resize(read_int(buffer))
	for n in commands.size():
		commands[n] = SnapCommand.new().decode(read_bytes(buffer))
	events.resize(read_int(buffer))
	for n in events.size():
		events[n] = SnapEvent.new().decode(read_bytes(buffer))
	ack_sequence = read_int(buffer)
	last_received_snapshot_tick = read_int(buffer)
	return self
