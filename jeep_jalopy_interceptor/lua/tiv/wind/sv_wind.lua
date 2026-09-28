-- ============================================================================
-- TIV WIND SYSTEM
-- Per-vehicle wind sampling (was global). One sample per vehicle per tick.
-- TIV_WindUpdate broadcast removed (was redundant with TIV_InstrumentData).
-- ApplyToEntity now takes an explicit scale instead of hard-coding 0.01.
-- ============================================================================

TIV.Wind = TIV.Wind or {}

TIV.Wind.CurrentMPH    = TIV.Config.WindDefault   -- last global sample (fallback)
TIV.Wind.Direction     = Vector(1, 0, 0)
TIV.Wind.PerVehicle    = TIV.Wind.PerVehicle or {} -- [entIndex] = { mph, dir, provider }

TIV.Wind.ManualMode    = false
TIV.Wind.ManualMPH     = 0
TIV.Wind.ManualDir     = Vector(1, 0, 0)
TIV.Wind.ManualUntil   = 0   -- 0 = no auto-expire

local MANUAL_AUTO_EXPIRE = 900 -- 15 minutes

-- Force constants (centralized magic numbers).
TIV.Wind.FORCE_PER_MPH_PER_KG = 25  -- empirical scaling

-- ============================================================================
-- INTERNAL: SAMPLE WORLD WIND AT A POSITION
-- Returns (mph, direction) without mutating globals. Caller decides what to
-- do with the value. Returns (nil, nil) if no provider responded.
--
-- GStorms API (from gstorms_probe ENT:Think):
--   GSGetGlobalWindspeedAndVectors(pos, entityList, inflowJet, envEnt, curTime, outVector, boolFlag)
--     - Returns: windspeed (number) -- single return value
--     - Writes wind direction into the pre-allocated outVector (6th arg)
--     - ConVar: "gstorms_tornado_inflow_jet" (NOT "gstorms_inflow_jet")
--     - entityList: gs_weatherEntityList.server
--     - envEnt: gs_env.server
-- ============================================================================

-- Pre-allocated output vector for GSGetGlobalWindspeedAndVectors.
-- The function writes the wind direction into this vector each call.
local gsOutVector = Vector(0, 0, 0)

local function IsFiniteNumber(value)
    return isnumber(value)
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function IsUsableVector(value)
    if not isvector(value) then return false end
    return IsFiniteNumber(value.x)
        and IsFiniteNumber(value.y)
        and IsFiniteNumber(value.z)
end

-- XT3 has used both (velocity, speed) and, in some API-facing integrations,
-- (speed, velocity). Accept either without letting NaN/inf poison physics or
-- net.WriteFloat later in the pipeline.
local function NormaliseWindReturns(first, second)
    -- Current XT3 can produce a NaN zero vector while still correctly
    -- returning speed 0 when no tornado exists. Treat a finite zero speed as
    -- calm before validating the unused direction so stale readings clear.
    if IsFiniteNumber(second) and second == 0 then
        return 0, Vector(1, 0, 0)
    end
    if IsFiniteNumber(first) and first == 0 and isvector(second) then
        return 0, Vector(1, 0, 0)
    end

    local velocity, speed
    if IsUsableVector(first) and IsFiniteNumber(second) then
        velocity, speed = first, second
    elseif IsFiniteNumber(first) and IsUsableVector(second) then
        speed, velocity = first, second
    else
        return nil, nil
    end

    if speed < 0 then return nil, nil end

    local lengthSqr = velocity:LengthSqr()
    if not IsFiniteNumber(lengthSqr) then return nil, nil end

    local direction = lengthSqr > 0.01
        and velocity:GetNormalized() or Vector(1, 0, 0)
    return math.Clamp(speed, 0, TIV.Config.WindMaxSimulated), direction
end

local function SampleGStormsTornadoWindAt(pos)
    if not isfunction(GSGetGlobalWindspeedAndVectors) then return nil, nil end
    if not gs_env or not gs_weatherEntityList then return nil, nil end

    local envEnt = gs_env.server or gs_env
    if not envEnt then return nil, nil end
    -- gs_env.server may be an entity or a table depending on GStorms version;
    -- only call IsValid on things that support it.
    if type(envEnt) ~= "table" and IsValid and not IsValid(envEnt) then return nil, nil end

    local entityList = gs_weatherEntityList.server or gs_weatherEntityList or {}

    local inflowCVar = GetConVar("gstorms_tornado_inflow_jet")
    local inflowJet  = inflowCVar and inflowCVar:GetBool() or false

    -- Reset the output vector before the call.
    gsOutVector.x, gsOutVector.y, gsOutVector.z = 0, 0, 0

    -- Full 7-argument call matching GStorms probe:
    --   GSGetGlobalWindspeedAndVectors(pos, entityList, inflowJet, envEnt, curTime, outVector, false)
    -- Returns a single number (blended windspeed in MPH).
    -- Wind direction is written into gsOutVector.
    local ok, windspeedMPH = pcall(
        GSGetGlobalWindspeedAndVectors,
        pos, entityList, inflowJet, envEnt, CurTime(), gsOutVector, false
    )
    if not ok or not IsFiniteNumber(windspeedMPH) then return nil, nil end
    if windspeedMPH <= 0 then return nil, nil end

    local _, direction = NormaliseWindReturns(gsOutVector, windspeedMPH)
    if not direction then return nil, nil end

    return math.Clamp(windspeedMPH, 0, TIV.Config.WindMaxSimulated), direction
end

-- XTwisters 3 intentionally exposes global API functions. Other weather
-- addons have historically used some of the same generic names, so resolving
-- only `GetGlobalWindspeed` is load-order dependent. Prefer namespaced/new API
-- spellings, then use the legacy globals while an XT3 convar/API marker exists.
local function GetNamespacedXT3Function(name)
    for _, namespaceName in ipairs({ "XT3", "XTwisters3" }) do
        local namespace = rawget(_G, namespaceName)
        if istable(namespace) and isfunction(namespace[name]) then
            return namespace[name]
        end
    end

    local prefixed = rawget(_G, "XT3" .. name)
    if isfunction(prefixed) then return prefixed end
    return nil
end

local function LegacyXT3Function(name)
    local fn = rawget(_G, name)
    return isfunction(fn) and fn or nil
end

local function HasXT3Marker()
    return GetConVar("xtwisters3_updatetime") ~= nil
        or GetConVar("xtwisters3_antilag") ~= nil
        or isfunction(rawget(_G, "GetGlobalWindData"))
        or isfunction(rawget(_G, "GetTornadoWindspeed"))
        or GetNamespacedXT3Function("GetGlobalWindspeed") ~= nil
end

-- Build the expensive global windfield list once per TIV wind tick. Reusing
-- it avoids rescanning all tornado entities separately for every occupied
-- interceptor, whether the per-vortex or global sampler handles the request.
local function BuildXT3Context()
    local context = { detected = HasXT3Marker(), windData = nil }
    if not context.detected then return context end

    local getData = GetNamespacedXT3Function("GetGlobalWindData")
        or LegacyXT3Function("GetGlobalWindData")
    if isfunction(getData) then
        local ok, windData = pcall(getData)
        if ok and istable(windData) then
            context.windData = windData
        end
    end

    return context
end

local function GetXT3GlobalSampler()
    local namespaced = GetNamespacedXT3Function("GetGlobalWindspeed")
    if namespaced then return namespaced end
    if not HasXT3Marker() then return nil end
    return LegacyXT3Function("GetGlobalWindspeed")
end

local function GetXT3TornadoSampler()
    return GetNamespacedXT3Function("GetTornadoWindspeed")
        or LegacyXT3Function("GetTornadoWindspeed")
end

-- Sample each valid XT3 vortex independently. This avoids the load-order
-- collision around XT3's generic `GetGlobalWindspeed` name and keeps one bad
-- third-party API tornado from disabling readings from every other vortex.
local function SampleXT3TornadoesDirectly(pos, context)
    local sampleTornado = GetXT3TornadoSampler()
    if not isfunction(sampleTornado) then return nil, nil end

    local strongestSpeed, strongestDirection = nil, nil
    local windfields = context and context.windData and context.windData[1]

    if istable(windfields) then
        for _, windfield in ipairs(windfields) do
            local ok, velocity, speed = pcall(sampleTornado, false, pos, windfield)
            if ok then
                local mph, direction = NormaliseWindReturns(velocity, speed)
                if mph and (not strongestSpeed or mph > strongestSpeed) then
                    strongestSpeed, strongestDirection = mph, direction
                end
            end
        end
    else
        -- Current XT3 and its API examples use xt3_tornadoes_* classes. Keep
        -- failures isolated so a malformed third-party vortex cannot disable
        -- wind readings from all other tornadoes.
        for _, tornado in ipairs(ents.FindByClass("xt3_tornadoes*")) do
            if IsValid(tornado) then
                local ok, velocity, speed = pcall(sampleTornado, tornado, pos)
                if ok then
                    local mph, direction = NormaliseWindReturns(velocity, speed)
                    if mph and (not strongestSpeed or mph > strongestSpeed) then
                        strongestSpeed, strongestDirection = mph, direction
                    end
                end
            end
        end
    end

    return strongestSpeed, strongestDirection
end

local function SampleXT3WindAt(pos, context)
    context = context or BuildXT3Context()
    if not context.detected then return nil, nil end

    -- The per-vortex function has an XT3-specific name and is therefore much
    -- less likely to be replaced by another weather addon. Prefer it whenever
    -- available, using the global API only as a compatibility fallback.
    local mph, direction = SampleXT3TornadoesDirectly(pos, context)
    if mph ~= nil then return mph, direction end

    local globalSampler = GetXT3GlobalSampler()
    if isfunction(globalSampler) then
        local ok, first, second = pcall(globalSampler, pos, context.windData)
        if ok then
            return NormaliseWindReturns(first, second)
        end
    end

    return nil, nil
end

-- ============================================================================
-- XTWISTERS 2 (XT2) COMPATIBILITY ENGINE
-- Integrates directly with XTwisters 2 base vortex physics, windfields,
-- storm entities, and translational path velocity.
-- ============================================================================
local function HasXT2Marker()
    return GetConVar("xt2_tornadochance") ~= nil
        or GetConVar("xt2_antilag") ~= nil
        or GetConVar("xt2_tlifetime") ~= nil
        or scripted_ents.GetStored("xtwisters2base") ~= nil
        or scripted_ents.GetStored("xt2_tornadoes_dynamic") ~= nil
end

local function SampleXT2WindAt(pos)
    if not HasXT2Marker() then return nil, nil end

    local strongestSpeed, strongestDirection = nil, nil
    local seen = {}

    -- 1. Check XT2 active tornadoes (derived from xtwisters2base, xt2_tornadoes_*, smallnado)
    local candidateClasses = {
        "xt2_tornadoes_*",
        "xt2_autospawn_tornado*",
        "xt2_autospawn_whirlwinds_*",
        "xt2_whirlwinds_*",
        "smallnado",
        "xtwisters2base",
    }

    for _, pattern in ipairs(candidateClasses) do
        for _, ent in ipairs(ents.FindByClass(pattern)) do
            if IsValid(ent) and not seen[ent] then
                seen[ent] = true
                local tPos = ent:GetPos()
                local dist2D = Vector(pos.x - tPos.x, pos.y - tPos.y, 0):Length()
                local vRange = ent.range or 3500
                local vForce = ent.Force or 100

                -- XTwisters 2 wind scaling formula:
                -- fraction = (1.0 - ((dist / v_range)^(1/2))) + 0.25
                if dist2D < (vRange * 1.5) then
                    local normDist = math.Clamp(dist2D / math.max(vRange, 500), 0, 1.5)
                    local fraction = math.Clamp((1.0 - math.sqrt(normDist)) + 0.25, 0.05, 1.35)
                    local mph = math.max(0, vForce * fraction)

                    -- Account for sub-vortices or RFD simulation if enabled in XT2
                    if ent.Subvorts and ent.xt2ForceListTotal and isnumber(ent.xt2ForceListTotal[2]) then
                        mph = math.max(mph, ent.xt2ForceListTotal[2])
                    end
                    if ent.RearFlankDowndraftWindspeeds and ent.RearFlankDowndraftWindspeeds > 0 then
                        mph = math.max(mph, ent.RearFlankDowndraftWindspeeds)
                    end

                    -- Calculate 2D cyclonic rotational wind vector + inward inflow pull
                    local toCenter = (tPos - pos):GetNormalized()
                    toCenter.z = 0
                    local rotSign = (ent.rotforce and ent.rotforce < 0) and -1 or 1
                    local tangential = Vector(-toCenter.y * rotSign, toCenter.x * rotSign, 0)
                    local inflowMult = ent.inflowmult or 1.0

                    -- Blend cyclonic tangential vector (65%) with radial inward pull (35%)
                    local windVec = (tangential * 0.65 + toCenter * (0.35 * inflowMult)):GetNormalized()

                    if not strongestSpeed or mph > strongestSpeed then
                        strongestSpeed = mph
                        strongestDirection = windVec
                    end
                end
            end
        end
    end

    -- 2. Check XT2 weather entities (straight-line winds, rainstorms, derechos)
    local weatherClasses = {
        "xt2_weather_*",
        "xt2_autospawn_thunderstorm_*",
        "xt2_autospawn_rainstorm_*",
        "xtwisters2weatherbase",
    }

    for _, pattern in ipairs(weatherClasses) do
        for _, ent in ipairs(ents.FindByClass(pattern)) do
            if IsValid(ent) and not seen[ent] then
                seen[ent] = true
                if ent.IsWindy and ent.Force and ent.Force > 0 then
                    local wMPH = ent.Force
                    local wDir = ent.WindDir or Vector(0, 1, 0)
                    if not strongestSpeed or wMPH > strongestSpeed then
                        strongestSpeed = wMPH
                        strongestDirection = wDir
                    end
                end
            end
        end
    end

    return strongestSpeed, strongestDirection
end

-- Pick the strongest provider among GStorms, XTwisters 3, and XTwisters 2.
local function SampleWorldWindAt(pos, xt3Context)
    local gsMPH, gsDirection   = SampleGStormsTornadoWindAt(pos)
    local xt3MPH, xt3Direction = SampleXT3WindAt(pos, xt3Context)
    local xt2MPH, xt2Direction = SampleXT2WindAt(pos)

    local bestMPH, bestDir, bestProvider = nil, nil, nil

    if gsMPH ~= nil then
        bestMPH, bestDir, bestProvider = gsMPH, gsDirection, "GStorms"
    end

    if xt3MPH ~= nil and (bestMPH == nil or xt3MPH > bestMPH) then
        bestMPH, bestDir, bestProvider = xt3MPH, xt3Direction, "XTwisters 3"
    end

    if xt2MPH ~= nil and (bestMPH == nil or xt2MPH > bestMPH) then
        bestMPH, bestDir, bestProvider = xt2MPH, xt2Direction, "XTwisters 2"
    end

    return bestMPH, bestDir, bestProvider
end

TIV.Wind.BuildXT3Context          = BuildXT3Context
TIV.Wind.SampleXT3WindAt          = SampleXT3WindAt
TIV.Wind.HasXT2Marker             = HasXT2Marker
TIV.Wind.SampleXT2WindAt          = SampleXT2WindAt
TIV.Wind.SampleWorldWindAt        = SampleWorldWindAt

-- ============================================================================
-- FORWARD TRAJECTORY PREDICTION ENGINE
-- Accurately calculates where the tornado will travel into the future by simulating
-- mod physics (GStorms noise & edge bias, XT3 deviation & wall reflection,
-- turning momentum, and terrain elevation tracking) instead of drawing a straight line.
-- ============================================================================
function TIV.Wind.CalculateTornadoFuturePath(bestEnt, tPos, heading, speedUnits, speedMPH, coreRadius, outerRadius, vehiclePos)
    local waypoints = {}
    local now = CurTime()

    -- 1. If GStorms PathingData spline nodes are active, trace along the actual spline graph
    if bestEnt.PathingData and istable(bestEnt.PathingData.edgePoints) and #bestEnt.PathingData.edgePoints > 0 then
        local edgePoints = bestEnt.PathingData.edgePoints
        local startIdx = bestEnt.PathingData.edgePointIndex or 1
        local cumDist = 0
        local lastPt = Vector(tPos.x, tPos.y, tPos.z)

        for i = startIdx, #edgePoints do
            local pt = edgePoints[i]
            if pt then
                local ptPos = Vector(pt.x, pt.y, pt.z or tPos.z)
                cumDist = cumDist + (ptPos - lastPt):Length2D()
                lastPt = ptPos
                local estTime = math.Round(cumDist / math.max(speedUnits, 100), 1)
                table.insert(waypoints, {
                    time = estTime,
                    pos  = ptPos,
                })
                if #waypoints >= 16 then break end
            end
        end

        if #waypoints >= 4 then
            return waypoints
        end
    end

    -- 2. Dynamic Physics & Environmental Simulation
    -- Simulates the tornado's forward path taking into account turning momentum,
    -- mod-specific wandering algorithms, map boundary repulsion, and obstacle reflection.
    local simPos   = Vector(tPos.x, tPos.y, tPos.z)
    local simDir   = Vector(heading.x, heading.y, 0):GetNormalized()
    local turnRate = bestEnt._TIV_TurnRate or 0 -- degrees per second

    local isXT2     = (bestEnt.Base == "xtwisters2base" or bestEnt.dir ~= nil or bestEnt.Tornadic == true or string.find(string.lower(bestEnt:GetClass() or ""), "xt2", 1, true) ~= nil)
    local isXT3     = (bestEnt.MovementDirection ~= nil)
    local isGStorms = (bestEnt.MovementVector ~= nil)

    local w = game.GetWorld()
    local wMins, wMaxs
    if IsValid(w) then
        wMins, wMaxs = w:GetModelBounds()
    else
        wMins, wMaxs = Vector(-15000, -15000, -1000), Vector(15000, 15000, 1000)
    end
    local wCenter = (wMins + wMaxs) * 0.5
    wCenter.z = 0

    local totalSimTime = 60
    local dt = 0.5
    local steps = math.floor(totalSimTime / dt)

    local sampleInterval = 3.5 -- Record a waypoint every 3.5 seconds
    local nextSampleTime = 3.5

    for s = 1, steps do
        local t = s * dt

        -- A. Angular Momentum / Turning Extrapolation with natural turbulent decay
        local currentTurn = turnRate * math.exp(-t * 0.05)
        if math.abs(currentTurn) > 0.05 then
            local rotAngle = math.rad(currentTurn * dt)
            local cosA, sinA = math.cos(rotAngle), math.sin(rotAngle)
            local nx = simDir.x * cosA - simDir.y * sinA
            local ny = simDir.x * sinA + simDir.y * cosA
            simDir = Vector(nx, ny, 0):GetNormalized()
        end

        -- B. Mod-specific wandering algorithms
        if isGStorms and _G.GSNoise then
            local _, sinX, sinY = _G.GSNoise(simPos.x, simPos.y, simDir.x, simDir.y, 0, 0, 0, 7500, 30000, -45, 45, 1, now + t)
            local gNoise = Vector(sinX, sinY, 0) * (0.000375 * speedMPH * dt * 25)
            simDir = (simDir + gNoise):GetNormalized()
        elseif isXT3 then
            if _G.perlinNoise3D then
                local NoiseSize = 300
                local simT = now + t
                local devTime = simT / Lerp((_G.perlinNoise3D(simPos.x / NoiseSize, simT, simPos.y / NoiseSize) or 0) + 0.5, 3, 30)
                local devOffset = Vector(math.cos(devTime), math.sin(devTime), 0) * (0.035 * dt * 15)
                simDir = (simDir + devOffset):GetNormalized()
            end
            if IsValid(bestEnt.SmartTarget) then
                local stPos = bestEnt.SmartTarget:GetPos()
                local smartDir = Vector(stPos.x - simPos.x, stPos.y - simPos.y, 0):GetNormalized()
                simDir = LerpVector(0.002 * dt * 20, simDir, smartDir):GetNormalized()
            end
        elseif isXT2 then
            -- XT2 dynamic target attraction and turbulence perturbation
            if bestEnt.trnt and isvector(bestEnt.trnt) then
                local toTarget = Vector(bestEnt.trnt.x - simPos.x, bestEnt.trnt.y - simPos.y, 0):GetNormalized()
                simDir = LerpVector(math.Clamp(0.015 * dt * 10, 0, 1), simDir, toTarget):GetNormalized()
            else
                local devOffset = Vector(math.sin(now + t * 0.7), math.cos(now + t * 0.7), 0) * (0.02 * dt * 10)
                simDir = (simDir + devOffset):GetNormalized()
            end
        end

        -- C. Map Edge Repulsion (Prevents path from projecting off the playable map)
        local edgeDistX = math.min(simPos.x - wMins.x, wMaxs.x - simPos.x)
        local edgeDistY = math.min(simPos.y - wMins.y, wMaxs.y - simPos.y)
        local minEdgeDist = math.min(edgeDistX, edgeDistY)
        if minEdgeDist < 2500 then
            local edgeFactor = math.Clamp((2500 - minEdgeDist) / 2500, 0, 1) ^ 2
            local toCenter = (wCenter - simPos):GetNormalized()
            toCenter.z = 0
            simDir = LerpVector(edgeFactor * 0.35, simDir, toCenter):GetNormalized()
        end

        -- D. Obstacle / Cliff / Wall Deflection (TraceLine check ahead)
        local checkDist = math.max(speedUnits * dt * 1.5, coreRadius * 0.65, 350)
        local wallTr = util.TraceLine({
            start = simPos + Vector(0, 0, 250),
            endpos = simPos + Vector(0, 0, 250) + simDir * checkDist,
            mask = MASK_SOLID_BRUSHONLY,
        })
        if wallTr.Hit and not wallTr.StartSolid then
            local hitNorm = Vector(wallTr.HitNormal.x, wallTr.HitNormal.y, 0):GetNormalized()
            if hitNorm:LengthSqr() > 0.05 then
                simDir = (simDir - 2 * simDir:Dot(hitNorm) * hitNorm):GetNormalized()
                simDir.z = 0
                simDir:Normalize()
            end
        end

        -- E. Terrain Elevation Tracking
        local groundTr = util.TraceLine({
            start = simPos + Vector(0, 0, 600),
            endpos = simPos - Vector(0, 0, 3000),
            mask = MASK_SOLID_BRUSHONLY,
        })
        if groundTr.Hit then
            simPos.z = groundTr.HitPos.z
        end

        -- F. Advance Position
        simPos = simPos + simDir * (speedUnits * dt)

        -- G. Sample Waypoint
        if t >= nextSampleTime then
            table.insert(waypoints, {
                time = math.Round(t),
                pos  = Vector(simPos.x, simPos.y, simPos.z),
            })
            nextSampleTime = nextSampleTime + sampleInterval
            if #waypoints >= 16 then break end
        end
    end

    return waypoints
end

-- ============================================================================
-- CIRCULATION & GROUND-CONTACT COMPATIBILITY LAYER
--
-- The radar paints a Doppler velocity signature only while a vortex is actually
-- on the ground, and colours its two lobes by the direction the vortex really
-- turns. Both facts are addon-specific, and no addon exposes them under the same
-- name, so they are read here once instead of being guessed in the client
-- renderer.
--
-- Nothing in this section invents a state. Every branch returns nil when the
-- addon does not publish the value, and the callers treat nil as "unknown" --
-- unknown ground contact means the signature is not drawn, and unknown rotation
-- direction means it is drawn in a neutral colour that claims no direction.
-- ============================================================================

TIV.Wind.ROTATION_UNKNOWN = 0
TIV.Wind.ROTATION_CYCLONIC = 1        -- Northern-hemisphere default: counter-clockwise
TIV.Wind.ROTATION_ANTICYCLONIC = -1   -- the reverse circulation

-- Reads a field that an addon may expose either as a plain value or through a
-- networked accessor. Returns the value, or nil when it is absent or unusable.
local function ReadAddonValue(ent, field, getter)
    if not ent then return nil end
    local direct = ent[field]
    if direct ~= nil then return direct end
    if getter and ent[getter] then
        local ok, value = pcall(ent[getter], ent)
        if ok and value ~= nil then return value end
    end
    return nil
end

-- Returns v only when it is a finite number above zero, otherwise nil, so that
-- the `or` chains below never settle on a zero-valued or NaN placeholder.
local function PositiveNumber(v)
    if isnumber(v) and IsFiniteNumber(v) and v > 0 then return v end
    return nil
end

-- Coerces an addon flag into a boolean. Returns nil rather than false when the
-- value is absent or of an unexpected type, so "addon says cyclonic" stays
-- distinguishable from "addon said nothing".
local function ToTriStateBool(v)
    if v == true then return true end
    if v == false then return false end
    if isnumber(v) then
        if v ~= 0 then return true end
        return false
    end
    if isstring(v) then
        local s = string.lower(v)
        if s == "true" or s == "1" then return true end
        if s == "false" or s == "0" then return false end
    end
    return nil
end

-- ----------------------------------------------------------------------------
-- ROTATION DIRECTION
--
-- GStorms publishes `Anticyclonic` and derives its own spin from it as
-- `spinDir = anticyclonic and -1 or 1` (gstorms_subvortex.lua:127). XT3 publishes
-- `AntiCyclonic` on every vortex class, XT2 publishes `IsAnticyclonic` on
-- xtwisters2base. A boolean from any of those is taken at face value.
-- ----------------------------------------------------------------------------
function TIV.Wind.GetTornadoRotationDirection(ent)
    if not ent then return TIV.Wind.ROTATION_UNKNOWN end

    local anti = ToTriStateBool(ReadAddonValue(ent, "Anticyclonic", "GetAnticyclonic"))
    if anti == nil then anti = ToTriStateBool(ReadAddonValue(ent, "AntiCyclonic", "GetAntiCyclonic")) end
    if anti == nil then anti = ToTriStateBool(ReadAddonValue(ent, "IsAnticyclonic", "GetIsAnticyclonic")) end

    if anti ~= nil then
        return anti and TIV.Wind.ROTATION_ANTICYCLONIC or TIV.Wind.ROTATION_CYCLONIC
    end

    -- XT2's EF variants do not always set the boolean: an anticyclonic EF0 only
    -- flips `rotforce` from -54 to +54 (xt2_tornadoes_ef-0.lua:39-40), while every
    -- cyclonic class ships a negative rotforce. The sign is a real property of
    -- the spawned vortex, so it is a legitimate fallback -- but only as a sign.
    local rotforce = ReadAddonValue(ent, "rotforce")
    if isnumber(rotforce) and IsFiniteNumber(rotforce) and rotforce ~= 0 then
        return rotforce > 0 and TIV.Wind.ROTATION_ANTICYCLONIC or TIV.Wind.ROTATION_CYCLONIC
    end

    return TIV.Wind.ROTATION_UNKNOWN
end

-- ----------------------------------------------------------------------------
-- ROTATION STRENGTH
--
-- Tangential wind in MPH, used only to pace the signature's pulse. Absent or
-- non-positive values yield nil, and the renderer falls back to the translation
-- speed it already has rather than inventing a number here.
-- ----------------------------------------------------------------------------
function TIV.Wind.GetTornadoRotationSpeed(ent)
    if not ent then return nil end
    local mph = ReadAddonValue(ent, "VortexWindspeed", "GetVortexWindspeed")
        or ReadAddonValue(ent, "MaxWinds", "GetMaxWinds")
        or ReadAddonValue(ent, "Force", "GetForce")
    return PositiveNumber(mph)
end

-- ----------------------------------------------------------------------------
-- GROUND CONTACT
--
-- Returns true when the vortex is measured to be on the ground, false when it is
-- measured to be clear of it, and nil when it cannot be measured. It never
-- returns true merely because a tornado happens to exist.
-- ----------------------------------------------------------------------------
local GROUND_CONTACT_GAP = 512 -- Source units of clearance that still count as "on the ground"

function TIV.Wind.GetTornadoGroundContact(ent)
    if not IsValid(ent) then return nil end

    -- GStorms tracks the funnel's bottom height above the vortex origin. It is
    -- set to FunnelMaxHeight while the funnel is fully aloft and lerped toward
    -- the configured start height -- 0 by default -- as the tornado touches down,
    -- then back up again as it lifts (gstorms_dynamic_entity_handler.lua:205,218,
    -- 260). Only that addon can be aloft at all, so its own state decides.
    local startH = ReadAddonValue(ent, "FunnelStartHeight", "GetFunnelStartHeight")
    local maxH = ReadAddonValue(ent, "FunnelMaxHeight", "GetFunnelMaxHeight")
    startH = (isnumber(startH) and IsFiniteNumber(startH)) and startH or nil
    maxH = PositiveNumber(maxH)

    if startH ~= nil or maxH ~= nil then
        if startH ~= nil and startH <= 0 then return true end
        if maxH ~= nil and startH ~= nil then
            -- A funnel still at (or above) its ceiling is entirely off the ground,
            -- as is one configured to stop short of it.
            if startH >= maxH or startH > GROUND_CONTACT_GAP then return false end
            return true
        end
        -- Only one of the two is published, so the funnel height alone cannot
        -- settle it; fall through to the measurement below.
    end

    -- XT2 and XT3 anchor the vortex at the ground -- XT3 sets the entity to a
    -- downward trace on spawn and keeps it there through MovementHeightGoal
    -- (xtwisters3vortexbase.lua:76-85, 140-149) -- and neither publishes an aloft
    -- state, so measure the gap directly. The trace failing or running short is
    -- reported as unknown rather than as an answer.
    if not ent.GetPos then return nil end

    local origin = ent:GetPos()
    if not IsUsableVector(origin) then return nil end

    local tr = util.TraceLine({
        start  = origin + Vector(0, 0, 64),
        endpos = origin - Vector(0, 0, 16384),
        mask   = MASK_SOLID_BRUSHONLY + MASK_WATER,
        filter = ent,
    })
    if not tr or not tr.Hit or not IsUsableVector(tr.HitPos) then return nil end

    return (origin.z - tr.HitPos.z) <= GROUND_CONTACT_GAP
end

-- Bundles the three values the radar needs. Anything the addons do not publish
-- arrives as nil / 0, and the renderer suppresses the signature rather than
-- filling the gap with an assumption.
function TIV.Wind.GetTornadoCirculationReport(ent)
    if not IsValid(ent) then
        return {
            touchingGround = false,
            rotationDirection = TIV.Wind.ROTATION_UNKNOWN,
            rotationSpeed = 0,
        }
    end

    local contact = TIV.Wind.GetTornadoGroundContact(ent)
    local rotSpeed = TIV.Wind.GetTornadoRotationSpeed(ent)

    return {
        -- nil is deliberately collapsed to false here: the client renders one
        -- boolean, and "cannot be determined" must not draw a signature.
        touchingGround = contact == true,
        rotationDirection = TIV.Wind.GetTornadoRotationDirection(ent),
        rotationSpeed = rotSpeed or 0,
    }
end

-- ============================================================================
-- ACTIVE TORNADO TRACKING & PATH PREDICTION (GSTORMS, XT2, & XTWISTERS 3)
-- Locates the active tornado entity to evaluate real-time core/side interception
-- and generate forward trajectory path prediction waypoints.
-- ============================================================================
function TIV.Wind.GetNearestActiveTornado(pos, maxDist)
    maxDist = maxDist or 45000
    local maxDistSqr = maxDist * maxDist
    local bestEnt = nil
    local bestDistSqr = maxDistSqr

    local candidates = {}
    local seen = {}

    local function addCandidate(e)
        if IsValid(e) and not seen[e] then
            seen[e] = true
            table.insert(candidates, e)
        end
    end

    -- XT2 tornado entities
    for _, e in ipairs(ents.FindByClass("xt2_tornadoes_*")) do addCandidate(e) end
    for _, e in ipairs(ents.FindByClass("xt2_autospawn_tornado*")) do addCandidate(e) end
    for _, e in ipairs(ents.FindByClass("xt2_autospawn_whirlwinds_*")) do addCandidate(e) end
    for _, e in ipairs(ents.FindByClass("xt2_whirlwinds_*")) do addCandidate(e) end
    for _, e in ipairs(ents.FindByClass("smallnado")) do addCandidate(e) end
    for _, e in ipairs(ents.FindByClass("xtwisters2base")) do addCandidate(e) end

    -- XT3 tornado entities
    for _, e in ipairs(ents.FindByClass("xt3_tornadoes*")) do addCandidate(e) end
    for _, e in ipairs(ents.FindByClass("xtwisters3vortexbase")) do addCandidate(e) end

    -- GStorms weather entities
    for _, e in ipairs(ents.FindByClass("gstorms_weather_*")) do addCandidate(e) end
    for _, e in ipairs(ents.FindByClass("gstorms_base_entity")) do addCandidate(e) end
    if gs_weatherEntityList and gs_weatherEntityList.server then
        for _, e in pairs(gs_weatherEntityList.server) do
            if isentity(e) then addCandidate(e) end
        end
    end

    for _, ent in ipairs(candidates) do
        local cls = string.lower(ent:GetClass() or "")
        local isExcluded = string.find(cls, "earthquake", 1, true)
            or string.find(cls, "probe", 1, true)
            or string.find(cls, "seismograph", 1, true)
            or string.find(cls, "thermometer", 1, true)
            or string.find(cls, "computer", 1, true)
            or string.find(cls, "siren", 1, true)
            or string.find(cls, "volcano", 1, true)
            or string.find(cls, "anemometer", 1, true)
            or string.find(cls, "barometer", 1, true)

        local isVortex = false
        if not isExcluded then
            if string.find(cls, "xt3_tornadoes", 1, true)
                or string.find(cls, "xtwisters3vortexbase", 1, true)
                or string.find(cls, "xt2_tornadoes", 1, true)
                or string.find(cls, "xt2_autospawn_tornado", 1, true)
                or string.find(cls, "xt2_autospawn_whirlwind", 1, true)
                or string.find(cls, "xt2_whirlwind", 1, true)
                or string.find(cls, "xtwisters2base", 1, true)
                or cls == "smallnado"
                or string.find(cls, "gstorms_weather_ef", 1, true)
                or string.find(cls, "gstorms_weather_spout", 1, true)
                or string.find(cls, "gstorms_weather_dust_devil", 1, true)
                or string.find(cls, "gstorms_weather_hurricane", 1, true)
                or ent.VortexWindspeed ~= nil
                or ent.VortexCoreSize ~= nil
                or ent.Tornado == true
                or (ent.GetTornado and ent:GetTornado() == true)
                or ent.IsXT3Vortex == true or ent.IsVortex == true
                or ent.Tornadic == true or ent.isTornado == true then
                isVortex = true
            end
        end

        if isVortex then
            local tPos = ent:GetPos()
            local dSqr = Vector(pos.x - tPos.x, pos.y - tPos.y, 0):LengthSqr()
            if dSqr < bestDistSqr then
                bestDistSqr = dSqr
                bestEnt = ent
            end
        end
    end

    if not IsValid(bestEnt) then return nil end

    local tPos = bestEnt:GetPos()
    local now = CurTime()
    local dist2D = math.sqrt(bestDistSqr)

    -- Universal track smoothing for translation vector and angular turning rate
    if not bestEnt._TIV_LastPos then
        bestEnt._TIV_LastPos    = tPos
        bestEnt._TIV_LastTime   = now
        bestEnt._TIV_TrackDir   = Vector(1, 0, 0)
        bestEnt._TIV_TrackSpeed = 25
        bestEnt._TIV_TurnRate   = 0
    else
        local dt = now - bestEnt._TIV_LastTime
        if dt >= 0.20 then
            local dPos = tPos - bestEnt._TIV_LastPos
            local dLen = dPos:Length2D()
            if dLen > 1.5 then
                local newDir = Vector(dPos.x, dPos.y, 0):GetNormalized()
                local oldDir = bestEnt._TIV_TrackDir or newDir

                -- Compute 2D signed cross product to find turning direction and rate
                local crossZ = oldDir.x * newDir.y - oldDir.y * newDir.x
                local dot = math.Clamp(oldDir:Dot(newDir), -1, 1)
                local angleDeltaDeg = math.deg(math.atan2(crossZ, dot))
                local instantTurnRate = angleDeltaDeg / dt -- degrees per second

                -- Smooth with exponential moving average
                bestEnt._TIV_TurnRate   = Lerp(0.35, bestEnt._TIV_TurnRate or 0, math.Clamp(instantTurnRate, -45, 45))
                bestEnt._TIV_TrackDir   = newDir
                bestEnt._TIV_TrackSpeed = math.Clamp((dLen / dt) * 0.0568182, 5, 120)
            end
            bestEnt._TIV_LastPos  = tPos
            bestEnt._TIV_LastTime = now
        end
    end

    -- Direction derivation
    local rawDir = (bestEnt.dir and isvector(bestEnt.dir) and bestEnt.dir)
        or bestEnt.MovementDirection or bestEnt.MovementVector
        or (bestEnt:GetVelocity():Length2D() > 15 and bestEnt:GetVelocity():GetNormalized())
        or bestEnt._TIV_TrackDir or Vector(1, 0, 0)
    local heading = Vector(rawDir.x, rawDir.y, 0):GetNormalized()
    if heading:LengthSqr() < 0.01 then heading = Vector(1, 0, 0) end

    -- Speed derivation (MPH & hammer units/sec)
    local speedMPH = bestEnt._TIV_TrackSpeed or 25
    if bestEnt.MovementSpeed and bestEnt.MovementSpeed > 0 then
        speedMPH = bestEnt.MovementSpeed * 2.23694
    elseif bestEnt.Speed and isnumber(bestEnt.Speed) and bestEnt.Speed > 0 and (bestEnt.Base == "xtwisters2base" or string.find(string.lower(bestEnt:GetClass() or ""), "xt2", 1, true)) then
        speedMPH = math.Clamp(bestEnt.Speed * 0.0568182 * 30, 8, 90)
    elseif bestEnt:GetVelocity():Length2D() > 15 then
        speedMPH = bestEnt:GetVelocity():Length() * 0.0568182
    end
    speedMPH = math.Clamp(speedMPH, 8, 90)
    local speedUnits = speedMPH / 0.0568182

    -- Core radius (RMW / maximum wind zone)
    local coreRadius = (bestEnt.InnerFunnelDistance and isnumber(bestEnt.InnerFunnelDistance) and bestEnt.InnerFunnelDistance > 0 and bestEnt.InnerFunnelDistance)
        or bestEnt.VortexRMWSize
        or (bestEnt.GetNW2Float and bestEnt:GetNW2Float("VortexRMWSize", 0) > 0 and bestEnt:GetNW2Float("VortexRMWSize"))
        or bestEnt.VortexCoreSize
        or (bestEnt.GetNW2Float and bestEnt:GetNW2Float("VortexCoreSize", 0) > 0 and bestEnt:GetNW2Float("VortexCoreSize"))
        or (bestEnt.range and isnumber(bestEnt.range) and (bestEnt.range * 0.25))
        or 600

    -- Outer vortex radius
    local outerRadius = (bestEnt.range and isnumber(bestEnt.range) and bestEnt.range > 0 and bestEnt.range)
        or bestEnt.VortexSize
        or (bestEnt.GetVortexSize and bestEnt:GetVortexSize())
        or (bestEnt.GetNW2Float and bestEnt:GetNW2Float("VortexSize", 0) > 0 and bestEnt:GetNW2Float("VortexSize"))
        or (coreRadius * 4.5)
        or 3500

    -- ========================================================================
    -- ACTUAL FORWARD PATH CALCULATION
    -- Simulates the tornado's true trajectory taking into account turning momentum,
    -- mod physics (GStorms noise, XT3 deviation, smart targets), map bounds, and obstacle deflection.
    -- ========================================================================
    local waypoints = TIV.Wind.CalculateTornadoFuturePath(bestEnt, tPos, heading, speedUnits, speedMPH, coreRadius, outerRadius, pos)

    -- Closest Point of Approach (CPA) evaluated along the actual calculated trajectory
    local cpaDist = dist2D
    local eta = 0
    local impactType = "receding"
    local closestDist = dist2D
    local closestTime = 0
    local foundCloser = false

    for _, wp in ipairs(waypoints) do
        local d = (Vector(wp.pos.x, wp.pos.y, 0) - Vector(pos.x, pos.y, 0)):Length2D()
        if d < closestDist then
            closestDist = d
            closestTime = wp.time or 0
            foundCloser = true
        end
    end

    if foundCloser then
        cpaDist = math.Round(closestDist, 1)
        eta = math.Round(closestTime, 1)

        if cpaDist <= coreRadius then
            impactType = "core"
        elseif cpaDist <= outerRadius then
            impactType = "side"
        elseif cpaDist <= (outerRadius * 2.2) then
            impactType = "miss"
        else
            impactType = "receding"
        end
    else
        -- Tornado is already closest right now or moving away
        if dist2D <= coreRadius then
            impactType = "core"
            eta = 0
        elseif dist2D <= outerRadius then
            impactType = "side"
            eta = 0
        else
            impactType = "receding"
            eta = 0
        end
    end

    local bearing = math.deg(math.atan2(tPos.y - pos.y, tPos.x - pos.x))
    if bearing < 0 then bearing = bearing + 360 end

    -- Ground contact and circulation are resolved by the compatibility layer, so
    -- the radar never has to reach into an addon's fields itself.
    local circulation = TIV.Wind.GetTornadoCirculationReport(bestEnt)

    return {
        ent         = bestEnt,
        pos         = tPos,
        heading     = heading,
        speedMPH    = speedMPH,
        speedUnits  = speedUnits,
        coreRadius  = coreRadius,
        outerRadius = outerRadius,
        dist        = dist2D,
        bearing     = bearing,
        eta         = math.Round(eta, 1),
        cpaDist     = math.Round(cpaDist, 1),
        impactType  = impactType,
        waypoints   = waypoints,
        touchingGround    = circulation.touchingGround,
        rotationDirection = circulation.rotationDirection,
        rotationSpeed     = circulation.rotationSpeed,
    }
end

-- ============================================================================
-- PUBLIC API
-- ============================================================================
local function ManualActive()
    if not TIV.Wind.ManualMode then return false end
    if TIV.Wind.ManualUntil > 0 and CurTime() > TIV.Wind.ManualUntil then
        TIV.Wind.ManualMode  = false
        TIV.Wind.ManualUntil = 0
        print("[TIV] Wind manual override auto-expired.")
        return false
    end
    return true
end

function TIV.Wind.GetSpeed(veh)
    if ManualActive() then return TIV.Wind.ManualMPH end
    if IsValid(veh) then
        local entry = TIV.Wind.PerVehicle[veh:EntIndex()]
        if entry then return entry.mph end
    end
    return TIV.Wind.CurrentMPH
end

function TIV.Wind.GetDirection(veh)
    if ManualActive() then return TIV.Wind.ManualDir end
    if IsValid(veh) then
        local entry = TIV.Wind.PerVehicle[veh:EntIndex()]
        if entry then return entry.dir end
    end
    return TIV.Wind.Direction
end

-- Returns an unscaled wind force vector. Callers multiply by mass and any
-- scenario-specific scalar.
function TIV.Wind.GetForceVector(veh)
    return TIV.Wind.GetDirection(veh) * TIV.Wind.GetSpeed(veh) * TIV.Wind.FORCE_PER_MPH_PER_KG
end

function TIV.Wind.SetSpeed(mph)
    TIV.Wind.ManualMode  = true
    TIV.Wind.ManualMPH   = math.Clamp(mph, 0, TIV.Config.WindMaxSimulated)
    TIV.Wind.ManualUntil = CurTime() + MANUAL_AUTO_EXPIRE
end

function TIV.Wind.SetDirection(dir)
    TIV.Wind.ManualMode  = true
    TIV.Wind.ManualDir   = dir:GetNormalized()
    TIV.Wind.ManualUntil = CurTime() + MANUAL_AUTO_EXPIRE
end

function TIV.Wind.ClearManual()
    TIV.Wind.ManualMode  = false
    TIV.Wind.ManualUntil = 0
end

-- Apply wind force to a single entity. `scale` defaults to 1.0; pass smaller
-- values (e.g., 0.5) for lighter coupling.
function TIV.Wind.ApplyToEntity(ent, scale, veh)
    if not IsValid(ent) then return end
    local phys = ent:GetPhysicsObject()
    if not IsValid(phys) then return end
    if not phys:IsMotionEnabled() then return end

    local force = TIV.Wind.GetForceVector(veh) * phys:GetMass() * (scale or 1.0)
    phys:ApplyForceCenter(force)
end

-- ============================================================================
-- WIND THINK
-- Per-vehicle sampling. Each vehicle has its own wind value.
-- ============================================================================
timer.Create("TIV_WindThink", 0.1, 0, function()
    -- XT3's global wind data scans every tornado. Cache it for this tick so
    -- multiple interceptors do not each repeat the same world scan.
    local xt3Context = BuildXT3Context()

    -- Build list of active TIV vehicles.
    local activeVehicles = {}
    local seenIdx = {}
    for entIdx, data in pairs(TIV.Deploy.Vehicles or {}) do
        local veh = Entity(entIdx)
        if IsValid(veh) then
            table.insert(activeVehicles, { veh = veh, data = data, idx = entIdx })
            seenIdx[entIdx] = true
        end
    end

    -- Prune per-vehicle cache for vehicles that no longer exist.
    for idx in pairs(TIV.Wind.PerVehicle) do
        if not seenIdx[idx] then
            TIV.Wind.PerVehicle[idx] = nil
        end
    end

    if not ManualActive() then
        if #activeVehicles > 0 then
            for _, entry in ipairs(activeVehicles) do
                local mph, dir, provider = SampleWorldWindAt(entry.veh:GetPos(), xt3Context)
                if mph ~= nil then
                    TIV.Wind.PerVehicle[entry.idx] = {
                        mph      = mph,
                        dir      = dir,
                        provider = provider,
                    }
                    -- Keep the global cache updated as the last-seen sample.
                    TIV.Wind.CurrentMPH = mph
                    TIV.Wind.Direction  = dir
                else
                    -- Every provider answered "no storm here" (a removed tornado
                    -- included). The previous sample must not survive that, or
                    -- the vehicle keeps getting shoved by wind that no longer exists.
                    TIV.Wind.PerVehicle[entry.idx] = nil
                end
            end
            if not next(TIV.Wind.PerVehicle) then
                TIV.Wind.CurrentMPH = TIV.Config.WindDefault or 0
            end
        else
            local ply = player.GetAll()[1]
            if IsValid(ply) then
                local mph, dir = SampleWorldWindAt(ply:GetPos(), xt3Context)
                if mph ~= nil then
                    TIV.Wind.CurrentMPH = mph
                    TIV.Wind.Direction  = dir
                else
                    TIV.Wind.CurrentMPH = TIV.Config.WindDefault or 0
                end
            end
        end
    end

    -- Apply forces only to TIV vehicles (when not solidly anchored) + released spikes (never all props).
    for _, entry in ipairs(activeVehicles) do
        local state = entry.data and entry.data.state or "idle"
        local isSolidAnchored = (state == "anchored" and not entry.data.gravityReleased)
            or (state == "lowering" or state == "deploying_spikes")
        local windMPH = TIV.Wind.GetSpeed(entry.veh)

        if not isSolidAnchored and windMPH >= 50 then
            TIV.Wind.ApplyToEntity(entry.veh, 0.01, entry.veh)
        end

        for _, sd in ipairs(entry.data.spikes or {}) do
            if IsValid(sd.entity) and sd.phase == "released" then
                -- Released spikes are loose debris: lighter wind coupling.
                TIV.Wind.ApplyToEntity(sd.entity, 0.5, entry.veh)
            end
        end
    end

    -- Auto-deploy safety feature on high wind threshold
    local autoDeployCVar = GetConVar("tiv_auto_deploy_wind")
    local autoDeployThreshold = autoDeployCVar and autoDeployCVar:GetFloat() or 0
    if autoDeployThreshold > 0 then
        for _, entry in ipairs(activeVehicles) do
            local veh = entry.veh
            local data = entry.data
            if data and data.state == "idle" then
                local wMPH = TIV.Wind.GetSpeed(veh)
                if wMPH >= autoDeployThreshold then
                    local speed = veh:GetVelocity():Length() * 0.0568182
                    if speed < 15 and TIV.Deploy and TIV.Deploy.Deploy then
                        TIV.Deploy.Deploy(veh, data)
                    end
                end
            end
        end
    end

    -- No TIV_WindUpdate broadcast: HUD gets wind via TIV_InstrumentData.
end)

-- ============================================================================
-- COMMANDS
-- ============================================================================
local function isAuth(ply)
    if not IsValid(ply) then return true end -- server console
    return ply:IsAdmin()
end

concommand.Add("tiv_wind_set", function(ply, cmd, args)
    if not isAuth(ply) then return end
    local speed = tonumber(args[1]) or 0
    TIV.Wind.SetSpeed(speed)
    print(string.format("[TIV] Wind manual override: %d MPH (auto-expires in %ds)",
        speed, MANUAL_AUTO_EXPIRE))
end)

concommand.Add("tiv_wind_dir", function(ply, cmd, args)
    if not isAuth(ply) then return end
    local x = tonumber(args[1]) or 1
    local y = tonumber(args[2]) or 0
    local z = tonumber(args[3]) or 0
    TIV.Wind.SetDirection(Vector(x, y, z))
    print(string.format("[TIV] Wind direction set to (%s, %s, %s)", x, y, z))
end)

concommand.Add("tiv_wind_clear", function(ply, cmd, args)
    if not isAuth(ply) then return end
    TIV.Wind.ClearManual()
    print("[TIV] Wind manual override cleared.")
end)

concommand.Add("tiv_wind_status", function(ply, cmd, args)
    if not isAuth(ply) then return end
    local manual = ManualActive()
    local remaining = (TIV.Wind.ManualUntil > 0)
        and math.max(0, math.floor(TIV.Wind.ManualUntil - CurTime())) or 0

    print(string.format(
        "[TIV] Wind: %.1f MPH | Dir: %s | Mode: %s%s | GStorms: %s | XT2: %s | XT3: %s",
        TIV.Wind.CurrentMPH,
        tostring(TIV.Wind.Direction),
        manual and "MANUAL" or "AUTO",
        manual and string.format(" (%ds left)", remaining) or "",
        isfunction(GSGetGlobalWindspeedAndVectors) and "YES" or "NO",
        HasXT2Marker() and "YES" or "NO",
        HasXT3Marker() and "YES" or "NO"
    ))

    for idx, entry in pairs(TIV.Wind.PerVehicle) do
        print(string.format("  Vehicle #%d: %.1f MPH dir=%s provider=%s",
            idx, entry.mph, tostring(entry.dir), entry.provider or "unknown"))
    end
end)

print("[TIV] Wind system loaded (per-vehicle sampling, GStorms + XTwisters 3)")
