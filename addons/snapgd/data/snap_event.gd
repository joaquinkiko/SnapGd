## This stores event data to be sent over network.
class_name SnapEvent extends SnapEncodable

## This is the event sequence, ensuring events are played in
## correct order and that no events are skipped.
var sequence: int
## This is the tick the event is meant to be played on.
var tick: int
## This is the original event caller.
var caller: int
## This is the ID of the [NetEvent] node the event was called from.
var net_id: int
## This is the index of the event/function name being called.
var event_index: int
## This is the event parameters provided.
var args: Array

func encode() -> PackedByteArray:
	var raw := StreamPeerBuffer.new()
	write_int(raw, sequence)
	write_int(raw, tick)
	write_int(raw, caller)
	write_int(raw, net_id)
	write_int(raw, event_index)
	write_variant(raw,args )
	return raw.data_array

func decode(bytes: PackedByteArray) -> SnapEvent:
	var buffer := StreamPeerBuffer.new()
	buffer.data_array = bytes
	sequence = read_int(buffer)
	tick = read_int(buffer)
	caller = read_int(buffer)
	net_id = read_int(buffer)
	event_index = read_int(buffer)
	args = read_variant(buffer)
	return self
