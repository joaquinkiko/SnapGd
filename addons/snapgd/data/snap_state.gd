##
class_name SnapState extends SnapEncodable

##
var sequence: int
##
var data: Dictionary[StringName, Variant]

func encode() -> PackedByteArray:
	var raw := StreamPeerBuffer.new()
	write_int(raw, sequence)
	write_variant(raw, data)
	return raw.data_array

func decode(bytes: PackedByteArray) -> SnapState:
	var buffer := StreamPeerBuffer.new()
	buffer.data_array = bytes
	sequence = read_int(buffer)
	data = read_variant(buffer)
	return self
