@tool
extends EditorPlugin

const settings := [
	{
		"name": "SnapAPI/tick_rate",
		"type": TYPE_FLOAT,
		"hint": PROPERTY_HINT_RANGE,
		"hint_string": "30,128,or_greater,prefer_slider",
		"default": 60,
	},
	{
		"name": "SnapAPI/snapshot_rate",
		"type": TYPE_FLOAT,
		"hint": PROPERTY_HINT_RANGE,
		"hint_string": "15,64,or_greater,prefer_slider",
		"default": 30,
	},
	{
		"name": "SnapAPI/input_send_rate",
		"type": TYPE_FLOAT,
		"hint": PROPERTY_HINT_RANGE,
		"hint_string": "15,64,or_greater,prefer_slider",
		"default": 30,
	},
	{
		"name": "SnapAPI/max_tick_per_frame",
		"type": TYPE_INT,
		"hint": PROPERTY_HINT_RANGE,
		"hint_string": "1,16,or_greater",
		"default": 8,
	},
]

func _enable_plugin() -> void:
	add_autoload_singleton("SnapAPI", "snap_api.gd")
	for setting in settings:
		if not ProjectSettings.has_setting(setting["name"]):
			ProjectSettings.set_setting(setting["name"], setting["default"])
		ProjectSettings.set_initial_value(setting["name"], setting["default"])
		ProjectSettings.add_property_info(setting)

func _disable_plugin() -> void:
	remove_autoload_singleton("SnapAPI")
	for setting in settings:
		ProjectSettings.set_setting(setting["name"], null)
