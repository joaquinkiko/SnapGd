##
class_name SnapCommand extends SnapEncodable

##
var sequence: int
##
var tick: int
##
var delta_time: float
##
var data: Dictionary[StringName, Variant]

func encode() -> PackedByteArray:
	var raw: StreamPeerBuffer
	write_int(raw, sequence)
	write_int(raw, tick)
	write_float(raw, delta_time)
	write_variant(raw, data)
	return raw.data_array

func decode(bytes: PackedByteArray) -> SnapCommand:
	var buffer := StreamPeerBuffer.new()
	buffer.data_array = bytes
	sequence = read_int(buffer)
	tick = read_int(buffer)
	delta_time = read_float(buffer)
	data = read_variant(buffer)
	return self
