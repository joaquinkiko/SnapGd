## Manages what properties should be synchronized between peers
class_name NetNode extends Node

## Client -> Server properties (NodePath:Property:OptionalSubProperty)
@export var command_properties: PackedStringArray

## Server -> client properties (NodePath:Property:OptionalSubProperty)
@export var state_properties: PackedStringArray

func _enter_tree() -> void:
	SnapAPI.register_net_node(self)

func _exit_tree() -> void:
	SnapAPI.unregister_net_node(self)

## Reads command properties to [param command].
func capture_command(command: SnapCommand) -> void:
	for prop in command_properties:
		if prop.split(':').size() < 2: continue
		var node: Node = get_node(prop.split(':', true, 2)[0])
		var property: NodePath = prop.split(':', true ,2)[1]
		if node == null || property.is_empty(): continue
		command.data[_key(prop)] = node.get_indexed(property)

## Writes [param command] back to this node.
func apply_command(command: SnapCommand) -> void:
	for prop in command_properties:
		var key := _key(prop)
		if command.data.has(key):
			if prop.split(':').size() < 2: continue
			var node: Node = get_node(prop.split(':', true, 2)[0])
			var property: NodePath = prop.split(':', true ,2)[1]
			if node == null || property.is_empty(): continue
			node.set_indexed(property, command.data[key])

## Read state properties to [param state].
func capture_state(state: SnapState) -> void:
	for prop in state_properties:
		if prop.split(':').size() < 2: continue
		var node: Node = get_node(prop.split(':', true, 2)[0])
		var property: NodePath = prop.split(':', true ,2)[1]
		if node == null || property.is_empty(): continue
		state.data[_key(prop)] = node.get_indexed(property)

## Writes [param state] back to this node.
func apply_state(state: SnapState) -> void:
	for prop in state_properties:
		var key := _key(prop)
		if state.data.has(key):
			if prop.split(':').size() < 2: continue
			var node: Node = get_node(prop.split(':', true, 2)[0])
			var property: NodePath = prop.split(':', true ,2)[1]
			if node == null || property.is_empty(): continue
			node.set_indexed(property, state.data[key])

## Gets reconciliation offset for visual properties.
func get_render_offset(prop: String) -> Variant:
	return SnapAPI.render_offsets.get(_key(prop))

func _key(prop: String) -> StringName:
	return StringName("%s:%s" % [get_path(), prop])
