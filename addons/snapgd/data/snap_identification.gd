## Bundles new NetIdentifiable id->path assignments into one packet.
class_name SnapIdentification extends SnapEncodable

## Assigned identifiable IDs.
var ids: Array[int]
## Paths corresponding to each ID, same order as [member ids].
var paths: Array[NodePath]

func encode() -> PackedByteArray:
	var raw := StreamPeerBuffer.new()
	write_int(raw, ids.size())
	for n in ids.size():
		write_int(raw, ids[n])
		write_variant(raw, paths[n])
	return raw.data_array

func decode(bytes: PackedByteArray) -> SnapIdentification:
	var buffer := StreamPeerBuffer.new()
	buffer.data_array = bytes
	var count := read_int(buffer)
	ids.resize(count)
	paths.resize(count)
	for n in count:
		ids[n] = read_int(buffer)
		paths[n] = read_variant(buffer)
	return self
