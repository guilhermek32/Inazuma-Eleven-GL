class_name AudioManager
extends Node

## Owns the Music/SFX audio buses and stream players, and exposes simple
## play hooks. Volumes are pushed in from SettingsStore via apply_volumes().

var bus_music := -1
var bus_sfx := -1
var music_player: AudioStreamPlayer
var sfx_kick: AudioStreamPlayer
var sfx_whistle: AudioStreamPlayer
var sfx_special: AudioStreamPlayer
var sfx_roar: AudioStreamPlayer

func build_audio() -> void:
	if DisplayServer.get_name() == "headless":
		return
	bus_music = _add_audio_bus("Music")
	bus_sfx = _add_audio_bus("SFX")
	music_player = _make_stream_player("MusicPlayer", "res://assets/sound/background-sound.mp3", "Music", true)
	sfx_kick = _make_stream_player("KickSfx", "res://assets/sound/kick.mp3", "SFX", false)
	sfx_whistle = _make_stream_player("WhistleSfx", "res://assets/sound/referee-start.mp3", "SFX", false)
	# Special-shot "whoosh" reuses the kick clip pitched down; the crowd roar is optional
	# and silently skipped if its asset isn't present (see _make_stream_player).
	sfx_special = _make_stream_player("SpecialSfx", "res://assets/sound/kick.mp3", "SFX", false)
	if sfx_special != null:
		sfx_special.pitch_scale = 0.7
	sfx_roar = _make_stream_player("RoarSfx", "res://assets/sound/crowd-roar.mp3", "SFX", false)
	if music_player != null:
		music_player.play()

func _add_audio_bus(bus_name: String) -> int:
	var idx := AudioServer.bus_count
	AudioServer.add_bus(idx)
	AudioServer.set_bus_name(idx, bus_name)
	AudioServer.set_bus_send(idx, "Master")
	return idx

func _make_stream_player(node_name: String, path: String, bus: String, loop: bool) -> AudioStreamPlayer:
	if not ResourceLoader.exists(path):
		push_warning("Audio asset missing: %s" % path)
		return null
	var player := AudioStreamPlayer.new()
	player.name = node_name
	var stream := load(path)
	if stream is AudioStreamMP3:
		stream.loop = loop
	player.stream = stream
	player.bus = bus
	add_child(player)
	return player

func play_kick() -> void:
	if sfx_kick != null:
		sfx_kick.play()

func play_whistle() -> void:
	if sfx_whistle != null:
		sfx_whistle.play()

func play_special() -> void:
	if sfx_special != null:
		sfx_special.play()

func play_crowd_roar() -> void:
	if sfx_roar != null:
		sfx_roar.play()

## Applies linear [0,1] volumes (converted to dB) to Master/Music/SFX buses.
func apply_volumes(master: float, music: float, sfx: float) -> void:
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("Master"), linear_to_db(master))
	if bus_music >= 0:
		AudioServer.set_bus_volume_db(bus_music, linear_to_db(music))
	if bus_sfx >= 0:
		AudioServer.set_bus_volume_db(bus_sfx, linear_to_db(sfx))

func _exit_tree() -> void:
	for player in [music_player, sfx_kick, sfx_whistle, sfx_special, sfx_roar]:
		if player != null:
			player.stop()
			player.stream = null
