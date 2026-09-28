-- ============================================================================
-- TIV WIREMOD INTEGRATION - CLIENT
-- ============================================================================

TIV = TIV or {}
TIV.Wire = TIV.Wire or {}

-- Safe Wiremod detection
function TIV.Wire.IsAvailable()
    return istable(rawget(_G, "WireLib"))
end

-- Wire tool UI strings
if language and language.Add then
    language.Add("Tool.wire_tiv.name", "TIV Controller Tool (Wire)")
    language.Add("Tool.wire_tiv.desc", "Spawn or link a Wire TIV Controller to a Tornado Intercept Vehicle.")
    language.Add("Tool.wire_tiv.0", "Primary: Spawn a TIV Controller / Secondary: Link to TIV / Reload: Unlink")
    language.Add("Undone_gmod_wire_tiv_controller", "Undone Wire TIV Controller")
    language.Add("Cleanup_gmod_wire_tiv_controller", "Wire TIV Controllers")
    language.Add("Cleaned_gmod_wire_tiv_controller", "Cleaned up all Wire TIV Controllers")
    language.Add("SBoxLimit_gmod_wire_tiv_controllers", "You've hit the Wire TIV Controller limit!")
end

-- Expression 2 documentation helper
if E2Helper and file.Exists("entities/gmod_wire_expression2/core/custom/cl_tiv.lua", "LUA") then
    include("entities/gmod_wire_expression2/core/custom/cl_tiv.lua")
end

print("[TIV] Wiremod client module loaded")
