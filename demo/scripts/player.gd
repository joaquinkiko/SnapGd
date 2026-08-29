extends CharacterBody3D

const USE_CUSTOM_PHYSICS := true
const MOVE_SPEED := 6.0
const JUMP_VELOCITY := 8.0
const GRAVITY := 24.0
const ACCELERATION := 15.0
const FRICTION := 12.0
const MOUSE_SENSITIVITY := 0.002
const PITCH_LIMIT := deg_to_rad(80)
const HEAD_INDEX := 5

@export var camera_node: Camera3D
@export var animation_player: AnimationPlayer
@export var skeleton: Skeleton3D
@export var net_node: NetNode

enum AnimationState {
	STANDING = 0,
	WALKING = 1,
	JUMPING = 2,
	FALLING = 3,
}
var animation_state := AnimationState.STANDING
var _previous_animation_state := -1
var _jump_animation_state := false

# Command inputs
var camera_yaw := 0.0
var camera_pitch := 0.0
var should_jump := false
var input_dir := Vector2.ZERO

func _enter_tree() -> void:
	net_node.simulate_command.connect(_simulate)
	net_node.sample_input.connect(_gather_input)
	SnapAPI.post_tick_loop.connect(_render_update)
	set_multiplayer_authority(name.trim_prefix("Player").to_int())

func _ready() -> void:
	if not is_multiplayer_authority():
		camera_node.current = false
		return
	else:
		camera_node.current = true
	# Setup skeleton for head rotation
	skeleton.set_bone_global_pose_override(HEAD_INDEX, skeleton.get_bone_global_pose(HEAD_INDEX), 1.0, true)
	# Own character should be invisible
	if camera_node.current:
		visible = false
	else:
		visible = true

func _input(event: InputEvent) -> void:
	if not is_multiplayer_authority(): return
	
	# Grab/release camera
	if event is InputEventKey and event.keycode == KEY_ESCAPE:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	elif event is InputEventKey and event.keycode == KEY_P and event.is_pressed():
		SnapAPI.set_paused(!SnapAPI.is_paused)
	elif event is InputEventMouseButton and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	if Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
		return # Ignore input if not currently in focus
	
	if SnapAPI.is_paused: return
	
	# Get look direction
	if event is InputEventMouseMotion:
		_rotate_camera(event.relative)
	# Get jump action
	if Input.is_action_just_pressed("ui_accept"):
		should_jump = true
	# Get speak action
	if Input.is_action_just_pressed("ui_focus_next"): # (Tab)
		$NetEvent.call_event(&"event_speak", ["Server" if multiplayer.is_server() else "Client"])

func _gather_input(_command: SnapCommand) -> void:
	if not is_multiplayer_authority(): return
	# Get move direction
	input_dir.x = int(Input.is_key_label_pressed(KEY_D)) - int(Input.is_key_label_pressed(KEY_A))
	input_dir.y = int(Input.is_key_label_pressed(KEY_S)) - int(Input.is_key_label_pressed(KEY_W))
	input_dir = input_dir.normalized()
	# Check if should_jump is valid
	should_jump = should_jump and _is_on_floor()

func _simulate(delta: float) -> void:
	# Update camera
	camera_node.rotation.x = camera_pitch
	rotation.y = camera_yaw
	
	# Update animation state
	if _previous_animation_state != animation_state:
		_previous_animation_state = animation_state
		match animation_state:
			AnimationState.STANDING: animation_player.current_animation = "Idle"
			AnimationState.WALKING: animation_player.current_animation = "Run"
			AnimationState.JUMPING: animation_player.current_animation = "LongJump"
			AnimationState.FALLING: animation_player.current_animation = "Fall"
	# Update head animation
	var current_transform := skeleton.get_bone_global_pose(HEAD_INDEX)
	current_transform.basis = Basis(Quaternion(Vector3.RIGHT, -camera_pitch / 1.5))
	skeleton.set_bone_global_pose_override(HEAD_INDEX, current_transform, 1.0, true)
	
	# Handle gravity
	var gravity_velocity := velocity.y
	if _is_on_floor():
		if should_jump:
			gravity_velocity = JUMP_VELOCITY
			_jump_animation_state = true
		else:
			gravity_velocity = 0.0
			_jump_animation_state = false
	else:
		gravity_velocity -= GRAVITY * delta
	# Consume should_jump, so it's not resimulated next tick without command
	should_jump = false
	
	# Get move direction
	var wish_dir: Vector3 = (
		Basis(Vector3.UP, rotation.y) 
		* Vector3(input_dir.x, 0.0, input_dir.y)
		).normalized()
	# Calculate movement and update animation
	var horizontal_velocity := Vector3(velocity.x, 0, velocity.z)
	var target_velocity := wish_dir * MOVE_SPEED
	var smoothing := ACCELERATION if wish_dir.length() > 0.01 else FRICTION
	horizontal_velocity = horizontal_velocity.lerp(target_velocity, clamp(smoothing * delta, 0.0, 1.0))
	velocity = Vector3(horizontal_velocity.x, gravity_velocity, horizontal_velocity.z)
	# Update animation
	_update_animation(horizontal_velocity.length())
	# Apply movement
	_apply_motion(delta)

func _rotate_camera(mouse_delta: Vector2) -> void:
	camera_yaw += -mouse_delta.x * MOUSE_SENSITIVITY
	camera_pitch -= mouse_delta.y * MOUSE_SENSITIVITY
	camera_pitch = clamp(camera_pitch, -PITCH_LIMIT, PITCH_LIMIT)

func _update_animation(horizontal_speed: float) -> void:
	if not multiplayer.is_server(): return
	if not _is_on_floor():
		if _jump_animation_state:
			animation_state = AnimationState.JUMPING
		else:
			animation_state = AnimationState.FALLING
	elif horizontal_speed > 0.2:
		animation_state = AnimationState.WALKING
	else:
		animation_state = AnimationState.STANDING

func _is_on_floor() -> bool:
	if USE_CUSTOM_PHYSICS:
		var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
		var origin: Vector3 = global_position + Vector3.UP * 0.05
		var target: Vector3 = global_position + Vector3.DOWN * 0.15
		var params := PhysicsRayQueryParameters3D.create(origin, target)
		params.exclude = [self]
		params.collision_mask = collision_mask
		return space.intersect_ray(params).size() > 0
	else:
		return is_on_floor()

func _render_update() -> void:
	if multiplayer.is_server() || is_multiplayer_authority():
		return # This is only for remote clients
	# Update animation state
	if _previous_animation_state != animation_state:
		_previous_animation_state = animation_state
		match animation_state:
			AnimationState.STANDING: animation_player.current_animation = "Idle"
			AnimationState.WALKING: animation_player.current_animation = "Run"
			AnimationState.JUMPING: animation_player.current_animation = "LongJump"
			AnimationState.FALLING: animation_player.current_animation = "Fall"
	# Update head animation
	var current_transform := skeleton.get_bone_global_pose(HEAD_INDEX)
	current_transform.basis = Basis(Quaternion(Vector3.RIGHT, -camera_pitch / 1.5))
	skeleton.set_bone_global_pose_override(HEAD_INDEX, current_transform, 1.0, true)

func _apply_motion(delta: float) -> void:
	if USE_CUSTOM_PHYSICS:
		var remaining: Vector3 = velocity * delta
		var collision: KinematicCollision3D
		for _i in 4: # Max slides
			if remaining.is_zero_approx():
				break
			collision = KinematicCollision3D.new()
			if test_move(global_transform, remaining, collision):
				global_position += collision.get_travel()
				var normal: Vector3 = collision.get_normal()
				remaining = remaining.slide(normal)
				velocity = velocity.slide(normal)
			else:
				global_position += remaining
				break
	else:
		move_and_slide()

# Returns "speaker:listener"
func event_speak(word: String) -> void:
	print(word, ":", "Server" if multiplayer.is_server() else "Client")
