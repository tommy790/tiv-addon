-- ============================================================================
-- TIV RUNTIME SERVER CVARS
-- ============================================================================

TIV = TIV or {}
TIV.Config = TIV.Config or {}

local function clampInt(value, minValue, maxValue)
    return math.Clamp(math.floor(tonumber(value) or minValue), minValue, maxValue)
end

local function applyRuntimeSpikeConfig()
    local count = clampInt(
        GetConVar("tiv_spike_count"):GetInt(),
        TIV.Config.SpikeCountConvarMin,
        TIV.Config.SpikeCountConvarMax
    )
    local force = clampInt(
        GetConVar("tiv_spike_force"):GetInt(),
        TIV.Config.SpikeForceConvarMin,
        TIV.Config.SpikeForceConvarMax
    )

    TIV.Config.SpikeCount           = count
    TIV.Config.SpikeForceLimit      = force
    TIV.Config.BallSocketForceLimit = force
end

-- Visibility is deliberately independent from spike count. Hidden spikes keep
-- deploying and anchoring normally; only their models and shadows disappear.
local function applyRuntimeSpikeVisibility()
    local convar = GetConVar("tiv_hide_spikes")
    TIV.Config.HideSpikes = convar and convar:GetBool() or false

    for _, data in pairs((TIV.Deploy and TIV.Deploy.Vehicles) or {}) do
        for _, spikeData in ipairs(data.spikes or {}) do
            local spike = spikeData.entity
            if IsValid(spike) then
                if TIV.SpikeAnim and TIV.SpikeAnim.ApplyVisibility then
                    TIV.SpikeAnim.ApplyVisibility(spike)
                else
                    spike:SetNoDraw(TIV.Config.HideSpikes)
                    spike:DrawShadow(not TIV.Config.HideSpikes)
                end
            end
        end
    end
end

local function applyRuntimeCompatConfig()
    TIV.Compat = TIV.Compat or {}
    TIV.Compat.Enabled = GetConVar("tiv_compat_mode"):GetBool()

    TIV.Compat.MaxDeployLinearVelocity = math.Clamp(
        GetConVar("tiv_compat_max_deploy_linear"):GetFloat(),
        TIV.Config.CompatMaxDeployLinearMin,
        TIV.Config.CompatMaxDeployLinearMax
    )
    TIV.Compat.MaxDeployAngularVelocity = math.Clamp(
        GetConVar("tiv_compat_max_deploy_angular"):GetFloat(),
        TIV.Config.CompatMaxDeployAngularMin,
        TIV.Config.CompatMaxDeployAngularMax
    )
    TIV.Compat.RecoveryCooldown = math.Clamp(
        GetConVar("tiv_compat_recovery_cooldown"):GetFloat(),
        TIV.Config.CompatRecoveryCooldownMin,
        TIV.Config.CompatRecoveryCooldownMax
    )
    TIV.Compat.AnchoredWindForceScale = math.Clamp(
        GetConVar("tiv_compat_anchored_wind_scale"):GetFloat(),
        TIV.Config.CompatWindForceScaleMin,
        TIV.Config.CompatWindForceScaleMax
    )
end

local function applyRuntimeLoftConfig()
    local threshold = math.Clamp(
        GetConVar("tiv_loft_wind_threshold"):GetFloat(),
        TIV.Config.LoftWindMin,
        TIV.Config.WindMaxSimulated or 350
    )
    TIV.Config.LoftWindThreshold = threshold
end

-- Anchor tuning. Writes straight into TIV.Config.Anchor, which is the only
-- place the anchor/loft mechanics read their numbers from, so a convar change
-- takes effect on the next deploy (and on the next hold re-cut) without
-- touching any of the mechanics.
local function applyRuntimeAnchorConfig()
    local A = TIV.Config.Anchor
    if not A then return end

    A.StressedForceLimit = math.Clamp(
        GetConVar("tiv_anchor_stress_force"):GetFloat(), 1000, 1000000)
    A.StressedTorqueLimit = A.StressedForceLimit
    A.PullOutDistance = math.Clamp(GetConVar("tiv_anchor_pullout"):GetFloat(), 2, 60)
    A.EmbedConstant   = math.Clamp(GetConVar("tiv_anchor_soil_constant"):GetFloat(), 200, 200000)
    A.UseGrabbers     = GetConVar("tiv_anchor_use_grabbers"):GetBool() and 1 or 0

    -- Storm load. The scale is a straight multiplier on the whole load, which
    -- is the one knob worth having live: it is what decides whether the
    -- threshold is a wall or a suggestion.
    A.WindLoadScale = math.Clamp(GetConVar("tiv_anchor_wind_load"):GetFloat(), 0, 4)
    A.WindLoadLift  = math.Clamp(GetConVar("tiv_anchor_wind_lift"):GetFloat(), 0, 1.5)

    -- The availability cache keys off UseGrabbers, so flipping the convar has
    -- to be allowed to change the answer.
    if TIV.WireAnchor and TIV.WireAnchor.InvalidateCache then
        TIV.WireAnchor.InvalidateCache()
    end
end

CreateConVar(
    "tiv_spike_count",
    tostring(TIV.Config.SpikeCount),
    { FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED },
    "Number of TIV spikes used during deploy.",
    TIV.Config.SpikeCountConvarMin,
    TIV.Config.SpikeCountConvarMax
)

CreateConVar(
    "tiv_hide_spikes",
    "0",
    { FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED },
    "Hide TIV spike models while retaining their deploy and anchor behavior."
)

CreateConVar(
    "tiv_compat_mode",
    "1",
    { FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED },
    "Enable TIV compatibility safety guards for external tornado/vehicle addons."
)

CreateConVar(
    "tiv_compat_max_deploy_linear",
    "650",
    { FCVAR_ARCHIVE, FCVAR_REPLICATED },
    "Max linear velocity allowed before deploy starts (compat mode).",
    TIV.Config.CompatMaxDeployLinearMin,
    TIV.Config.CompatMaxDeployLinearMax
)

CreateConVar(
    "tiv_compat_max_deploy_angular",
    "300",
    { FCVAR_ARCHIVE, FCVAR_REPLICATED },
    "Max angular velocity allowed before deploy starts (compat mode).",
    TIV.Config.CompatMaxDeployAngularMin,
    TIV.Config.CompatMaxDeployAngularMax
)

CreateConVar(
    "tiv_compat_recovery_cooldown",
    "3.0",
    { FCVAR_ARCHIVE, FCVAR_REPLICATED },
    "Cooldown seconds after a compatibility safety recovery.",
    TIV.Config.CompatRecoveryCooldownMin,
    TIV.Config.CompatRecoveryCooldownMax
)

CreateConVar(
    "tiv_compat_anchored_wind_scale",
    "0.65",
    { FCVAR_ARCHIVE, FCVAR_REPLICATED },
    "Scales anchored wind force while compat mode is enabled.",
    TIV.Config.CompatWindForceScaleMin,
    TIV.Config.CompatWindForceScaleMax
)

CreateConVar(
    "tiv_spike_force",
    tostring(TIV.Config.SpikeForceLimit),
    { FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED },
    "Force limit for spike/world and vehicle/spike anchors (0 = unbreakable by force).",
    TIV.Config.SpikeForceConvarMin,
    TIV.Config.SpikeForceConvarMax
)

CreateConVar(
    "tiv_loft_wind_threshold",
    tostring(TIV.Config.LoftWindThreshold),
    { FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED },
    "Wind MPH threshold where anchored spikes fail and loft begins.",
    TIV.Config.LoftWindMin,
    TIV.Config.WindMaxSimulated or 350
)

CreateConVar(
    "tiv_anchor_stress_force",
    tostring(TIV.Config.Anchor and TIV.Config.Anchor.StressedForceLimit or 50000),
    { FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED },
    "Force limit (N) the spike holds are re-cut at once the loft sequence is failing. They keep resisting, but can now lose.",
    1000,
    1000000
)

CreateConVar(
    "tiv_anchor_wind_load",
    "1",
    { FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED },
    "Multiplier on the storm load a failing TIV feels. At 1 the wind matches 70% of the anchors' total force limit at the loft threshold and grows with the square of the speed past it; 0 returns to external storm mods only.",
    0,
    4
)

CreateConVar(
    "tiv_anchor_wind_lift",
    tostring(TIV.Config.Anchor and TIV.Config.Anchor.WindLoadLift or 0.4),
    { FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED },
    "Fraction of the storm load applied upward. This is the component the anchors actually have to beat to keep the vehicle on the ground.",
    0,
    1.5
)

CreateConVar(
    "tiv_anchor_pullout",
    tostring(TIV.Config.Anchor and TIV.Config.Anchor.PullOutDistance or 11),
    { FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED },
    "How far (units) a spike must be dragged out of the ground before it loses its grip and lets go.",
    2,
    60
)

CreateConVar(
    "tiv_anchor_soil_constant",
    tostring(TIV.Config.Anchor and TIV.Config.Anchor.EmbedConstant or 6000),
    { FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED },
    "Soil grip stiffness (N per unit of stretch) for each spike's ground anchors.",
    200,
    200000
)

CreateConVar(
    "tiv_anchor_use_grabbers",
    "1",
    { FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED },
    "Use Wire Grabbers for spike anchoring when Wiremod is installed (0 = always use ball sockets)."
)

CreateConVar(
    "tiv_wire_auto_controller",
    "1",
    { FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED },
    "Automatically attach a Wiremod controller entity to TIV vehicles when Wiremod is installed."
)

CreateConVar(
    "tiv_wire_hide_controller",
    "0",
    { FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED },
    "Hide the physical model of the auto-attached Wiremod controller."
)

CreateConVar(
    "tiv_suspension_limit",
    "0",
    { FCVAR_ARCHIVE, FCVAR_REPLICATED },
    "Override suspension lowering distance in units (0 = automatic based on vehicle suspension limit)."
)

CreateConVar(
    "tiv_auto_deploy_wind",
    "0",
    { FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED },
    "Automatically initiate deployment when wind speed exceeds this MPH threshold (0 = disabled).",
    0,
    300
)

CreateConVar(
    "tiv_deploy_speed",
    "1.0",
    { FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED },
    "Speed multiplier for lowering/raising hydraulic suspension (0.5 to 3.0).",
    0.5,
    3.0
)

CreateConVar(
    "tiv_deploy_handbrake",
    "1",
    { FCVAR_ARCHIVE, FCVAR_REPLICATED },
    "Automatically apply vehicle handbrake when anchored."
)

CreateConVar(
    "tiv_spike_drive_depth",
    "18",
    { FCVAR_ARCHIVE, FCVAR_REPLICATED },
    "Ground penetration depth in units when driving spikes into terrain.",
    5,
    50
)

CreateConVar(
    "tiv_spike_spread_offset",
    "0",
    { FCVAR_ARCHIVE, FCVAR_REPLICATED },
    "Lateral spread adjustment in units for spike mounting positions.",
    -25,
    25
)

CreateConVar(
    "tiv_spike_length_offset",
    "0",
    { FCVAR_ARCHIVE, FCVAR_REPLICATED },
    "Longitudinal (forward/rear) adjustment in units for spike mounting positions.",
    -40,
    40
)

CreateConVar(
    "tiv_spike_group_front",
    "1",
    { FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED },
    "Enable/disable the front pair of anchor spikes."
)

CreateConVar(
    "tiv_spike_group_mid",
    "1",
    { FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED },
    "Enable/disable the middle pair of anchor spikes."
)

CreateConVar(
    "tiv_spike_group_rear",
    "1",
    { FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED },
    "Enable/disable the rear pair of anchor spikes."
)

CreateConVar(
    "tiv_cheat_godmode_anchors",
    "0",
    { FCVAR_ARCHIVE, FCVAR_REPLICATED },
    "Cheat: Spikes never break and vehicle cannot be lofted by tornado winds."
)

CreateConVar(
    "tiv_cheats_enabled",
    "1",
    { FCVAR_ARCHIVE, FCVAR_REPLICATED },
    "Allow TIV sandbox cheats and instant upgrade unlocking."
)

-- Real bug fix: callbacks had `*,*` paste artifacts (function(_, _, _) is correct).
cvars.AddChangeCallback("tiv_spike_count", function(_, old, new)
    applyRuntimeSpikeConfig()
    print(string.format("[TIV] Spike count: %s -> %s (next deploy)", tostring(old), tostring(new)))
end, "TIV_RuntimeSpikeCount")

cvars.AddChangeCallback("tiv_spike_force", function(_, _, _)
    applyRuntimeSpikeConfig()
end, "TIV_RuntimeSpikeForce")

cvars.AddChangeCallback("tiv_hide_spikes", function(_, _, _)
    applyRuntimeSpikeVisibility()
end, "TIV_RuntimeSpikeVisibility")

cvars.AddChangeCallback("tiv_compat_mode", function(_, _, _)
    applyRuntimeCompatConfig()
end, "TIV_RuntimeCompatMode")

cvars.AddChangeCallback("tiv_compat_max_deploy_linear", function(_, _, _)
    applyRuntimeCompatConfig()
end, "TIV_RuntimeCompatMaxDeployLinear")

cvars.AddChangeCallback("tiv_compat_max_deploy_angular", function(_, _, _)
    applyRuntimeCompatConfig()
end, "TIV_RuntimeCompatMaxDeployAngular")

cvars.AddChangeCallback("tiv_compat_recovery_cooldown", function(_, _, _)
    applyRuntimeCompatConfig()
end, "TIV_RuntimeCompatRecoveryCooldown")

cvars.AddChangeCallback("tiv_compat_anchored_wind_scale", function(_, _, _)
    applyRuntimeCompatConfig()
end, "TIV_RuntimeCompatWindScale")

cvars.AddChangeCallback("tiv_loft_wind_threshold", function(_, _, _)
    applyRuntimeLoftConfig()
end, "TIV_RuntimeLoftThreshold")

cvars.AddChangeCallback("tiv_anchor_stress_force", function(_, _, new)
    applyRuntimeAnchorConfig()
    print(string.format("[TIV] Anchor stress force: %s N (next hold re-cut)", tostring(new)))
end, "TIV_RuntimeAnchorStressForce")

cvars.AddChangeCallback("tiv_anchor_pullout", function(_, _, _)
    applyRuntimeAnchorConfig()
end, "TIV_RuntimeAnchorPullout")

cvars.AddChangeCallback("tiv_anchor_soil_constant", function(_, _, _)
    applyRuntimeAnchorConfig()
end, "TIV_RuntimeAnchorSoilConstant")

cvars.AddChangeCallback("tiv_anchor_use_grabbers", function(_, _, new)
    applyRuntimeAnchorConfig()
    print(string.format("[TIV] Spike anchoring: %s (next deploy)",
        tobool(new) and "Wire Grabbers when available" or "ball sockets"))
end, "TIV_RuntimeAnchorUseGrabbers")

cvars.AddChangeCallback("tiv_wire_hide_controller", function(_, _, new)
    local hide = tobool(new)
    if TIV.Wire and TIV.Wire.UpdateControllerVisibility then
        TIV.Wire.UpdateControllerVisibility(hide)
    end
end, "TIV_RuntimeWireHideController")


-- Single init path (was duplicated: Initialize hook + 3 timer.Simple calls).
hook.Add("Initialize", "TIV_ApplyRuntimeCvars", function()
    applyRuntimeSpikeConfig()
    applyRuntimeSpikeVisibility()
    applyRuntimeCompatConfig()
    applyRuntimeLoftConfig()
    applyRuntimeAnchorConfig()
end)

print("[TIV] Runtime convars loaded")
