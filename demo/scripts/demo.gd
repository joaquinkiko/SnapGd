## May use args:
## --ip=127.0.0.1 # Set IP to 127.0.0.1
## --port=42069 # Set port to 42069
## --server # Auto host
## --client # Auto join
extends CanvasLayer

@export var world: PackedScene
@export var player: PackedScene
@export var spawn_radius := Vector2(20, 20)

var ip: String = "127.0.0.1"
var port: int = 42069

var _player_nodes: Dictionary[int, Node]

func _ready() -> void:
	get_window().title = "Offline"
	multiplayer.connected_to_server.connect(_connected_to_server)
	multiplayer.server_disconnected.connect(_server_disconnected)
	multiplayer.connection_failed.connect(_connection_failed)
	multiplayer.peer_connected.connect(_peer_connected)
	multiplayer.peer_disconnected.connect(_peer_disconnected)
	# Read setup args
	for arg in OS.get_cmdline_args():
		if arg.begins_with("--ip="):
			ip = arg.trim_prefix("--ip=")
			$Menu/IP.text = ip
		if arg.begins_with("--port="):
			port = arg.trim_prefix("--port=").to_int()
			$Menu/IP.text = "%s:%s"%[ip, port]
		if arg == "--server" or arg == "--headless":
			_on_host_pressed()
		elif arg == "--client":
			_on_join_pressed()

func _connected_to_server():
	print("Connected to server at %s:%s"%[ip, port])
	$Background.visible = false

func _server_disconnected():
	print("Disconnected from server")
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	$Menu.visible = true
	$Background.visible = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	get_window().title = "Offline"
	for child in $Spawner.get_children():
		child.queue_free()

func _connection_failed():
	print("Connection failed")
	$Menu.visible = true
	$Background.visible = true

func _peer_connected(peer: int):
	print("Peer connected as %s"%peer)
	if multiplayer.is_server():
		spawn_player(peer)

func _peer_disconnected(peer: int):
	print("Peer %s disconnected"%peer)
	if multiplayer.is_server() and _player_nodes.has(peer):
		_player_nodes[peer].queue_free()
		_player_nodes.erase(peer)

func _on_ip_text_changed() -> void:
	var text: String = $Menu/IP.text
	if text.is_empty():
		ip = "127.0.0.1"
	else:
		ip = text.split(":")[0]
	if text.contains(":"):
		port = text.split(":")[1].to_int()
	else:
		port = 42069

func _on_join_pressed() -> void:
	print("Attempting to connect to %s:%s"%[ip, port])
	if not ip.is_valid_ip_address():
		print("Invalid ip: %s"%ip)
		return
	$Menu.visible = false
	var peer := ENetMultiplayerPeer.new()
	var err: Error = peer.create_client(ip, port)
	if err:
		print("Unable to join: (%s) %s"%[err, error_string(err)])
		$Menu.visible = true
		return
	multiplayer.multiplayer_peer = peer
	_connect_to_game()
	get_window().title = "Client %s"%multiplayer.get_unique_id()

func _on_host_pressed() -> void:
	print("Attempting to host at %s"%port)
	if port < 0 or port > 65535:
		print("Invalid port: %s"%port)
		return
	var peer := ENetMultiplayerPeer.new()
	$Menu.visible = false
	var err: Error = peer.create_server(port)
	if err:
		print("Unable to host: (%s) %s"%[err, error_string(err)])
		$Menu.visible = true
		return
	multiplayer.multiplayer_peer = peer
	$Background.visible = false
	print("Now hosting at port %s"%port)
	_connect_to_game()
	get_window().title = "Server"

func _on_offline_pressed() -> void:
	print("Starting offline session")
	$Menu.visible = false
	$Background.visible = false
	_connect_to_game()
	get_window().title = "Offline"

func _connect_to_game() -> void:
	if multiplayer.is_server() or (multiplayer.multiplayer_peer is OfflineMultiplayerPeer):
		var world_instance := world.instantiate()
		$Spawner.add_child(world_instance)
		if not OS.get_cmdline_args().has("--headless"):
			spawn_player(multiplayer.get_unique_id())

func spawn_player(peer: int) -> Node3D:
	if not (multiplayer.is_server() or (multiplayer.multiplayer_peer is OfflineMultiplayerPeer)):
		return
	var player_instance := player.instantiate()
	player_instance.name = "Player%s"%peer
	player_instance.set_multiplayer_authority(peer)
	_player_nodes[peer] = player_instance
	$Spawner.add_child(player_instance)
	player_instance.position = Vector3(
		randf_range(-spawn_radius.x, spawn_radius.x),
		1,
		randf_range(-spawn_radius.y, spawn_radius.y)
		)
	return player_instance

func _on_exit_pressed() -> void:
	get_tree().quit()

func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		if event.keycode == KEY_ESCAPE and Input.is_key_pressed(KEY_ALT):
			print("Terminating connection")
			multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
			$Menu.visible = true
			$Background.visible = true
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
			get_window().title = "Offline"
			for child in $Spawner.get_children():
				child.queue_free()
