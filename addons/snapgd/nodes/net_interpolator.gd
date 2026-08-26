## Smoothes client reconciliations and remote interpolations.
class_name NetInterpolator extends Node

## Max size of [member _snapshot_buffer].
const _BUFFER_SIZE := 32
 
## [NetNode] to reference. Will use parent if not specified.
@export var net_node: NetNode
## Properties to remotely interpolate (must match [NetNode] states).
@export var interpolated_properties: PackedStringArray
## Properties to locally smooth after reconciliation (must match [NetNode] states).
@export var smoothed_properties: PackedStringArray
## How far in past (in msec) remote peers are interpolated.
@export_range(50, 150, 1) var interpolation_delay_msec: float = 100
## Reconciliation offsets above this magnitude snap instantly instead of blending.
@export var snap_threshold: float = 1.0
 
## Stores received snapshots to interpolate over.
var _snapshot_buffer: Array[Snapshot] = []
## Stored offsets for smoothing reconciliation.
var _applied_offsets: Dictionary[StringName, Variant] = {}
 
func _ready() -> void:
	if net_node == null:
		net_node = get_parent() as NetNode
	SnapAPI.snapshot_received.connect(_on_snapshot_received)
	SnapAPI.pre_tick_loop.connect(_remove_smoothing_offsets)
	SnapAPI.post_tick_loop.connect(_update)
 
func _on_snapshot_received(snapshot: Snapshot) -> void:
	# Add snapshot to buffer, and remove old buffer contents
	_snapshot_buffer.push_back(snapshot)
	if _snapshot_buffer.size() > _BUFFER_SIZE:
		_snapshot_buffer.pop_front()
 
## Called post-tick-loop
func _update() -> void:
	if net_node == null || !is_instance_valid(net_node): return
	if net_node.is_multiplayer_authority():
		_apply_smoothing_offsets() # Smooth reconciliation
	else: # Remote authority
		_apply_interpolation() # Interpolate between states
 
## Interpolates between two past snapshots
func _apply_interpolation() -> void:
	if interpolated_properties.is_empty() || _snapshot_buffer.size() < 2: return
	# Get number of ticks to offset interpolation
	var delay_ticks: float = interpolation_delay_msec / 1000.0 * SnapAPI.tick_rate
	var render_tick: float = SnapAPI.current_tick - delay_ticks
	# Get reference snapshots
	var from: Snapshot = null
	var to: Snapshot = null
	for i in range(_snapshot_buffer.size() - 1):
		if _snapshot_buffer[i].server_tick <= render_tick and _snapshot_buffer[i + 1].server_tick >= render_tick:
			from = _snapshot_buffer[i]
			to = _snapshot_buffer[i + 1]
			break
	# Get reference states
	if from == null || to == null: return
	var from_state: SnapState = from.states.back() if !from.states.is_empty() else null
	var to_state: SnapState = to.states.back() if !to.states.is_empty() else null
	if from_state == null || to_state == null: return
	# Where are we between states?
	var span: float = maxf(1.0, to.server_tick - from.server_tick)
	var t: float = clampf((render_tick - from.server_tick) / span, 0.0, 1.0)
	# Apply interpolation
	for prop in interpolated_properties:
		if prop.split(':').size() < 2: continue
		var node_path: String = prop.split(':', true, 2)[0]
		var property: NodePath = prop.split(':', true, 2)[1]
		var key := _state_key(prop)
		if !from_state.data.has(key) || !to_state.data.has(key): continue
		var node: Node = net_node.root.get_node(node_path)
		if node == null: continue
		node.set_indexed(property, _lerp_variant(from_state.data[key], to_state.data[key], t))
 
## Smoothly updates property based off provided offset
func _apply_smoothing_offsets() -> void:
	if smoothed_properties.is_empty(): return
	for prop in smoothed_properties:
		if prop.split(':').size() < 2: continue
		var node_path: String = prop.split(':', true, 2)[0]
		var property: NodePath = prop.split(':', true, 2)[1]
		var offset: Variant = net_node.get_render_offset(prop)
		if offset == null: continue
		if _variant_magnitude(offset) > snap_threshold:
			# Error too large, snap instead of blend
			net_node.clear_render_offset(prop)
			continue
		var node: Node = net_node.root.get_node(node_path)
		if node == null: continue
		node.set_indexed(property, node.get_indexed(property) + offset)
		_applied_offsets[_state_key(prop)] = offset
 
## Called pre-tick-loop
func _remove_smoothing_offsets() -> void:
	if _applied_offsets.is_empty(): return
	for prop in smoothed_properties:
		var key := _state_key(prop)
		if !_applied_offsets.has(key): continue
		if prop.split(':').size() < 2: continue
		var node_path: String = prop.split(':', true, 2)[0]
		var property: NodePath = prop.split(':', true, 2)[1]
		var node: Node = net_node.root.get_node(node_path)
		if node == null: continue
		node.set_indexed(property, node.get_indexed(property) - _applied_offsets[key])
	_applied_offsets.clear()
 
func _state_key(prop: String) -> StringName:
	return StringName("%s:%s" % [net_node.get_path(), prop])

# Interpolate numbers. For non-numerical types, will snap to newer value.
func _lerp_variant(a: Variant, b: Variant, t: float) -> Variant:
	match typeof(a):
		TYPE_FLOAT, TYPE_INT: return lerpf(float(a), float(b), t)
		TYPE_VECTOR2: return (a as Vector2).lerp(b, t)
		TYPE_VECTOR3: return (a as Vector3).lerp(b, t)
		_: return b

func _variant_magnitude(offset: Variant) -> float:
	match typeof(offset):
		TYPE_FLOAT, TYPE_INT: return absf(offset)
		TYPE_VECTOR2: return (offset as Vector2).length()
		TYPE_VECTOR3: return (offset as Vector3).length()
		_: return 0.0
