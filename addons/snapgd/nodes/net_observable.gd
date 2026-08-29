## Scales managed [NetNode]s' [member NetNode.priority_multiplier]
## based on distance to a peer's active [NetObserver].
class_name NetObservable extends Node

## Root [Node2D]/[Node3D] to measure distance from. Defaults to parent.
@export var root: Node
## [NetNode]s managed.
@export var net_nodes: Array[NetNode]

func _ready() -> void:
	if root == null:
		root = get_parent()
	SnapAPI.register_net_observable(self)
	if not (root is Node2D or root is Node3D):
		push_error("Root of NetObservable should be Node2D or Node3D for it to function")

func _exit_tree() -> void:
	SnapAPI.unregister_net_observable(self)

## Returns [Vector3] or [Vector2] depending on node type of [member root].
## If [member root] is not a [Node2D] or [Noded3D], returns null.
func get_position() -> Variant:
	if root is Node2D || root is Node3D:
		return root.global_position
	return null
