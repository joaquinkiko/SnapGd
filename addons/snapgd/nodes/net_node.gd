## Manages what properties should be synchronized between peers
class_name NetNode extends Node

## Client -> Server properties
@export var command_properties: PackedStringArray

## Server -> client properties
@export var state_properties: PackedStringArray

func _enter_tree() -> void:
	SnapAPI.register_net_node(self)

func _exit_tree() -> void:
	SnapAPI.unregister_net_node(self)

## Reads command properties to [param command].
func capture_command(command: SnapCommand) -> void:
	for prop in command_properties:
		command.data[_key(prop)] = get_indexed(prop)

## Writes [param command] back to this node.
func apply_command(command: SnapCommand) -> void:
	for prop in command_properties:
		var key := _key(prop)
		if command.data.has(key):
			set_indexed(prop, command.data[key])

## Read state properties to [param state].
func capture_state(state: SnapState) -> void:
	for prop in state_properties:
		state.data[_key(prop)] = get_indexed(prop)

## Writes [param state] back to this node.
func apply_state(state: SnapState) -> void:
	for prop in state_properties:
		var key := _key(prop)
		if state.data.has(key):
			set_indexed(prop, state.data[key])

## Gets reconciliation offset for visual properties.
func get_render_offset(prop: String) -> Variant:
	return SnapAPI.render_offsets.get(_key(prop))

func _key(prop: String) -> StringName:
	return StringName("%s:%s" % [get_path(), prop])
