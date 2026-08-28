## Base for nodes needing a small numeric ID instead of a full NodePath over network.
class_name NetIdentifiable extends Node

## Assigned ID. -1 until the client hears back from the server.
var net_id: int = -1

func _enter_tree() -> void:
	SnapAPI.register_net_identifiable(self)

func _exit_tree() -> void:
	SnapAPI.unregister_net_identifiable(self)

## Combines a net_id and property/event index into one dictionary key.
## Assumes index < 65536.
static func make_property_key(net_id: int, index: int) -> int:
	return (net_id << 16) | index

## Extracts the net_id portion from a key made by [method make_property_key].
static func id_from_key(key: int) -> int:
	return key >> 16
