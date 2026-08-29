## Handles relaying one-time function calls across the network.\
## Events are guaranteed to be ran on all peers. Can check if peer is
## server or not to run server specific logic in event.
class_name NetEvent extends NetIdentifiable

## Peer ID of current event caller. -1 if called outside of an event.
static var current_event_caller: int = -1

## Who may call events on this node.
enum Rule {
	## Only multiplayer authority may call events.
	OWNER,
	## Only server may call events.
	SERVER,
	## Any peer may call events.
	ANYONE,
	}
 
## Node to execute functions from. If none provided, defaults to
## parent, or falls back to self.
@export var root: Node
## Available functions for executions.
@export var events: PackedStringArray
## Who is allowed to call these functions.
@export var rule: Rule = Rule.OWNER
## Should events apply lag compensation before being executed?
@export var lag_compensated: bool = false
 
## Events pending executions, sorted [event, args].
var _pending: Array[Array] = []
 
## Cached argument info by event index [min_args, max_args, types: Array[int]]
var _event_signatures: Array[Array]

func _enter_tree() -> void:
	super._enter_tree()
	SnapAPI.register_net_event(self)
 
func _exit_tree() -> void:
	super._exit_tree()
	SnapAPI.unregister_net_event(self)
 
func _ready() -> void:
	if root == null:
		if root.get_parent() != null:
			root.get_parent()
		else:
			root = self
	# Checks events, and caches info on what is considered valid for them
	_event_signatures.resize(events.size())
	var methods := root.get_method_list()
	for method in methods:
		if not events.has(method["name"]): continue
		var args: Array = method["args"]
		var default_count: int = method.get("default_args", []).size()
		var types: Array[int] = []
		for arg in args:
			types.append(arg["type"])
		_event_signatures[events.find(method["name"])] = [
			args.size() - default_count,
			args.size(),
			types,
		]
	for n in _event_signatures.size():
		if _event_signatures[n].is_empty():
			# Function wasn't found in parent
			push_error("Event '%s' wasn't found on '%s'"%[events[n], root.name])
 
## Calls event to be executed over the network.
func call_event(event_name: StringName, args: Array = []) -> void:
	var index := events.find(event_name)
	if index == -1:
		push_warning("Event '%s' cannot be found in approved events list"%event_name)
		return
	if !has_local_permission():
		push_warning("Attempting to call an event that local user doesn't have permission to")
		return
	# Call locally for responsiveness
	var event := SnapEvent.new()
	event.net_id = net_id
	event.event_index = index
	event.args = args
	event.tick = SnapAPI.current_tick + 1 # Pending events simulate during next tick
	event.caller = multiplayer.get_unique_id()
	event.sequence = -1 # This is a local call, with no remote sequencing
	SnapAPI.upcoming_events.append(event)
	# Append event to be sent out to network
	_pending.append([event_name, args])
 
## Applies event locally only. Doesn't self validate, use [function has_permission] beforehand.
func apply_event(event_index: int, args: Array, caller: int, tick: int) -> void:
	if event_index < 0 || event_index >= events.size():
		push_warning("Event index %d out of range"%event_index)
		return
	var event_name: StringName = events[event_index]
	current_event_caller = caller
	if caller == multiplayer.get_unique_id():
		root.callv(event_name, args)
	else: # Lag-compensation is only needed if we aren't the caller
		SnapAPI.rewind_compensators(tick)
		root.callv(event_name, args)
		SnapAPI.restore_compensators()
	current_event_caller = -1
 
## Grabs list of pending events, clearing [memebr _pending] in the process.
func consume_pending() -> Array[Array]:
	var out := _pending
	_pending = []
	return out
 
## Checks if [param peer] has permission to call events.
func has_permission(peer: int) -> bool:
	match rule:
		Rule.OWNER: return get_multiplayer_authority() == peer
		Rule.SERVER: return peer == 1
		Rule.ANYONE: return true
		_: return false
 
## Does local user have permission to call events?
func has_local_permission() -> bool:
	match rule:
		Rule.OWNER: return is_multiplayer_authority()
		Rule.SERVER: return multiplayer.is_server()
		Rule.ANYONE: return true
		_: return false

## Validates [param event]'s args and returns true if the event is safe to apply.
func validate_event(event: SnapEvent) -> bool:
	if event.event_index < 0 or event.event_index >= events.size():
		return false
	if _event_signatures[event.event_index].is_empty():
		return false # Function doesn't exist on root, or wasn't found at _ready time
	var signature: Array = _event_signatures[event.event_index]
	var arg_count: int = event.args.size()
	if arg_count < signature[0] or arg_count > signature[1]:
		return false # Too litte/many arguments provided
	var types: Array = signature[2]
	for i in arg_count:
		var expected_type: int = types[i]
		if expected_type == TYPE_NIL:
			continue # Untyped parameter, accept any type
		if typeof(event.args[i]) != expected_type:
			return false
	return true
