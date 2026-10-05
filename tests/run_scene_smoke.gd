extends SceneTree

## End-to-end smoke test of the offline game: boots the real 3D scene
## (scenes/main_3d.tscn), starts an AI-vs-AI match with 30 s halves and lets
## the controller drive MatchSession through kickoff, half time and full time,
## dispatching every session event to the view/HUD/audio adapters on the way.
##
## Run with a fixed frame step so the match plays faster than real time:
##   godot-4 --headless --fixed-fps 60 --path . --script res://tests/run_scene_smoke.gd
## Exits 0 when the match reaches full time, 1 otherwise.

const MAX_FRAMES := 60 * 150

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var controller: Node = (load("res://scenes/main_3d.tscn") as PackedScene).instantiate()
	root.add_child(controller)
	await process_frame
	controller.settings.half_length = 30.0
	var devices: Array[int] = [GameConfig.DEVICE_AI, GameConfig.DEVICE_AI]
	var formations: Array[int] = [GameConfig.DEFAULT_FORMATION, 0]
	var kits: Array[Dictionary] = [GameConfig.DEFAULT_KIT_A.duplicate(), GameConfig.DEFAULT_KIT_B.duplicate()]
	controller.set_match_lineup(devices, formations, kits)
	controller._start_match()
	var saw_second_half := false
	var saw_slowmo := false
	var frames := 0
	var sim: MatchSimulation = controller.sim
	while frames < MAX_FRAMES and controller.game_state != GameConfig.GameState.FULLTIME:
		await physics_frame
		frames += 1
		if frames == 200:
			# Force the special-shot path: a full-power shot from close range.
			var striker: PlayerState = sim.teams[0].players[9]
			striker.x = 0.6 * float(-striker.side)
			striker.y = 0.0
			sim.ball.x = striker.x
			sim.ball.y = striker.y
			sim.kick_from_player(striker, Vector2(GameConfig.FIELD_BOUNDARY_X * float(-striker.side), 0.0), 1.0, true)
		if frames == 260 and sim.score_left + sim.score_right == 0:
			# Force the goal path (confetti, net ripple, freeze) if the shot was saved.
			sim._clear_owner()
			sim.restart_timer = 0.0
			sim.ball.x = 0.9
			sim.ball.y = 0.0
			sim.ball.h = 0.0
			sim.ball.vx = 2.0
			sim.ball.vy = 0.0
		if controller.session.time_scale < 1.0:
			saw_slowmo = true
		if controller.session.current_half == 2:
			saw_second_half = true
	var scored: bool = sim.score_left + sim.score_right > 0
	print("slow-mo seen: %s, goal scored: %s" % [saw_slowmo, scored])
	# Every clip in PLAYER_ANIM_FILES must have loaded onto the GLB players.
	var lib: AnimationLibrary = controller.player_factory.player_anim_library
	var missing: Array[String] = []
	for clip in GameConfig.PLAYER_ANIM_FILES:
		if lib == null or not lib.has_animation(clip):
			missing.append(clip)
	print("player clips missing: %s" % [missing])
	var ok: bool = controller.game_state == GameConfig.GameState.FULLTIME and saw_second_half and saw_slowmo and scored and missing.is_empty()
	print("scene smoke: %d frames, state %d, score %d-%d" % [frames, controller.game_state,
			controller.sim.score_left, controller.sim.score_right])
	print("SCENE SMOKE PASSED" if ok else "SCENE SMOKE FAILED")
	quit(0 if ok else 1)
