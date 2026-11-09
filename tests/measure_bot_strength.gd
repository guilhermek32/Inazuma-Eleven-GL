extends SceneTree

## Measures how the online bot's difficulty levels play, without a network:
## BotBrain drives a team of a local MatchSession through the same
## InputSnapshot a remote player would send (observing the session's own
## state, i.e. a zero-latency snapshot), with that team's off-ball AI at the
## same difficulty, as in a vs-AI room. Two experiments, seeded and therefore
## repeatable within one engine build:
##   1. bot vs bot for each pair of levels (left level on team 0)
##   2. each level against the in-simulation AI at Normal (team 0)
## Prints one line per experiment; docs/measurements.md records a run.
##
## Run: godot-4 --headless --path . --script res://tests/measure_bot_strength.gd [-- --seeds=6 --half=90]

const DT := 1.0 / 60.0

func _initialize() -> void:
	var seeds := 6
	var half := 90.0
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--seeds="):
			seeds = maxi(1, int(arg.substr(8)))
		elif arg.begins_with("--half="):
			half = clampf(float(arg.substr(7)), MatchConfig.MIN_HALF_LENGTH_S, MatchConfig.MAX_HALF_LENGTH_S)
	print("bot strength: %d seeded matches per line, %d s halves" % [seeds, int(half)])
	for pair in [["easy", "normal"], ["normal", "hard"], ["easy", "hard"]]:
		_report("%s vs %s" % pair, pair[0], pair[1], seeds, half)
	for level in BotBrain.DIFFICULTIES:
		_report("in-sim AI (normal) vs %s bot" % level, "", level, seeds, half)
	quit(0)

## `left` "" = team 0 is the in-simulation AI at Normal.
func _report(label: String, left: String, right: String, seeds: int, half: float) -> void:
	var goals := [0, 0]
	var shots := [0, 0]
	var wins := [0, 0]
	var possession := 0.0
	for seed_value in range(1, seeds + 1):
		var s := MatchSession.new()
		s.set_team_device(0, GameConfig.DEVICE_AI if left == "" else GameConfig.DEVICE_REMOTE)
		s.set_team_device(1, GameConfig.DEVICE_REMOTE)
		var cfg := MatchConfig.new()
		cfg.half_length_s = half
		cfg.team_difficulty = [MatchConfig.DIFFICULTY_NORMAL if left == "" else BotBrain.difficulty_index(left),
				BotBrain.difficulty_index(right)]
		s.initialize(cfg, seed_value)
		var brains := [null if left == "" else BotBrain.new(left, 0, seed_value), BotBrain.new(right, 1, seed_value + 1000)]
		while s.phase != MatchSession.Phase.FULLTIME:
			var playing := s.phase == MatchSession.Phase.PLAYING and s.sim.restart_timer <= 0.0
			for t in 2:
				if brains[t] != null:
					s.submit_input(t, (brains[t] as BotBrain).step(s.sim, playing, DT))
			s.step(DT)
			s.drain_events()
		goals[0] += s.sim.score_left
		goals[1] += s.sim.score_right
		for t in 2:
			shots[t] += int(s.sim.stats[t].shots)
		if s.sim.score_left != s.sim.score_right:
			wins[0 if s.sim.score_left > s.sim.score_right else 1] += 1
		var total := float(s.sim.stats[0].possession) + float(s.sim.stats[1].possession)
		possession += float(s.sim.stats[1].possession) / maxf(total, 0.001)
		s.dispose()
	print("%-32s goals %2d-%-2d  shots %2d-%-2d  wins %d-%d  right-side possession %.0f%%" % [label, goals[0], goals[1],
			shots[0], shots[1], wins[0], wins[1], 100.0 * possession / float(seeds)])
