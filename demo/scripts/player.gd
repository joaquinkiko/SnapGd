extends CharacterBody3D

const MOVE_SPEED := 6.0
const JUMP_VELOCITY := 8.0
const GRAVITY := 24.0
const ACCELERATION := 15.0
const FRICTION := 12.0
const MOUSE_SENSITIVITY := 0.002
const PITCH_LIMIT := deg_to_rad(80)
const SHOOT_RANGE := 50.0
const HEAD_INDEX := 5

enum AnimationState {
	STANDING = 0,
	WALKING = 1,
	JUMPING = 2,
	FALLING = 3,
}
var animation_state := AnimationState.STANDING
var _previous_animation_state := -1

var camera_yaw := 0.0
var camera_pitch := 0.0
var should_jump := false
var should_shoot := false
var input_dir := Vector2.ZERO

var received_mouse_button := false
var jump_state := false

@export var camera_node: Camera3D
@export var animation_player: AnimationPlayer
@export var skeleton: Skeleton3D

func _enter_tree() -> void:
	set_multiplayer_authority(name.trim_prefix("Player").to_int())
	if is_multiplayer_authority():
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		camera_node.current = true

func _ready() -> void:
	if not is_multiplayer_authority():
		camera_node.current = false
		return
	skeleton.set_bone_global_pose_override(HEAD_INDEX, skeleton.get_bone_global_pose(HEAD_INDEX), 1.0, true)
	# Own character should be invisible
	if camera_node.current:
		visible = false

func _input(event: InputEvent) -> void:
	if not is_multiplayer_authority(): return
	
	if event is InputEventMouseMotion:
		if Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
			_rotate_camera(event.relative)
	elif event is InputEventMouseButton:
		if Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
			return
		if event.pressed and event.button_index == MouseButton.MOUSE_BUTTON_LEFT:
			received_mouse_button = true
	
	if event is InputEventKey and event.keycode == KEY_ESCAPE:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

func _physics_process(delta: float) -> void:
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
	
	# Handle jump.
	if Input.is_action_just_pressed("ui_accept") and is_on_floor():
		should_jump = true
	
	# Handle gravity
	var gravity_velocity := velocity.y
	if is_on_floor():
		if should_jump:
			gravity_velocity = JUMP_VELOCITY
			jump_state = true
		else:
			gravity_velocity = 0.0
			jump_state = false
	else:
		gravity_velocity -= GRAVITY * delta
	should_jump = false
	
	input_dir.x = int(Input.is_key_label_pressed(KEY_D)) - int(Input.is_key_label_pressed(KEY_A))
	input_dir.y = int(Input.is_key_label_pressed(KEY_S)) - int(Input.is_key_label_pressed(KEY_W))
	input_dir = input_dir.normalized()
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
	_update_animation(is_on_floor(), horizontal_velocity.length())
	# Apply movement
	move_and_slide()

func _rotate_camera(mouse_delta: Vector2) -> void:
	camera_yaw += -mouse_delta.x * MOUSE_SENSITIVITY
	camera_pitch -= mouse_delta.y * MOUSE_SENSITIVITY
	camera_pitch = clamp(camera_pitch, -PITCH_LIMIT, PITCH_LIMIT)

func _update_animation(on_floor: bool, horizontal_speed: float) -> void:
	if not on_floor:
		if jump_state:
			animation_state = AnimationState.JUMPING
		else:
			animation_state = AnimationState.FALLING
	elif horizontal_speed > 0.2:
		animation_state = AnimationState.WALKING
	else:
		animation_state = AnimationState.STANDING
