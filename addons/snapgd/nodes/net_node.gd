## Manages what properties should be synchronized between peers
class_name NetNode extends Node

@export var command_properties: PackedStringArray

@export var state_properties: PackedStringArray

## TODO: register/unregister node

func capture_command(command: SnapCommand) -> void:
	for prop in command_properties:
		command.data[_key(prop)] = get_indexed(prop)

func apply_command(command: SnapCommand) -> void:
	for prop in command_properties:
		var key := _key(prop)
		if command.data.has(key):
			set_indexed(prop, command.data[key])

func capture_state(state: SnapState) -> void:
	for prop in state_properties:
		state.data[_key(prop)] = get_indexed(prop)

func apply_state(state: SnapState) -> void:
	for prop in state_properties:
		var key := _key(prop)
		if state.data.has(key):
			set_indexed(prop, state.data[key])

func _key(prop: String) -> StringName:
	return StringName("%s:%s" % [get_path(), prop])
