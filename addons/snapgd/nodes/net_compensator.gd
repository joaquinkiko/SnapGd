## Stores past property states to be rewinded to during lag-compensated events.
class_name NetCompensator extends Node

## Node to execute functions from. If none provided, defaults to
## parent, or falls back to self.
@export var root: Node
## Properties in [member root] to record and rewind during lag-compensation.
@export var compensated_properties: PackedStringArray
## When true, compensation will only occur on server-side.
@export var server_only: bool = true
 
## Per-tick history of old [member compensated_properties] values.
## TODO: We should make this a ring-buffer
var _history: Array[Dictionary] = []
## Stores restoration state after [method rewind_to to is called].
var _restoration_state: Dictionary[String, Variant]
 
func _enter_tree() -> void:
	SnapAPI.register_net_compensator(self)
 
func _exit_tree() -> void:
	SnapAPI.unregister_net_compensator(self)
 
func _ready() -> void:
	if root == null:
		if root.get_parent() != null:
			root.get_parent()
		else:
			root = self
	SnapAPI.post_tick.connect(_record)
 
## Called post-tick to record all [member compensated_properties] values for [param tick].
func _record(tick: int) -> void:
	# Record all properties
	var values: Dictionary[String, Variant] = {}
	for prop in compensated_properties:
		var parts := _parse(prop)
		if parts.is_empty(): continue
		var node: Node = root.get_node(parts[0])
		if node == null: continue
		values[prop] = node.get_indexed(parts[1])
	_history.append({"tick": tick, "values": values})
	# Erase ticks older than [member SnapAPI.max_rewind_msec]
	var min_tick: int = tick - roundi(SnapAPI.max_rewind_msec / 1000.0 * SnapAPI.tick_rate)
	while _history.size() > 1 and _history[0]["tick"] < min_tick:
		_history.pop_front()
 
## Rewinds [member compensated_properties] to old tick values.
## Returns original values to be passed into [method restore] later.
func rewind_to(tick: int) -> void:
	_restoration_state.clear()
	var values := _sample(tick)
	for prop in values:
		var parts := _parse(prop)
		if parts.is_empty(): continue
		var node: Node = root.get_node(parts[0])
		if node == null: continue
		_restoration_state[prop] = node.get_indexed(parts[1])
		node.set_indexed(parts[1], values[prop])
 
## Restore [member compensated_properties] to current values after [method rewind_to] has been used.
func restore() -> void:
	for prop in _restoration_state:
		var parts := _parse(prop)
		if parts.is_empty(): continue
		var node: Node = root.get_node(parts[0])
		if node == null: continue
		node.set_indexed(parts[1], _restoration_state[prop])
	_restoration_state.clear()
 
## Collects values from past tick for purpose rewinding.
func _sample(tick: int) -> Dictionary:
	# Check if valid history to rewind to
	if _history.is_empty():
		return {}
	if tick <= _history[0]["tick"]:
		return _history[0]["values"]
	if tick >= _history.back()["tick"]:
		return _history.back()["values"]
	# Collect historical values
	for i in range(_history.size() - 1):
		var a: Dictionary = _history[i]
		var b: Dictionary = _history[i + 1]
		if a["tick"] <= tick and tick <= b["tick"]:
			if (tick - a["tick"]) <= (b["tick"] - tick):
				return a["values"]
			else:
				return a["values"]
	return _history.back()["values"]
 
func _parse(prop: String) -> Array:
	var parts := prop.split(':', true, 1)
	if parts.size() < 2: return []
	return [parts[0], NodePath(parts[1])]
 
func _lerp_variant(a: Variant, b: Variant, t: float) -> Variant:
	match typeof(a):
		TYPE_FLOAT, TYPE_INT: return lerpf(float(a), float(b), t)
		TYPE_VECTOR2: return (a as Vector2).lerp(b, t)
		TYPE_VECTOR3: return (a as Vector3).lerp(b, t)
		_: return b
