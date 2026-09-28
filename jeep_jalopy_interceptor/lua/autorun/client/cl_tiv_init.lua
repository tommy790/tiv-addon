-- ============================================================================
-- TIV CLIENT INIT
-- ============================================================================
print("[TIV] Loading client modules...")

include("tiv/config/sh_config.lua")
include("tiv/progression/sh_progression.lua")
include("tiv/customization/sh_custom_config.lua")
include("tiv/progression/cl_progression.lua")
include("tiv/editor/cl_editor_3d.lua")

include("tiv/config/cl_settings.lua")
include("tiv/hud/cl_hud.lua")
include("tiv/instruments/cl_instruments.lua")
include("tiv/instruments/cl_radar_screen.lua")
include("tiv/deploy/cl_deploy.lua")
include("tiv/animation/cl_spike_anim.lua")
include("tiv/wire/cl_wire.lua")

print("[TIV] Client modules loaded!")