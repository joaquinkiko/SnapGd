## Base for nodes needing a small numeric ID instead of a full NodePath over network.
class_name NetIdentifiable extends Node

## Assigned ID. -1 until the client hears back from the server.
var net_id: int = -1

func _enter_tree() -> void:
	SnapAPI.register_net_identifiable(self)

func _exit_tree() -> void:
	SnapAPI.unregister_net_identifiable(self)
