## Encodes changed node property values, grouped by net_id with a
## bitmask marking which property indices are present.
class_name SnapStateDelta extends SnapEncodable

## Grouped by net_id in priority order (owned nodes first).
## Preserving insertion order matters — Godot dictionaries keep it.
var data: Dictionary[int, Dictionary] # net_id : {index: value}

func encode() -> PackedByteArray:
	var raw := StreamPeerBuffer.new()
	raw.put_32(data.size())
	for net_id in data:
		raw.put_32(net_id)
		var bitmask := 0
		for index in data[net_id]:
			bitmask |= (1 << index)
		raw.put_32(bitmask) # assumes <= 32 properties per node
		for index in range(32):
			if bitmask & (1 << index):
				write_variant(raw, data[net_id][index])
	return raw.data_array

func decode(bytes: PackedByteArray) -> SnapStateDelta:
	var buffer := StreamPeerBuffer.new()
	buffer.data_array = bytes
	var group_count := buffer.get_32()
	for g in group_count:
		var net_id := buffer.get_32()
		var bitmask := buffer.get_32()
		data[net_id] = {}
		for index in range(32):
			if bitmask & (1 << index):
				data[net_id][index] = read_variant(buffer)
	return self

## Flattens to key : value using NetIdentifiable.make_property_key, for merging into full state.
func flatten() -> Dictionary:
	var out: Dictionary = {}
	for net_id in data:
		for index in data[net_id]:
			out[NetIdentifiable.make_property_key(net_id, index)] = data[net_id][index]
	return out
