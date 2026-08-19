## Handles relaying one-time function calls across the network.\
## Events are guaranteed to be ran on all peers. Can check if peer is
## server or not to run server specific logic in event.
class_name NetEvent extends Node

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
 
func _enter_tree() -> void:
	SnapAPI.register_net_event(self)
 
func _exit_tree() -> void:
	SnapAPI.unregister_net_event(self)
 
func _ready() -> void:
	if root == null:
		if root.get_parent() != null:
			root.get_parent()
		else:
			root = self
 
## Calls event to be executed over the network.
func call_event(event_name: StringName, args: Array = []) -> void:
	if !events.has(event_name):
		push_warning("Event '%s' cannot be found in approved events list"%event_name)
		return
	if !has_local_permission():
		push_warning("Attempting to call an event that local user doesn't have permission to")
		return
	# Call locally for responsiveness
	root.callv(event_name, args)
	# Append event to be sent out to network
	_pending.append([event_name, args])
 
## Applies event locally only. Doesn't self validate, use [function has_permission] beforehand.
func apply_event(event_name: StringName, args: Array, caller: int, tick: int) -> void:
	if !events.has(event_name):
		push_warning("Event '%s' cannot be found in approved events list"%event_name)
		return
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
