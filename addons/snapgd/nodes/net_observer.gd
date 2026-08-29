## Defines a peer's view for interest-management priority scaling.
class_name NetObserver extends Node

## Root [Node2D]/[Node3D] to measure distance from. Defaults to parent.
@export var root: Node
## Distance at or under which observables reach full priority (multiplier of 1.0).
@export var min_range: float = 10.0
## Distance at or beyond which observables reach zero priority.
@export var max_range: float = 50.0
## Auto-assigns this as current [NetObserver] for owner on [method _ready].
@export var _make_current: bool = true

func _ready() -> void:
	if root == null:
		root = get_parent()
	if _make_current:
		make_current()
	if not (root is Node2D or root is Node3D):
		push_error("Root of NetObserver should be Node2D or Node3D for it to function")

func _exit_tree() -> void:
	SnapAPI.unregister_net_observer(self)

## Sets this as the current observer for the peer that owns it.
func make_current() -> void:
	SnapAPI.set_current_observer(get_multiplayer_authority(), self)

## Returns [Vector3] or [Vector2] depending on node type of [member root].
## If [member root] is not a [Node2D] or [Noded3D], returns null.
func get_position() -> Variant:
	if root is Node2D || root is Node3D:
		return root.global_position
	return null
