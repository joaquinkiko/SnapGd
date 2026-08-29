## Manages what properties should be synchronized between peers
class_name NetNode extends NetIdentifiable

## Emitted for owner/server when this node should simulate and update it's state
signal simulate_command(delta: float)
## Emitted for owner when this node should gather command values
signal sample_input(command: SnapCommand)

## Properties paths will be relative to this node.
## If left empty, will use self as root.
@export var root: Node

## Client -> Server properties (NodePath:Property:OptionalSubProperty)
@export var command_properties: PackedStringArray

## Server -> client properties (NodePath:Property:OptionalSubProperty)
@export var state_properties: PackedStringArray

## Base send priority for this [NetNode]'s properties.
@export var base_priority: float = 1.0

## Runtime multiplier on top of [member base_priority].
## Set to 0 to suppress sending, or raise to temporarily boost it.
var priority_multiplier: float = 1.0

## Cached expected Variant type per state_properties index, sampled at _ready.
var _state_property_types: PackedInt32Array
## Cached expected Variant type per command_properties index, sampled at _ready.
var _command_property_types: PackedInt32Array

func _enter_tree() -> void:
	super._enter_tree()
	SnapAPI.register_net_node(self)

func _exit_tree() -> void:
	super._exit_tree()
	SnapAPI.unregister_net_node(self)

func _ready() -> void:
	if root == null:
		root = self
	# Validate properties and cache their types
	_state_property_types.resize(state_properties.size())
	_command_property_types.resize(command_properties.size())
	for i in state_properties.size():
		var value := _sample_property(state_properties[i])
		if value != null:
			_state_property_types[i] = typeof(value)
		else:
			_state_property_types[i] = -1
			push_error("State property '%s' couldn't be found"%state_properties[i])
	for i in command_properties.size():
		var value := _sample_property(command_properties[i])
		if value != null:
			_command_property_types[i] = typeof(value)
		else:
			_command_property_types[i] = -1
			push_error("Command property '%s' couldn't be found"%command_properties[i])

## Reads command properties to [param command].
func capture_command(command: SnapCommand) -> void:
	for i in command_properties.size():
		var prop := command_properties[i]
		if prop.split(':').size() < 2: continue
		var node: Node = root.get_node(prop.split(':', true, 2)[0])
		var property: NodePath = prop.split(':', true, 2)[1]
		if node == null || property.is_empty(): continue
		command.data[make_property_key(net_id, i)] = node.get_indexed(property)

## Writes [param command] back to this node.
func apply_command(command: SnapCommand) -> void:
	for i in command_properties.size():
		var key := make_property_key(net_id, i)
		if command.data.has(key):
			if _command_property_types[i] != typeof(command.data[key]):
				continue # Data is invalid type
			var prop := command_properties[i]
			if prop.split(':').size() < 2: continue
			var node: Node = root.get_node(prop.split(':', true, 2)[0])
			var property: NodePath = prop.split(':', true, 2)[1]
			if node == null || property.is_empty(): continue
			node.set_indexed(property, command.data[key])

## Read state properties to [param state].
func capture_state(state: SnapState) -> void:
	for i in state_properties.size():
		var prop := state_properties[i]
		if prop.split(':').size() < 2: continue
		var node: Node = root.get_node(prop.split(':', true, 2)[0])
		var property: NodePath = prop.split(':', true, 2)[1]
		if node == null || property.is_empty(): continue
		state.data[make_property_key(net_id, i)] = node.get_indexed(property)

## Writes [param state] back to this node.
func apply_state(state: SnapState) -> void:
	for i in state_properties.size():
		var key := make_property_key(net_id, i)
		if state.data.has(key):
			if _state_property_types[i] != typeof(state.data[key]):
				continue # Data is invalid type
			var prop := state_properties[i]
			if prop.split(':').size() < 2: continue
			var node: Node = root.get_node(prop.split(':', true, 2)[0])
			var property: NodePath = prop.split(':', true, 2)[1]
			if node == null || property.is_empty(): continue
			node.set_indexed(property, state.data[key])

## Gets reconciliation offset for visual properties.
func get_render_offset(index: int) -> Variant:
	return SnapAPI.render_offsets.get(make_property_key(net_id, index))

## Clears reconciliation offset for this property, forcing an instant snap.
func clear_render_offset(index: int) -> void:
	SnapAPI.render_offsets.erase(make_property_key(net_id, index))

func _sample_property(prop: String) -> Variant:
	if prop.split(':').size() < 2: return null
	var node: Node = root.get_node(prop.split(':', true, 2)[0])
	var property: NodePath = prop.split(':', true, 2)[1]
	if node == null || property.is_empty(): return null
	return node.get_indexed(property)
