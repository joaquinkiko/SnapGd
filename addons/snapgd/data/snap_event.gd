## This stores event data to be sent over network.
class_name SnapEvent

## This is the event sequence, ensuring events are played in
## correct order and that no events are skipped.
var sequence: int
## This is the tick the event is meant to be played on.
var tick: int
## This is the original event caller.
var caller: int
## This is the [NetEvent] node the event was called from.
var node: NetEvent
## This is the event/function name being called.
var event_name: StringName
## This is the event parameters provided.
var args: Array
