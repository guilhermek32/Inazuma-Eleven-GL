class_name RenderTier
extends RefCounted

## Visual quality tier of this process, chosen once at start-up.
##
##   FULL  the desktop Forward+ look: SSAO, SSIL, volumetric fog, a baked
##         VoxelGI probe, four shadowed floodlights and the full crowd.
##   WEB   the Compatibility renderer (the web export, or a desktop run with
##         --rendering-method gl_compatibility). SSAO, SSIL, volumetric fog and
##         VoxelGI do not exist there, so StadiumBuilder skips them (no VoxelGI
##         bake at load) and compensates with ambient fill, depth fog and glow;
##         it also thins the crowd and the shadowed lights for frame time.
##
## Override with `?quality=full|web` (web) or `-- --quality=full|web`
## (desktop), e.g. to compare the tiers on one build. Forcing FULL on the
## Compatibility renderer only restores what that renderer supports.

enum { FULL, WEB }

static func detect() -> int:
	match LaunchArgs.value("quality"):
		"full":
			return FULL
		"web":
			return WEB
	if OS.has_feature("web") or RenderingServer.get_current_rendering_method() == "gl_compatibility":
		return WEB
	return FULL

static func tier_name(tier: int) -> String:
	return "web" if tier == WEB else "full"
