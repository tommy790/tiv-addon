-- ============================================================================
-- TIV CONFIG
-- ============================================================================

TIV = TIV or {}
TIV.Config = TIV.Config or {}

-- ============================================================================
-- VEHICLE HEADING BASIS
--
-- This file documents the addon's vehicle-local space as
--     Forward: +Y (along veh:GetForward())
--     Right:   +X (along veh:GetRight())
-- In GMod that cannot hold: Angle:Forward() is local +X and Angle:Right() is
-- local -Y, so the two halves disagree by 90 degrees. Anything that derives a
-- direction from veh:GetForward()/GetRight() therefore needs to know which of
-- the two the vehicle's nose actually is.
--
-- TIV.Config.HeadingOffsetDeg rotates the vehicle-relative components so that
-- "forward" means along the nose. Derived from two field reports: with 0 a
-- vortex visually dead ahead read as 090 RIGHT, and with -90 the same vortex
-- read as 180 ASTERN. Each 90 degrees of offset moves the reading 90 degrees,
-- so -90 overshot by 180 and +90 is correct.
--
-- Every relative-bearing consumer (radar screen, HUD, Expression 2) must go
-- through TIV.RelativeBearing so they cannot disagree with each other.
-- ============================================================================
-- Confirmed in game: with 0 a vortex visually dead ahead read as REL BRG 090
-- RIGHT. +90 rotates the reference frame onto the nose.
TIV.Config.HeadingOffsetDeg = 90

-- Separate correction for where the blip is PAINTED, because cam.Start3D2D's
-- canvas orientation is a different question from which way the vehicle's nose
-- points. Rotates the blip (and the movement arrow) clockwise about the disc
-- centre. Calibrate with tiv_radar_blip_offset, then put the number here.
TIV.Config.BlipOffsetDeg = 0

-- Live override so this can be calibrated in game without editing files:
--   tiv_radar_heading_offset 90
-- The radar screen also paints the value currently in force. Once the correct
-- number is known, put it in HeadingOffsetDeg above and this can stay at 0.
if CLIENT then
    CreateClientConVar("tiv_radar_heading_offset", "0", true, false,
        "Degrees to rotate the radar's heading basis. 0 uses TIV.Config.HeadingOffsetDeg.")
    CreateClientConVar("tiv_radar_blip_offset", "0", true, false,
        "Degrees to rotate the radar blip clockwise about the disc centre. 0 uses TIV.Config.BlipOffsetDeg.")
end

--- Heading correction currently in force, in degrees.
-- Precedence: offline-probe override, then the client convar, then the config.
-- Returns 0 when nothing is set, i.e. veh:GetForward() is taken at face value.
function TIV.HeadingOffsetDeg()
    local probe = tonumber(TIV_HEADING_OFFSET_DEG or "")
    if probe then return probe end
    if CLIENT and GetConVar then
        local cv = GetConVar("tiv_radar_heading_offset")
        if IsValid(cv) then
            local v = tonumber(cv:GetString())
            if v and v ~= 0 then return v end
        end
    end
    return TIV.Config.HeadingOffsetDeg or 0
end

--- Canvas rotation applied to the painted blip, in degrees clockwise.
-- Precedence: offline-probe override, then the client convar, then the config.
function TIV.BlipOffsetDeg()
    local probe = tonumber(TIV_RADAR_BLIP_OFFSET or "")
    if probe then return probe end
    if CLIENT and GetConVar then
        local cv = GetConVar("tiv_radar_blip_offset")
        if IsValid(cv) then
            local v = tonumber(cv:GetString())
            if v and v ~= 0 then return v end
        end
    end
    return TIV.Config.BlipOffsetDeg or 0
end

--- Track-up bearing of a world position relative to a vehicle's nose.
-- @param veh      Entity  the vehicle whose nose defines 000
-- @param targetPos Vector world position of the thing being reported on
-- @return number   degrees in [0, 360), clockwise from the nose
function TIV.RelativeBearing(veh, targetPos)
    if not IsValid(veh) or not targetPos then return 0 end

    local fwd = veh:GetForward()
    local rgt = veh:GetRight()
    local fwd2D = Vector(fwd.x, fwd.y, 0):GetNormalized()
    local rgt2D = Vector(rgt.x, rgt.y, 0):GetNormalized()

    local rel    = targetPos - veh:GetPos()
    local relFwd = rel:Dot(fwd2D)
    local relRgt = rel:Dot(rgt2D)

    local off = TIV.HeadingOffsetDeg()
    if off ~= 0 then
        local hr = math.rad(off)
        local c, s = math.cos(hr), math.sin(hr)
        -- With +90 this is (newFwd, newRgt) = (-relRgt, relFwd): relFwd ends up
        -- measuring along local +Y and relRgt along local +X.
        relFwd, relRgt = c * relFwd - s * relRgt, s * relFwd + c * relRgt
    end

    -- Normalise into [0, 360). atan2 can return exactly -0.0 and -0.0 < 0 is
    -- false, so "if negative then add 360" leaves it at -0, which then fails
    -- both "< 45" and ">= 315" in the usual sector chain and lands in the LEFT
    -- else. A vortex dead ahead would read as LEFT.
    return math.deg(math.atan2(relRgt, relFwd)) % 360
end

-- Runtime setting bounds
TIV.Config.SpikeCountConvarMin     = 0
TIV.Config.SpikeCountConvarMax     = 6
TIV.Config.SpikeForceConvarMin     = 0
TIV.Config.SpikeForceConvarMax     = 200000
TIV.Config.HideSpikes              = false
TIV.Config.CompatWindForceScaleMin = 0.1
TIV.Config.CompatWindForceScaleMax = 1.0

-- Compat slider bounds (single source of truth)
TIV.Config.CompatMaxDeployLinearMin   = 50
TIV.Config.CompatMaxDeployLinearMax   = 5000
TIV.Config.CompatMaxDeployAngularMin  = 20
TIV.Config.CompatMaxDeployAngularMax  = 4000
TIV.Config.CompatRecoveryCooldownMin  = 0
TIV.Config.CompatRecoveryCooldownMax  = 30

TIV.Config.LoftWindMin = 50

-- DEPLOYMENT
TIV.Config.DeployKey            = KEY_B
TIV.Config.LowerTime            = 3
TIV.Config.SpikeCount           = 6
TIV.Config.LowerAmount          = 10

-- SUSPENSION LOWERING LIMITS
TIV.Config.SuspensionLimits = {
    jeep    = 10,
    jalopy  = 10,
    apc     = 10,
}

-- SPIKES
TIV.Config.SpikeModel           = "models/props_junk/harpoon002a.mdl"
-- Hover offset of idle spike above the offset point, in units (positive = up).
TIV.Config.SpikeHoverOffset     = 60
TIV.Config.SpikeDriveDepth      = 15
TIV.Config.SpikeDriveDuration   = 3.0
TIV.Config.SpikeRetractDuration = 3.0

-- ANCHOR / BALLSOCKET
-- Force limit of 0 = unbreakable by force. The loft system handles all
-- spike removal explicitly via TIV.Anchor.BreakSpike(). This matches the
-- original design intent and prevents the "vehicle dragged with spikes
-- planted" failure mode where joints silently break under tornado wind.
TIV.Config.SpikeForceLimit      = 0
TIV.Config.BallSocketForceLimit = 0
TIV.Config.AnchorPivotLimit     = 28

-- LOFT MECHANICS
TIV.Config.LoftWindThreshold    = 160
TIV.Config.LoftForceMultiplier  = 50
TIV.Config.LoftTumbleForce      = 1000

-- Wind force applied to vehicle while anchored
TIV.Config.AnchoredWindForce    = 0.8
TIV.Config.AnchoredRockTorque   = 5.5

-- WIND
TIV.Config.WindEnabled          = true
TIV.Config.WindDefault          = 0
TIV.Config.WindMaxSimulated     = 350

-- INSTRUMENTS
TIV.Config.InstrumentUpdateRate = 0.1

-- HUD
TIV.Config.HUDEnabled           = true

-- STRESS (centralized thresholds)
TIV.Config.Stress = {
    TurbulenceMinMPH = 50,    -- wind speed at which to start applying turbulence
    TorqueMin        = 0.3,   -- stress level at which to start rocking torque
    SoundHigh        = 0.6,   -- > this uses StressHighSoundChance
    SoundCrit        = 0.9,   -- > this uses StressCritChance
    HUDPulse         = 0.7,   -- HUD bar pulses above this stress
    HUDMarker        = 0.7,   -- visual marker on the HUD bar
}

TIV.Config.StressLowSoundChance  = 0.005
TIV.Config.StressHighSoundChance = 0.04
TIV.Config.StressCritChance      = 0.10

-- SPIKE SPACING
TIV.Config.SpikeCountMin        = TIV.Config.SpikeCountConvarMin
TIV.Config.SpikeCountMax        = TIV.Config.SpikeCountConvarMax

-- SESSION TRACKING
TIV.Config.SessionSeed          = math.random(100000, 999999)

-- ============================================================================
-- SHARED VEHICLE DETECTION
-- One source of truth for "is this a TIV?". Called from cl_deploy, sv_deploy,
-- cl_hud, sv_instruments. Add new vehicle classes/models here only.
-- ============================================================================
TIV.SupportedClasses = {
    prop_vehicle_jeep      = true,
    prop_vehicle_jeep_old  = true,
    prop_vehicle_jalopy    = true,
    prop_vehicle_apc       = true,
}

TIV.SupportedModelKeywords = { "jeep", "jalopy", "apc", "interceptor" }

-- Checked BEFORE the tag and class lists, so an entity here is never a TIV even
-- if something tags it. Seats in particular are worth excluding explicitly:
-- GMod gives a jeep's own seats the class prop_vehicle_jeep, so they would
-- otherwise match SupportedClasses and resolve as a vehicle in their own right,
-- heading and position included.
TIV.ExcludedClasses = {
    prop_vehicle_prisoner_pod = true,
    prop_vehicle_airboat      = true,
}

TIV.ExcludedModelKeywords = {
    "prisoner_pod",
    "airboat",
    "pod",
    "seat",
}

function TIV.TagAsInterceptor(ent, isInterceptor)
    if not IsValid(ent) then return end
    if isInterceptor == nil then isInterceptor = true end
    ent.IsTIVVehicle = isInterceptor
    ent:SetNWBool("TIV_Interceptor", isInterceptor)
    if isInterceptor then
        ent.TIV_HasArmor = true
    end
    if SERVER then
        local model = ent:GetModel() or ""
        print(string.format("[TIV] Entity [%d] (%s) %s as Interceptor",
            ent:EntIndex(), model, isInterceptor and "registered" or "unregistered"))
    end
end

function TIV.IsSupportedVehicle(ent)
    if not IsValid(ent) then return false end

    -- Exclusions win over everything below, including an explicit tag.
    local class = string.lower(ent:GetClass() or "")
    if TIV.ExcludedClasses[class] then return false end
    local model = string.lower(ent:GetModel() or "")
    for _, kw in ipairs(TIV.ExcludedModelKeywords) do
        if string.find(model, kw, 1, true) then return false end
    end

    if ent.IsTIVVehicle or ent:GetNWBool("TIV_Interceptor", false) or ent:GetNWBool("IsTIVVehicle", false) then
        return true
    end
    if ent._TIVConfig ~= nil or ent.TIV_HasArmor or (ent.TIV_Controller and IsValid(ent.TIV_Controller)) then
        return true
    end
    if TIV.SupportedClasses[class] then return true end
    -- There used to be a bare `ent:IsVehicle() then return true` here. It made
    -- every vehicle on the map a TIV -- airboats, prisoner pods, and the seats of
    -- unrelated jeeps -- which is why the radar and HUD would attach to them.
    if string.find(model, "vehicle.mdl", 1, true) then return true end
    for _, kw in ipairs(TIV.SupportedModelKeywords) do
        if string.find(model, kw, 1, true) then return true end
    end
    return false
end

-- Resolve a player's TIV vehicle, walking seat parent / GetBase if needed.
-- ----------------------------------------------------------------------------
-- Who owns/drives this vehicle. sv_spike_anim, sv_custom_components and the
-- spike-count resolver all needed the same lookup and each had their own copy;
-- the upgrade-gated visuals depend on getting the same answer everywhere.
-- ----------------------------------------------------------------------------
function TIV.ResolveOwner(veh)
    if not IsValid(veh) then return nil end
    local ply = (veh.GetDriver and veh:GetDriver()) or veh._TIVOwner
    if not IsValid(ply) and veh.CPPIGetOwner then
        ply = veh:CPPIGetOwner()
    end
    if not IsValid(ply) and game.SinglePlayer then
        local humans = player.GetHumans()
        ply = humans and humans[1] or nil
    end
    return IsValid(ply) and ply or nil
end

function TIV.ResolveVehicle(ply)
    if not IsValid(ply) then return nil end
    local seat = ply:GetVehicle()
    if IsValid(seat) then
        if TIV.IsSupportedVehicle(seat) then return seat end
        local parent = seat:GetParent()
        if IsValid(parent) and TIV.IsSupportedVehicle(parent) then return parent end
        if isfunction(seat.GetBase) then
            local base = seat:GetBase()
            if IsValid(base) and TIV.IsSupportedVehicle(base) then return base end
        end
    end
    if isfunction(ply.GetSimfphys) then
        local simf = ply:GetSimfphys()
        if IsValid(simf) and TIV.IsSupportedVehicle(simf) then return simf end
    end
    return nil
end

-- Retrieve all entities and vehicles currently identified as interceptors
function TIV.GetIdentifiedInterceptors()
    local list = {}
    local seenModels = {}

    if CLIENT then
        local ply = LocalPlayer()
        local curVeh = TIV.ResolveVehicle and TIV.ResolveVehicle(ply)
        if IsValid(curVeh) then
            local mdl = curVeh:GetModel()
            if mdl and mdl ~= "" then
                table.insert(list, {
                    entity    = curVeh,
                    model     = mdl,
                    name      = "Current Vehicle (" .. string.GetFileFromFilename(mdl) .. ")",
                    isCurrent = true,
                })
                seenModels[string.lower(mdl)] = true
            end
        end
    end

    for _, ent in ipairs(ents.GetAll()) do
        if IsValid(ent) and TIV.IsSupportedVehicle(ent) then
            local mdl = ent:GetModel()
            if mdl and mdl ~= "" and not seenModels[string.lower(mdl)] then
                local label = "World " .. (ent:IsVehicle() and "Vehicle" or "Entity") .. " (" .. string.GetFileFromFilename(mdl) .. ")"
                table.insert(list, {
                    entity = ent,
                    model  = mdl,
                    name   = label,
                })
                seenModels[string.lower(mdl)] = true
            end
        end
    end

    return list
end

-- ============================================================================
-- SPIKE OFFSETS PER VEHICLE MODEL
-- ============================================================================
TIV.Config.SpikeOffsets = {
    jeep = {
        { pos = Vector( 25,   50, 0), ang = Angle( 90, 0, 0), name = "Front Right", group = "front" },
        { pos = Vector(-25,   50, 0), ang = Angle( 90, 0, 0), name = "Front Left",  group = "front" },
        { pos = Vector( 30,  -20, 0), ang = Angle( 90, 0, 0), name = "Mid Right",   group = "mid"   },
        { pos = Vector(-30,  -20, 0), ang = Angle( 90, 0, 0), name = "Mid Left",    group = "mid"   },
        { pos = Vector( 20, -100, 0), ang = Angle( 90, 0, 0), name = "Rear Right",  group = "rear"  },
        { pos = Vector(-20, -100, 0), ang = Angle( 90, 0, 0), name = "Rear Left",   group = "rear"  },
    },
    jalopy = {
        { pos = Vector( 25,   45, 0), ang = Angle( 90, 0, 0), name = "Front Right", group = "front" },
        { pos = Vector(-25,   45, 0), ang = Angle( 90, 0, 0), name = "Front Left",  group = "front" },
        { pos = Vector( 25,    0, 0), ang = Angle( 90, 0, 0), name = "Mid Right",   group = "mid"   },
        { pos = Vector(-25,    0, 0), ang = Angle( 90, 0, 0), name = "Mid Left",    group = "mid"   },
        { pos = Vector( 25, -100, 0), ang = Angle( 90, 0, 0), name = "Rear Right",  group = "rear"  },
        { pos = Vector(-25, -100, 0), ang = Angle( 90, 0, 0), name = "Rear Left",   group = "rear"  },
    },
    prop_vehicle_apc = {
        { pos = Vector( 35,   90, 0), ang = Angle( 90, 0, 0), name = "Front Right", group = "front" },
        { pos = Vector(-35,   90, 0), ang = Angle( 90, 0, 0), name = "Front Left",  group = "front" },
        { pos = Vector( 35,   10, 0), ang = Angle( 90, 0, 0), name = "Mid Right",   group = "mid"   },
        { pos = Vector(-35,   10, 0), ang = Angle( 90, 0, 0), name = "Mid Left",    group = "mid"   },
        { pos = Vector( 35, -110, 0), ang = Angle( 90, 0, 0), name = "Rear Right",  group = "rear"  },
        { pos = Vector(-35, -110, 0), ang = Angle( 90, 0, 0), name = "Rear Left",   group = "rear"  },
    },
}

-- ============================================================================
-- WIRE CONTROLLER OFFSETS PER VEHICLE MODEL
-- Placement offsets for the auto-attached Wiremod controller entity.
-- ============================================================================
TIV.Config.WireControllerOffsets = {
    jeep = {
        pos = Vector(0, 15, 36),
        ang = Angle(0, -90, 0),
    },
    jalopy = {
        pos = Vector(0, 15, 36),
        ang = Angle(0, -90, 0),
    },
    prop_vehicle_apc = {
        pos = Vector(0, 35, 50),
        ang = Angle(0, -90, 0),
    },
}

