-- ============================================================================
-- TIV SPIKE ANIMATION (server)
-- ============================================================================
-- Spikes are the visible pistons of the hydraulic rams. While a ram strokes,
-- its spike is a parented, non-solid prop moving along the ram axis in the
-- vehicle's local frame -- exactly what a piston bolted to the chassis does.
-- The moment a spike reaches drive depth it is unparented and planted as a
-- static body (TIV.Anchor.PlantSingle); from then on the chassis is held by
-- real constraints and the physics engine, never by SetPos.
--
-- One generic stroke job drives deploy, retract and both mid-stroke
-- reversals, so interrupting a sequence just starts a new stroke from
-- wherever the piston currently is.
-- ============================================================================

TIV.SpikeAnim = TIV.SpikeAnim or {}

util.AddNetworkString("TIV_SpikeAnimStart")
util.AddNetworkString("TIV_SpikeAnimRetract")
util.AddNetworkString("TIV_SpikeAnimImpact")
util.AddNetworkString("TIV_SpikeAnimPhase")

TIV.SpikeAnim.ActiveJobs      = TIV.SpikeAnim.ActiveJobs or {}
TIV.SpikeAnim._sessionCounter = TIV.SpikeAnim._sessionCounter or 0

local SPIKE_MODEL_FALLBACK = "models/props_junk/harpoon002a.mdl"

-- ============================================================================
-- JOB TICKER
-- ============================================================================
timer.Create("TIV_SpikeAnimThink", 0.02, 0, function()
    for key, job in pairs(TIV.SpikeAnim.ActiveJobs) do
        if job.fn(job) == false then
            TIV.SpikeAnim.ActiveJobs[key] = nil
        end
    end
end)

local function CancelVehicleJobs(sessionID)
    if not sessionID then return end
    local prefix = sessionID .. "_"
    for key in pairs(TIV.SpikeAnim.ActiveJobs) do
        if string.sub(key, 1, #prefix) == prefix then
            TIV.SpikeAnim.ActiveJobs[key] = nil
        end
    end
end
TIV.SpikeAnim.CancelVehicleJobs = CancelVehicleJobs

-- ============================================================================
-- ORIENTATION HELPERS
-- ============================================================================
local function GetParentedLocalAngle()
    return Angle(90, 0, 0)
end

local function GetSpikeDownAngle(veh, localAng)
    if not IsValid(veh) then return localAng or GetParentedLocalAngle() end
    return veh:LocalToWorldAngles(localAng or GetParentedLocalAngle())
end

-- Idle position of the piston inside its cylinder: hover offset back along
-- the ram axis from the mount point.
local function GetStoredLocalPos(offsetPos, offsetAng)
    local pos = isvector(offsetPos) and offsetPos or vector_origin
    local ang = isangle(offsetAng) and offsetAng or GetParentedLocalAngle()
    return pos - ang:Forward() * (TIV.Config.SpikeHoverOffset or 60)
end

TIV.SpikeAnim.GetSpikeDownAngle     = GetSpikeDownAngle
TIV.SpikeAnim.GetParentedLocalAngle = GetParentedLocalAngle
TIV.SpikeAnim.GetStoredLocalPos     = GetStoredLocalPos

local function SpeedMult()
    local cv = GetConVar("tiv_deploy_speed")
    return cv and math.max(0.2, cv:GetFloat()) or 1
end

local function DriveDepth(veh)
    local cv = GetConVar("tiv_spike_drive_depth")
    local depth = math.Clamp(cv and cv:GetFloat() or (TIV.Config.SpikeDriveDepth or 18), 5, 50)
    if IsValid(veh) and veh._TIVEffectiveStats and veh._TIVEffectiveStats.drive_depth_bonus then
        depth = depth + veh._TIVEffectiveStats.drive_depth_bonus
    end
    return depth
end

local function SendPhase(veh, index, phase)
    net.Start("TIV_SpikeAnimPhase")
        net.WriteEntity(veh)
        net.WriteUInt(index, 8)
        net.WriteString(phase)
    net.Broadcast()
end

-- ============================================================================
-- GROUND TRACE
-- ============================================================================
local function MakeTraceFilter(veh, data)
    return function(ent)
        if not IsValid(ent) then return true end
        if ent == veh or ent:GetParent() == veh then return false end
        if ent.TIV_OwnerVehicle == veh or ent.IsTIVArmor or ent.IsTIVSpike then return false end
        if ent:IsPlayer() and ent:GetVehicle() ~= NULL and IsValid(ent:GetVehicle()) then
            local seatParent = ent:GetVehicle():GetParent()
            if ent:GetVehicle() == veh or seatParent == veh then return false end
        end
        return true
    end
end

local function TraceGroundForSpike(veh, mountWorldPos, localAng, data)
    local downDir = veh:LocalToWorldAngles(localAng or GetParentedLocalAngle()):Forward()
    local filter = MakeTraceFilter(veh, data)
    local tr = util.TraceLine({ start = mountWorldPos, endpos = mountWorldPos + downDir * 350, filter = filter, mask = MASK_SOLID })
    if not tr.Hit then
        tr = util.TraceLine({ start = mountWorldPos, endpos = mountWorldPos + downDir * 500, filter = filter, mask = MASK_SOLID })
    end
    if not tr.Hit then
        tr = util.TraceLine({ start = mountWorldPos, endpos = mountWorldPos - veh:GetUp() * 400, filter = filter, mask = MASK_SOLID })
    end
    return tr
end
TIV.SpikeAnim.TraceGroundForSpike = TraceGroundForSpike

-- ============================================================================
-- FLAGS
-- ============================================================================
function TIV.SpikeAnim.ApplyVisibility(spike)
    if not IsValid(spike) then return end
    local cv = GetConVar("tiv_hide_spikes")
    local hidden = TIV.Config.HideSpikes == true or (cv and cv:GetBool())
    spike:SetNoDraw(hidden)
    spike:DrawShadow(not hidden)
end

function TIV.SpikeAnim.ApplyCompatibilityFlags(spike, veh)
    if not IsValid(spike) then return end
    spike:SetNWBool("TIV_Spike", true)
    if IsValid(veh) then
        spike:SetNWEntity("TIV_OwnerVehicle", veh)
        spike.TIV_OwnerVehicle = veh
    end
    spike:SetNWBool("GStormsIgnore", true)
    spike:SetNWBool("XT3Ignore", true)
    spike:SetNWBool("XT2Ignore", true)
    spike:SetNWBool("XTwister2Ignore", true)

    spike.IsTIVSpike           = true
    spike.GStormsIgnore        = true
    spike.XT3Ignore            = true
    spike.XT3DoNotApplyPhysics = true
    spike.XT2Ignore            = true
    spike.XT2DoNotApplyPhysics = true
    spike.XTwister2Ignore      = true
    spike.PhysgunDisabled      = true
    spike.DoNotDuplicate       = true
end

-- Stowed spikes ride parented with MOVETYPE_NONE: VPhysics cannot move the
-- entity at all, so a physgun unfreeze changes nothing. They must never be
-- welded to the chassis -- a motion-disabled body welded to the jeep pins
-- the jeep. Once unparented (planted / released) they go back to VPHYSICS.
local function StowPhysics(spike)
    local sp = spike:GetPhysicsObject()
    if IsValid(sp) then
        sp:EnableMotion(false)
        sp:EnableGravity(false)
    end
    spike:SetMoveType(MOVETYPE_NONE)
end

local function FreePhysics(spike)
    spike:SetMoveType(MOVETYPE_VPHYSICS)
end
TIV.SpikeAnim.StowPhysics = StowPhysics
TIV.SpikeAnim.FreePhysics = FreePhysics

-- ============================================================================
-- LAYOUT
-- ============================================================================
local function GetOffsetsForVehicle(veh)
    local offsets = TIV.Config.SpikeOffsets
    if not IsValid(veh) then return offsets.jeep end
    local model = string.lower(veh:GetModel() or "")
    local class = string.lower(veh:GetClass() or "")
    if class == "prop_vehicle_apc" or string.find(model, "apc", 1, true) then
        return offsets.prop_vehicle_apc or offsets.jeep
    end
    if class == "prop_vehicle_jalopy" or string.find(model, "jalopy", 1, true) or string.find(model, "vehicle.mdl", 1, true) then
        return offsets.jalopy or offsets.jeep
    end
    return offsets.jeep
end
TIV.SpikeAnim.GetOffsetsForVehicle = GetOffsetsForVehicle

local function ResolveOwner(veh)
    local ply = (veh.GetDriver and veh:GetDriver()) or veh._TIVOwner
    if not IsValid(ply) and veh.CPPIGetOwner then ply = veh:CPPIGetOwner() end
    if not IsValid(ply) and game.SinglePlayer() then ply = player.GetHumans()[1] end
    return ply
end

-- Parent the piston into its cylinder. Used at creation, after retract, and
-- when a sheared or lofted spike is taken back aboard.
function TIV.SpikeAnim.ReparentSpike(veh, spike, spikeData)
    if not IsValid(veh) or not IsValid(spike) then return end
    constraint.RemoveAll(spike)
    TIV.SpikeAnim.ApplyCompatibilityFlags(spike, veh)
    TIV.SpikeAnim.ApplyVisibility(spike)
    spike:SetCollisionGroup(COLLISION_GROUP_IN_VEHICLE)
    spike:SetParent(veh)
    spike:SetLocalPos(spikeData.storedLocalPos or spikeData.localPos or vector_origin)
    spike:SetLocalAngles(spikeData.storedLocalAng or GetParentedLocalAngle())
    StowPhysics(spike)
    spikeData.phase = "idle"
    spikeData.failed = nil
    spikeData.plantedPos = nil
end

-- A spike that has been pulled out of the ground. It is still the vehicle's
-- piston, so it rides with the chassis again, but at the extension it had
-- when it tore free: nothing retracts a piston that has lost its footing.
-- The next retract strokes it home from wherever it is.
function TIV.SpikeAnim.ReparentSpikeTorn(veh, spike, spikeData)
    if not IsValid(veh) or not IsValid(spike) then return end
    local localPos = veh:WorldToLocal(spike:GetPos())
    local localAng = veh:WorldToLocalAngles(spike:GetAngles())
    constraint.RemoveAll(spike)
    TIV.SpikeAnim.ApplyCompatibilityFlags(spike, veh)
    TIV.SpikeAnim.ApplyVisibility(spike)
    spike:SetCollisionGroup(COLLISION_GROUP_IN_VEHICLE)
    spike:SetParent(veh)
    spike:SetLocalPos(localPos)
    spike:SetLocalAngles(localAng)
    StowPhysics(spike)
    spikeData.phase      = "torn"
    spikeData.failed     = true
    spikeData.plantedPos = nil
    SendPhase(veh, spikeData.index, "torn")
end

function TIV.SpikeAnim.CreateSpikes(veh, data)
    if not IsValid(veh) then return end

    local ply = ResolveOwner(veh)
    local hasAngledUpg = false
    if IsValid(ply) and TIV.Progression and TIV.Progression.GetPlayerProfile then
        local prof = TIV.Progression.GetPlayerProfile(ply)
        hasAngledUpg = prof and prof.unlocked_upgrades and prof.unlocked_upgrades["angled_spikes"] == true or false
    end

    local customSpikes
    if not veh._TIVConfig and TIV.CustomConfig and TIV.CustomConfig.GetSavedConfig then
        veh._TIVConfig = TIV.CustomConfig.GetSavedConfig(veh:GetModel())
    end
    local config = veh._TIVConfig
        or (TIV.CustomConfig and TIV.CustomConfig.GetDefaultConfig and TIV.CustomConfig.GetDefaultConfig(veh:GetModel(), hasAngledUpg))
    if config and istable(config.components) then
        customSpikes = {}
        for _, comp in ipairs(config.components) do
            if comp.type == "spike" then customSpikes[#customSpikes + 1] = comp end
        end
        if #customSpikes == 0 then customSpikes = nil end
    end

    local offsets = customSpikes or GetOffsetsForVehicle(veh)
    local spikeCount = (TIV.Spikes and TIV.Spikes.ResolveCount and TIV.Spikes.ResolveCount(veh))
        or math.Clamp(customSpikes and #customSpikes or TIV.Config.SpikeCount, 0, 12)

    TIV.SpikeAnim._sessionCounter = TIV.SpikeAnim._sessionCounter + 1
    data.sessionID = string.format("%s_%d_%.2f_%d", tostring(TIV.Config.SessionSeed or 1000),
        veh:EntIndex(), CurTime(), TIV.SpikeAnim._sessionCounter)

    TIV.Spikes.RemoveAll(data, veh:EntIndex())
    data.spikes     = {}
    data.spikeAnims = {}
    if spikeCount <= 0 then return end

    local groups = {
        front = GetConVar("tiv_spike_group_front"),
        mid   = GetConVar("tiv_spike_group_mid"),
        rear  = GetConVar("tiv_spike_group_rear"),
    }
    local spreadOff = GetConVar("tiv_spike_spread_offset") and GetConVar("tiv_spike_spread_offset"):GetFloat() or 0
    local lengthOff = GetConVar("tiv_spike_length_offset") and GetConVar("tiv_spike_length_offset"):GetFloat() or 0

    for i = 1, spikeCount do
        local off = offsets[i]
        if not off then break end
        local grp = off.group or "mid"
        local groupCv = groups[grp]
        if groupCv and not groupCv:GetBool() then continue end

        local raw = off.pos or vector_origin
        local adjPos = Vector(raw.x, raw.y, raw.z)
        if not customSpikes then
            if adjPos.x > 0 then adjPos.x = adjPos.x + spreadOff
            elseif adjPos.x < 0 then adjPos.x = adjPos.x - spreadOff end
            adjPos.y = adjPos.y + lengthOff
        end

        local storedLocalAng = (hasAngledUpg and isangle(off.ang)) and Angle(off.ang) or GetParentedLocalAngle()
        local storedLocalPos = GetStoredLocalPos(adjPos, storedLocalAng)

        local model = off.model or TIV.Config.SpikeModel or SPIKE_MODEL_FALLBACK
        if not util.IsValidModel(model) then model = SPIKE_MODEL_FALLBACK end

        local spike = ents.Create("prop_physics")
        if not IsValid(spike) then continue end
        spike:SetModel(model)
        spike:SetPos(veh:LocalToWorld(storedLocalPos))
        spike:SetAngles(veh:LocalToWorldAngles(storedLocalAng))
        spike:Spawn()
        spike:Activate()
        spike:SetColor(Color(90, 90, 95, 255))
        spike:SetMaterial("models/props_combine/metal_combinebridge001")

        local sp = spike:GetPhysicsObject()
        if IsValid(sp) then
            sp:SetMass(25)
            sp:EnableMotion(false)
            sp:EnableGravity(false)
        end

        local sd = {
            entity         = spike,
            offset         = adjPos,
            storedLocalPos = storedLocalPos,
            storedLocalAng = storedLocalAng,
            localPos       = storedLocalPos,
            index          = i,
            tableIndex     = #data.spikes + 1,
            phase          = "idle",
            name           = off.name or ("Spike " .. i),
            group          = grp,
        }
        TIV.SpikeAnim.ReparentSpike(veh, spike, sd)
        data.spikes[#data.spikes + 1] = sd
        data.spikeAnims[i] = "idle"
    end
end

-- ============================================================================
-- HYDRAULIC RAM PROPS (cosmetic telescoping)
-- ============================================================================
function TIV.SpikeAnim.SetRamExtension(veh, frac)
    if not IsValid(veh) or not veh._TIVArmorProps then return end
    frac = math.Clamp(frac or 0, 0, 1)
    for _, prop in ipairs(veh._TIVArmorProps) do
        if IsValid(prop) and prop._TIVRamBasePos then
            local dir = prop._TIVRamDir or Vector(0, 0, -1)
            prop:SetLocalPos(prop._TIVRamBasePos + dir * ((prop._TIVRamTravel or 10) * frac))
        end
    end
end

local function CurrentRamExtension(veh)
    for _, prop in ipairs(veh._TIVArmorProps or {}) do
        if IsValid(prop) and prop._TIVRamBasePos then
            local dir = prop._TIVRamDir or Vector(0, 0, -1)
            local off = prop:GetLocalPos() - prop._TIVRamBasePos
            return math.Clamp(off:Dot(dir) / math.max(prop._TIVRamTravel or 10, 0.001), 0, 1)
        end
    end
    return nil
end

local function StartRamStroke(sessionID, veh, target, duration)
    local from = CurrentRamExtension(veh)
    if from == nil then return end
    local start = CurTime()
    duration = math.max(duration or 1, 0.01)
    TIV.SpikeAnim.ActiveJobs[sessionID .. "_rams"] = {
        veh = veh,
        fn = function()
            if not IsValid(veh) then return false end
            local frac = math.Clamp((CurTime() - start) / duration, 0, 1)
            TIV.SpikeAnim.SetRamExtension(veh, Lerp(math.sin(frac * math.pi * 0.5), from, target))
            return frac < 1
        end,
    }
end

-- ============================================================================
-- GENERIC PISTON STROKE
-- Moves one parented spike from where it is to `targetLocalPos` over
-- `duration` seconds, then calls onDone(spikeData). onTick(frac) is optional.
-- ============================================================================
local function StartStroke(sessionID, veh, spikeData, targetLocalPos, duration, jobName, onTick, onDone)
    local spike = spikeData.entity
    local localAng = spikeData.storedLocalAng or GetParentedLocalAngle()

    if not IsValid(spike:GetParent()) then
        local cur = veh:WorldToLocal(spike:GetPos())
        spike:SetCollisionGroup(COLLISION_GROUP_IN_VEHICLE)
        spike:SetParent(veh)
        spike:SetLocalPos(cur)
        spike:SetLocalAngles(localAng)
        StowPhysics(spike)
    end

    local startLocalPos = spike:GetLocalPos()
    local startTime = CurTime()
    duration = math.max(duration, 0.01)

    TIV.SpikeAnim.ActiveJobs[sessionID .. "_" .. jobName .. "_" .. spikeData.index] = {
        veh = veh, spike = spike,
        fn = function()
            if not IsValid(veh) or not IsValid(spike) then
                onDone(spikeData, false)
                return false
            end
            local frac = math.Clamp((CurTime() - startTime) / duration, 0, 1)
            local ease = math.sin(frac * math.pi * 0.5)
            spike:SetLocalPos(LerpVector(ease, startLocalPos, targetLocalPos))
            spike:SetLocalAngles(localAng)
            if onTick then onTick(frac) end
            if frac >= 1 then
                onDone(spikeData, true)
                return false
            end
            return true
        end,
    }
end

local DEPLOY_DELAY  = { rear = 0.00, mid = 0.12, front = 0.24 }
local RETRACT_DELAY = { front = 0.00, mid = 0.10, rear = 0.20 }

local function Completion(total, callback)
    local done, fired = 0, false
    return function()
        done = done + 1
        if done >= total and not fired then
            fired = true
            if callback then callback() end
        end
    end
end

-- ============================================================================
-- DEPLOY (also used for interrupt-and-deploy: strokes start where they are)
-- ============================================================================
function TIV.SpikeAnim.DeployToGround(veh, data, callback)
    if not IsValid(veh) or not data.spikes or #data.spikes == 0 then
        if callback then callback() end
        return
    end

    local sessionID = data.sessionID or tostring(veh:EntIndex())
    CancelVehicleJobs(sessionID)
    local speed = SpeedMult()
    local driveDuration = (TIV.Config.SpikeDriveDuration or 3) / speed
    StartRamStroke(sessionID, veh, 1, driveDuration)

    net.Start("TIV_SpikeAnimStart")
        net.WriteEntity(veh)
        net.WriteUInt(#data.spikes, 8)
    net.Broadcast()

    local tick = Completion(#data.spikes, callback)
    local depth = DriveDepth(veh)

    for i, sd in ipairs(data.spikes) do
        local spike = sd.entity
        if not IsValid(spike) then
            tick()
            continue
        end
        if sd.phase == "deployed" and not sd.failed then
            tick()
            continue
        end
        sd.tableIndex = i

        local delay = ((DEPLOY_DELAY[sd.group or "mid"] or 0.12) + ((i % 2 == 0) and 0.03 or 0)) / speed
        timer.Simple(delay, function()
            if not IsValid(veh) or not IsValid(spike) then
                tick()
                return
            end
            -- The sequence may have been reversed during the stagger delay.
            if data.state ~= "deploying_spikes" then
                tick()
                return
            end

            local localAng = sd.storedLocalAng or GetParentedLocalAngle()
            local mountWorld = veh:LocalToWorld(sd.storedLocalPos)
            local tr = TraceGroundForSpike(veh, mountWorld, localAng, data)
            local worldDir = veh:LocalToWorldAngles(localAng):Forward()
            local groundWorld = tr.Hit and tr.HitPos or (mountWorld + worldDir * 60)
            local groundNormal = tr.Hit and tr.HitNormal or veh:GetUp()
            local groundLocal = veh:WorldToLocal(groundWorld)
            local targetLocal = groundLocal + localAng:Forward() * depth

            sd.groundPos = groundWorld
            sd.groundNormal = groundNormal
            sd.targetLocalPos = targetLocal
            sd.phase = "deploying"
            data.spikeAnims[sd.index] = "deploying"
            SendPhase(veh, sd.index, "deploying")

            -- Stroke to the surface, then a shorter settle stroke to depth.
            StartStroke(sessionID, veh, sd, groundLocal, driveDuration * 0.88, "deploy", nil, function(_, ok)
                if not ok then tick() return end

                net.Start("TIV_SpikeAnimImpact")
                    net.WriteEntity(veh)
                    net.WriteUInt(sd.index, 8)
                    net.WriteVector(groundWorld)
                    net.WriteVector(groundNormal)
                net.Broadcast()
                spike:EmitSound("physics/metal/metal_solid_impact_bullet" .. math.random(1, 4) .. ".wav", 70, math.random(95, 105))

                StartStroke(sessionID, veh, sd, targetLocal, driveDuration * 0.12, "settle", nil, function(_, ok2)
                    if not ok2 then tick() return end
                    sd.phase = "deployed"
                    data.spikeAnims[sd.index] = "deployed"
                    TIV.Anchor.PlantSingle(veh, data, sd)
                    SendPhase(veh, sd.index, "deployed")
                    tick()
                end)
            end)
        end)
    end
end
TIV.SpikeAnim.InterruptAndDeploy = TIV.SpikeAnim.DeployToGround

-- ============================================================================
-- RETRACT (also used for interrupt-and-retract)
-- ============================================================================
function TIV.SpikeAnim.RetractFromGround(veh, data, callback)
    if not IsValid(veh) or not data.spikes or #data.spikes == 0 then
        if callback then callback() end
        return
    end

    local sessionID = data.sessionID or tostring(veh:EntIndex())
    CancelVehicleJobs(sessionID)
    local speed = SpeedMult()
    local retractDuration = (TIV.Config.SpikeRetractDuration or 3) / speed
    StartRamStroke(sessionID, veh, 0, retractDuration)

    net.Start("TIV_SpikeAnimRetract")
        net.WriteEntity(veh)
    net.Broadcast()

    local tick = Completion(#data.spikes, callback)

    for i, sd in ipairs(data.spikes) do
        local spike = sd.entity
        if not IsValid(spike) then
            tick()
            continue
        end
        if sd.phase == "idle" and IsValid(spike:GetParent()) then
            tick()
            continue
        end
        sd.tableIndex = i

        local delay = ((RETRACT_DELAY[sd.group or "mid"] or 0.10) + ((i % 2 == 0) and 0.02 or 0)) / speed
        timer.Simple(delay, function()
            if not IsValid(veh) or not IsValid(spike) then
                tick()
                return
            end
            if data.state ~= "retracting" then
                tick()
                return
            end

            -- Any hold-down on this spike is gone by now (sv_deploy releases
            -- before retracting); the nocollide stays until the spike is home.
            sd.phase = "retracting"
            data.spikeAnims[sd.index] = "retracting"
            SendPhase(veh, sd.index, "retracting")
            TIV.Anchor.UnplantSingle(veh, data, sd.index)

            StartStroke(sessionID, veh, sd, sd.storedLocalPos, retractDuration, "retract", nil, function(_, ok)
                if not ok then tick() return end
                TIV.SpikeAnim.ReparentSpike(veh, spike, sd)
                data.spikeAnims[sd.index] = "idle"
                SendPhase(veh, sd.index, "idle")
                tick()
            end)
        end)
    end
end
TIV.SpikeAnim.InterruptAndRetract = TIV.SpikeAnim.RetractFromGround

-- After a loft: every piston that is still aboard but not home (torn out
-- at some extension) is stroked back into its cylinder at retract speed, and
-- the rams follow. Spikes lost as debris are simply not there any more;
-- TIV.Deploy.EnsureSpikes rebuilds the set if the count no longer matches.
function TIV.SpikeAnim.StowAll(veh, data, callback)
    if not IsValid(veh) or not data or not data.spikes then
        if callback then callback() end
        return
    end
    local speed = SpeedMult()
    local duration = (TIV.Config.SpikeRetractDuration or 3) / speed
    local sessionID = data.sessionID or ("stow_" .. veh:EntIndex())
    local pending = 0
    local function done()
        pending = pending - 1
        if pending <= 0 and callback then callback() end
    end

    StartRamStroke(sessionID, veh, 0, duration)

    for i, sd in ipairs(data.spikes) do
        local spike = sd.entity
        if IsValid(spike) and not (sd.phase == "idle" and IsValid(spike:GetParent())) then
            sd.tableIndex = i
            pending = pending + 1
            if data.spikeAnims then data.spikeAnims[sd.index] = "retracting" end
            SendPhase(veh, sd.index, "retracting")
            StartStroke(sessionID, veh, sd, sd.storedLocalPos or vector_origin, duration, "stow", nil, function(_, ok)
                if ok and IsValid(veh) and IsValid(spike) then
                    TIV.SpikeAnim.ReparentSpike(veh, spike, sd)
                    if data.spikeAnims then data.spikeAnims[sd.index] = "idle" end
                    SendPhase(veh, sd.index, "idle")
                end
                done()
            end)
        end
    end
    if pending == 0 and callback then callback() end
end

print("[TIV] Dynamic spike animation system loaded")
