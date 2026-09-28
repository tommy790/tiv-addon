-- ============================================================================
-- TIV LOFT SYSTEM
-- ============================================================================
-- This module no longer decides which anchors fail. It measures the storm,
-- tells the anchor system to put its holds under a finite break force, and then
-- gets out of the way: the physics engine decides which spike lets go first and
-- how far the vehicle gets before nothing is holding it any more.
--
--   Grounded   : holds unbreakable, storm mods told to leave the chassis alone
--                (SetAnchoredImmunity). Every spike's soil grip is measured.
--   Heavy wind : immunity drops, the storm is allowed to act on the chassis and
--                the whole vehicle starts rocking on its anchors.
--   Failing    : past the loft threshold the holds are re-cut at
--                StressedForceLimit. They are NOT removed -- they keep
--                resisting, they just stop being infinite.
--   Partial    : the most loaded spike is dragged past its pull-out distance,
--                its own soil springs let go, and that end of the vehicle
--                rises while the others stay planted. The chassis rotates
--                around whatever is still in the ground.
--   Loft       : the last anchor loses, or the chassis is physically that far
--                off the ground, and the vehicle is simply free. Gravity and
--                the storm do the rest. Nothing is frozen, nothing is
--                teleported, no launch impulse is applied.
--   Reset      : ResetDelay seconds later the pistons still aboard stroke home,
--                lost ones are replaced and the vehicle is idle.
-- ============================================================================

TIV.Loft = TIV.Loft or {}

util.AddNetworkString("TIV_LoftEvent")
util.AddNetworkString("TIV_AnchorWarning")

TIV.Loft.WindTimers    = TIV.Loft.WindTimers    or {}
TIV.Loft.FailingGroups = TIV.Loft.FailingGroups or {}

local function ReleaseSpikesOnLoft()
    local cv = GetConVar("tiv_loft_release_spikes")
    return cv and cv:GetBool() or false
end

CreateConVar("tiv_loft_release_spikes", "0",
    { FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED },
    "If 1, spikes fly free as debris on loft. If 0, they stay on the vehicle at the extension they were torn out at.")

-- ============================================================================
-- EXTERNAL TORNADO MOD IMMUNITY HELPERS
-- Prevents GStorms, XTwisters 2, XTwisters 3, and generic storm mods from
-- suctioning, orbiting, or teleporting the anchored vehicle while it is solidly
-- constrained to the ground. Once the anchors are failing the immunity comes
-- off, because from that point the storm SHOULD be the thing moving it.
-- ============================================================================
function TIV.Loft.SetAnchoredImmunity(veh, enable)
    if not IsValid(veh) then return end
    if enable then
        veh:SetNWBool("GStormsIgnore", true)
        veh.GStormsIgnore        = true
        veh:SetNWBool("XT3Ignore", true)
        veh.XT3Ignore            = true
        veh.XT3DoNotApplyPhysics = true
        veh:SetNWBool("XT2Ignore", true)
        veh.XT2Ignore            = true
        veh.XT2DoNotApplyPhysics = true
        veh.XTwister2Ignore      = true
        veh.GStormsIgnoreWind    = true
        veh.XTwisterIgnore       = true
        veh.XTDoNotApplyPhysics  = true
    else
        veh:SetNWBool("GStormsIgnore", false)
        veh.GStormsIgnore        = nil
        veh:SetNWBool("XT3Ignore", false)
        veh.XT3Ignore            = nil
        veh.XT3DoNotApplyPhysics = nil
        veh:SetNWBool("XT2Ignore", false)
        veh.XT2Ignore            = nil
        veh.XT2DoNotApplyPhysics = nil
        veh.XTwister2Ignore      = nil
        veh.GStormsIgnoreWind    = nil
        veh.XTwisterIgnore       = nil
        veh.XTDoNotApplyPhysics  = nil
    end
end

-- ============================================================================
-- STRESS CALCULATION
-- ============================================================================
function TIV.Loft.CalculateStress(windMPH, veh)
    if windMPH < 100 then return 0 end
    local threshold = (IsValid(veh) and veh._TIVEffectiveStats and veh._TIVEffectiveStats.effective_loft_mph)
        or TIV.Config.LoftWindThreshold
        or 180
    local ratio = windMPH / threshold
    return math.Clamp(ratio * ratio, 0, 1)
end

local function GetWindScale(veh)
    local base = (TIV.Compat and TIV.Compat.Enabled) and (TIV.Compat.AnchoredWindForceScale or 0.65) or 1
    if IsValid(veh) and veh._TIVEffectiveStats and veh._TIVEffectiveStats.wind_force_mult then
        base = base * veh._TIVEffectiveStats.wind_force_mult
    end
    return base
end
TIV.Loft.GetWindScale = GetWindScale

local function GetLoftThreshold(veh)
    return (IsValid(veh) and veh._TIVEffectiveStats and veh._TIVEffectiveStats.effective_loft_mph)
        or TIV.Config.LoftWindThreshold or 180
end

local function CleanupLoftTracking(entIdx)
    TIV.Loft.WindTimers[entIdx]    = nil
    TIV.Loft.FailingGroups[entIdx] = nil
    local data = TIV.Deploy.Vehicles and TIV.Deploy.Vehicles[entIdx]
    if data then
        if data.state == "anchored" then data.gravityReleased = false end
        data.holdStressed = nil
    end
    for wave = 1, 3 do
        timer.Remove("TIV_WaveFail_" .. entIdx .. "_" .. wave)
    end
end
TIV.Loft.CleanupTracking = CleanupLoftTracking

-- ============================================================================
-- ARMOR TEARING (EXTREME VORTEX / AERODYNAMIC STRESS)
-- ============================================================================
function TIV.Loft.RipArmorPanel(veh, prop, windDir)
    if not IsValid(prop) then return end

    prop:SetParent(nil)
    constraint.RemoveAll(prop)
    prop.PhysgunDisabled      = nil
    prop.TIV_OwnerVehicle     = nil
    prop.IsTIVArmor           = nil
    prop.GStormsIgnore        = nil
    prop.XT3Ignore            = nil
    prop.XT3DoNotApplyPhysics = nil
    prop.XT2Ignore            = nil
    prop.XT2DoNotApplyPhysics = nil
    prop.XTwister2Ignore      = nil

    local phys = prop:GetPhysicsObject()
    if IsValid(phys) then
        phys:SetMass(35)
        phys:EnableMotion(true)
        phys:EnableGravity(true)
        phys:Wake()

        local tearDir = (windDir:GetNormalized() + Vector(0, 0, 0.35) + VectorRand() * 0.2):GetNormalized()
        phys:ApplyForceCenter(tearDir * phys:GetMass() * 2400)
        phys:ApplyTorqueCenter(VectorRand() * 1200)
    end

    prop:SetCollisionGroup(COLLISION_GROUP_DEBRIS)

    local ed = EffectData()
    ed:SetOrigin(prop:GetPos())
    ed:SetMagnitude(8)
    ed:SetScale(2.5)
    util.Effect("Sparks", ed)

    prop:EmitSound("physics/metal/metal_sheet_impact_hard" .. math.random(6, 8) .. ".wav", 95, math.random(70, 85))
    util.ScreenShake(prop:GetPos(), 8, 10, 0.5, 300)

    if IsValid(veh) and veh._TIVArmorProps then
        for i = #veh._TIVArmorProps, 1, -1 do
            if veh._TIVArmorProps[i] == prop then
                table.remove(veh._TIVArmorProps, i)
            end
        end
    end

    SafeRemoveEntityDelayed(prop, 15)
end

function TIV.Loft.CheckArmorTear(veh, windMPH, windForceVec)
    if not IsValid(veh) or not veh._TIVArmorProps or #veh._TIVArmorProps == 0 then return end
    if windMPH < 200 then return end

    if math.random() < 0.08 then
        local idx = math.random(1, #veh._TIVArmorProps)
        local prop = veh._TIVArmorProps[idx]
        if IsValid(prop) then
            TIV.Loft.RipArmorPanel(veh, prop, windForceVec)
        end
    end
end

-- ============================================================================
-- FORCED TEAR-OUT
-- ============================================================================
-- Not part of the normal sequence any more -- the storm does that itself. Kept
-- as an explicit tool (wire triggers, admin commands, cheats) and implemented
-- through the same path a real tear-out takes, so a spike that is forced out
-- loses its soil grip exactly like one the wind pulled out.
function TIV.Loft.FailSpikeList(veh, data, spikesToFail, duration)
    local cheatGodmode = GetConVar("tiv_cheat_godmode_anchors")
    if cheatGodmode and cheatGodmode:GetBool() then return end
    if not IsValid(veh) or not data or #spikesToFail == 0 then return end

    veh:EmitSound("physics/metal/metal_box_break1.wav", 88, 55)
    local staggerPerSpike = (duration or 0.3) / math.max(1, #spikesToFail)

    for i, sd in ipairs(spikesToFail) do
        local spikeIdx = sd.index
        timer.Simple((i - 1) * staggerPerSpike, function()
            if not IsValid(veh) or data.state ~= "anchored" then return end
            if sd.failed then return end

            TIV.Anchor.TearOutSpike(veh, data, sd)

            net.Start("TIV_AnchorWarning")
                net.WriteEntity(veh)
                net.WriteUInt(spikeIdx, 8)
            net.Broadcast()
        end)
    end
end

-- Tears the windward spikes first, on demand. Direction is still worked out the
-- same way it always was; what changed is that "tear" now means the spike's own
-- ground grip is released rather than its constraints being deleted.
function TIV.Loft.StartDirectionalFailure(veh, data)
    if not IsValid(veh) or not data then return end
    if data.state ~= "anchored" then return end

    local entIndex = veh:EntIndex()
    if TIV.Loft.WindTimers[entIndex] then return end

    TIV.Loft.WindTimers[entIndex]    = CurTime()
    TIV.Loft.FailingGroups[entIndex] = true
    data.gravityReleased = true

    TIV.Anchor.StressAll(veh, data)

    local liveSpikes = {}
    for _, sd in ipairs(data.spikes or {}) do
        if sd.phase == "deployed" and not sd.failed and not sd.slipped and IsValid(sd.entity) then
            table.insert(liveSpikes, sd)
        end
    end
    if #liveSpikes == 0 then return end

    local windForceVec = TIV.Wind.GetForceVector(veh)
    local localWind    = veh:WorldToLocal(veh:GetPos() + windForceVec):GetNormalized()
    for _, sd in ipairs(liveSpikes) do
        local lpos = sd.offset or veh:WorldToLocal(sd.entity:GetPos())
        sd._windExposure = lpos:Dot(localWind)
    end
    table.sort(liveSpikes, function(a, b)
        return (a._windExposure or 0) < (b._windExposure or 0)
    end)

    local count = #liveSpikes
    local wave1 = {}
    for i, sd in ipairs(liveSpikes) do
        if (i - 1) / count < 1 / 3 then table.insert(wave1, sd) end
    end
    TIV.Loft.FailSpikeList(veh, data, wave1, 0.25)
end

-- ============================================================================
-- FULL LOFT
-- ============================================================================
-- Reached when the anchors are physically gone, or when the chassis has been
-- carried so far off the ground that calling it anchored would be a lie. No
-- launch impulse is applied: by the time this runs the vehicle is already
-- moving under the storm, and gravity plus whatever the storm is doing take it
-- from there. That is the difference between being lofted and being thrown.
function TIV.Loft.TriggerLoft(veh, data)
    if not IsValid(veh) then return end
    if data.state == "lofted" then return end

    local cheatGodmode = GetConVar("tiv_cheat_godmode_anchors")
    if cheatGodmode and cheatGodmode:GetBool() then
        return
    end

    local entIdx    = veh:EntIndex()
    local sessionID = data.sessionID
    local survivors = TIV.Anchor.LiveGroundAnchorCount(data)

    print("[TIV] ================================")
    print("[TIV] === TIV LOFT TRIGGERED       ===")
    print(string.format("[TIV] === Wind: %.0f MPH  anchors left: %d  rise: %.1f u ===",
        TIV.Wind.GetSpeed(veh), survivors,
        data.plantedPos and math.max(0, veh:GetPos().z - data.plantedPos.z) or 0))
    print("[TIV] ================================")

    -- Anything that somehow survived goes now: a lofted vehicle must not be
    -- tethered. In the normal path this list is already empty.
    TIV.Anchor.ForceDetach(veh, data)
    timer.Remove("TIV_Lower_" .. entIdx)
    timer.Remove("TIV_Raise_" .. entIdx)

    data.state       = "lofted"
    data.anchored    = false
    data.plantedPos  = nil
    data.anchorStressed = nil

    TIV.Loft.SetAnchoredImmunity(veh, false)

    -- finalizeAnchored applied the handbrake; StartRetract releases it on the
    -- normal path but a loft bypasses retract entirely, so without this the
    -- vehicle lands with the handbrake on and will not drive.
    if TIV.Deploy.ReleaseHandbrake then
        TIV.Deploy.ReleaseHandbrake(veh)
    end
    data.handbrakeOn = nil

    -- Physics invariant: the body stays live and keeps its gravity. It is never
    -- frozen here and never repositioned here -- it is already in motion.
    TIV.Anchor.UnfreezeForDeploy(veh)

    -- Spikes: torn ones are already riding with the chassis at the extension
    -- they came out at. Anything still planted when the vehicle tears free
    -- comes out the same way; stowed pistons just stay stowed.
    if ReleaseSpikesOnLoft() then
        if TIV.Spikes.ReleaseAll then
            TIV.Spikes.ReleaseAll(data)
        end
    else
        for _, sd in ipairs(data.spikes or {}) do
            if IsValid(sd.entity) and sd.phase ~= "idle" and TIV.SpikeAnim and TIV.SpikeAnim.ReparentSpikeTorn then
                TIV.SpikeAnim.ReparentSpikeTorn(veh, sd.entity, sd)
                if data.spikeAnims and sd.index then data.spikeAnims[sd.index] = "torn" end
            end
        end
    end

    util.ScreenShake(veh:GetPos(), 25, 15, 3, 800)

    net.Start("TIV_LoftEvent")
        net.WriteEntity(veh)
    net.Broadcast()

    hook.Run("TIV_LoftEvent", veh)

    TIV.Deploy.BroadcastState(veh, "lofted")

    CleanupLoftTracking(entIdx)

    -- Automatic reset: the pistons still aboard are stroked home, anything lost
    -- is replaced, and the vehicle is idle.
    local resetDelay = math.max(1, tonumber(TIV.AnchorSetting("ResetDelay", 15)) or 15)
    timer.Simple(resetDelay, function()
        local liveVeh  = Entity(entIdx)
        local liveData = TIV.Deploy.Vehicles and TIV.Deploy.Vehicles[entIdx]

        if not liveData or liveData.sessionID ~= sessionID then return end

        if IsValid(liveVeh) and TIV.SpikeAnim and TIV.SpikeAnim.StowAll then
            TIV.SpikeAnim.StowAll(liveVeh, liveData, function()
                if not IsValid(liveVeh) or liveData.sessionID ~= sessionID then return end
                if liveData.state == "idle" and TIV.Deploy.EnsureSpikes then
                    TIV.Deploy.EnsureSpikes(liveVeh, liveData)
                end
            end)
        else
            for _, sd in ipairs(liveData.spikes or {}) do
                if IsValid(sd.entity) then SafeRemoveEntity(sd.entity) end
            end
            liveData.spikes        = {}
            liveData.spikeAnims    = {}
            liveData.spikesCreated = false
        end
        liveData.state           = "idle"
        liveData.anchored        = false
        liveData.gravityReleased = false
        liveData.plantedPos      = nil
        liveData.handbrakeOn     = nil
        liveData.anchorStressed  = nil

        if IsValid(liveVeh) then
            -- Re-assert the "idle means drivable" invariant rather than assuming
            -- the loft path left things clean.
            TIV.Anchor.DetachAll(liveVeh, liveData)
            if TIV.Deploy.ReleaseHandbrake then TIV.Deploy.ReleaseHandbrake(liveVeh) end

            local p = liveVeh:GetPhysicsObject()
            if IsValid(p) then
                if not p:IsGravityEnabled() then p:EnableGravity(true) end
                if not p:IsMotionEnabled() then
                    p:EnableMotion(true)
                    p:Wake()
                end
            end

            TIV.Deploy.BroadcastState(liveVeh, "idle")
            if TIV.Deploy.EnsureSpikes then TIV.Deploy.EnsureSpikes(liveVeh, liveData) end
            if TIV.CustomComponents and TIV.CustomComponents.EnsureArmor then
                TIV.CustomComponents.EnsureArmor(liveVeh)
            end
        end
    end)
end

-- ============================================================================
-- MAIN LOFT THINK
-- ============================================================================
local function ProcessAnchored(entIndex, veh, data)
    local phys = veh:GetPhysicsObject()
    if not IsValid(phys) then return end

    local windMPH = TIV.Wind.GetSpeed(veh)
    local stress  = TIV.Loft.CalculateStress(windMPH, veh)
    local effectiveThreshold = GetLoftThreshold(veh)

    if not data.plantedPos then data.plantedPos = veh:GetPos() end

    -- ------------------------------------------------------------------
    -- MEASURE THE ANCHORS
    -- This is the heart of it: every spike's own grip is sampled, and any
    -- spike the ground can no longer hold tears itself out here. Nothing
    -- below decides that a spike has failed -- this does, from where the
    -- spike physically is.
    -- ------------------------------------------------------------------
    local report = TIV.Anchor.UpdateAnchors(veh, data)

    -- A planted spike that lost its hold without losing the ground (an admin
    -- cleanup, a stray RemoveConstraints) is re-locked. One that tore out is
    -- left alone: re-anchoring it would be exactly the "snap it back"
    -- behaviour this system exists to avoid.
    local isFailing = TIV.Loft.FailingGroups[entIndex] or data.gravityReleased
    if not isFailing then
        for i, sd in ipairs(data.spikes or {}) do
            if sd.phase == "deployed" and not sd.failed and not sd.slipped and IsValid(sd.entity) then
                if not TIV.Anchor.HasHold(data, sd.index) then
                    TIV.Anchor.AttachSingle(veh, data, sd, i)
                end
            end
        end
    end

    -- Only anchors that reach the ground count here: see
    -- TIV.Anchor.LiveGroundAnchorCount for why a chassis<->spike hold whose
    -- spike has come out of the earth is not an anchor.
    local liveAnchors = TIV.Anchor.LiveGroundAnchorCount(data)

    -- ------------------------------------------------------------------
    -- FAILSAFE: the anchors are gone
    -- Reached through physics in the normal path. Also catches a storm mod
    -- that picks the whole body up regardless of what is holding it.
    -- ------------------------------------------------------------------
    local rise = veh:GetPos().z - data.plantedPos.z
    local maxLift = tonumber(TIV.AnchorSetting("MaxLiftBeforeLoft", 130)) or 0
    local maxRise = tonumber(TIV.AnchorSetting("MaxRiseBeforeLoft", 90)) or 0

    if liveAnchors == 0 then
        print(string.format("[TIV] #%d: every anchor has let go (spikes fitted: %d) - the vehicle is free",
            entIndex, TIV.Spikes.GetCount(data)))
        TIV.Loft.TriggerLoft(veh, data)
        return
    end
    if maxLift > 0 and veh:GetPos():Distance(data.plantedPos) > maxLift then
        print(string.format("[TIV] #%d carried %.1f u from its anchors - completing loft", entIndex,
            veh:GetPos():Distance(data.plantedPos)))
        TIV.Loft.TriggerLoft(veh, data)
        return
    end
    if maxRise > 0 and rise > maxRise then
        print(string.format("[TIV] #%d risen %.1f u while %d anchor(s) nominally survive - completing loft",
            entIndex, rise, liveAnchors))
        TIV.Loft.TriggerLoft(veh, data)
        return
    end

    -- ------------------------------------------------------------------
    -- STORM COUPLING
    -- Solidly anchored: the storm mods are told to leave it alone and the
    -- chassis feels nothing. Failing: immunity drops and the storm is what
    -- loads the anchors in the first place.
    -- ------------------------------------------------------------------
    if isFailing then
        if veh.XT3Ignore or veh.GStormsIgnore or veh.XT2Ignore then
            TIV.Loft.SetAnchoredImmunity(veh, false)
        end
    elseif not veh.XT3Ignore or not veh.GStormsIgnore or not veh.XT2Ignore then
        TIV.Loft.SetAnchoredImmunity(veh, true)
    end

    -- ------------------------------------------------------------------
    -- THRESHOLD: put the holds under a finite break force.
    -- The constraints stay exactly where they are.
    -- ------------------------------------------------------------------
    if windMPH >= effectiveThreshold then
        if not data.holdStressed then
            data.holdStressed = true
            TIV.Loft.WindTimers[entIndex]    = TIV.Loft.WindTimers[entIndex] or CurTime()
            TIV.Loft.FailingGroups[entIndex] = true
            data.gravityReleased = true

            local stressed = TIV.Anchor.StressAll(veh, data)
            if stressed == 0 and TIV.Spikes.GetCount(data) == 0 then
                -- No spikes and no world anchors to stress: nothing is holding
                -- it, so it is simply loose.
                TIV.Loft.TriggerLoft(veh, data)
                return
            end
        end
    elseif data.holdStressed and windMPH < effectiveThreshold * 0.70 then
        -- The storm backed off. The holds go back to unbreakable and the
        -- sequence stands down -- the vehicle settles back onto the spikes it
        -- still has, on its own.
        data.calmDuration = (data.calmDuration or 0) + 0.05
        if data.calmDuration >= 2.0 then
            TIV.Anchor.UnstressAll(veh, data)
            data.holdStressed = nil
            data.gravityReleased = false
            print(string.format("[TIV] Wind sustained drop to %.0f MPH - hold stress released for #%d", windMPH, entIndex))
            CleanupLoftTracking(entIndex)
            data.calmDuration = 0
            -- Spikes that tore out stay out; a vehicle on four anchors is a
            -- vehicle on four anchors until it retracts.
        end
    else
        data.calmDuration = 0
    end

    -- ------------------------------------------------------------------
    -- FEEDBACK
    -- ------------------------------------------------------------------
    local shakeStress = math.max(stress, report.worst or 0)
    if shakeStress > 0.40 then
        data.nextShakeTime = data.nextShakeTime or 0
        if CurTime() > data.nextShakeTime then
            data.nextShakeTime = CurTime() + 0.30
            util.ScreenShake(veh:GetPos(), math.Clamp(shakeStress * 3.0, 0.5, 3.0), 10, 0.35, 350)
        end
    end

    local soundChance
    if stress > TIV.Config.Stress.SoundCrit then
        soundChance = TIV.Config.StressCritChance
    elseif stress > TIV.Config.Stress.SoundHigh then
        soundChance = TIV.Config.StressHighSoundChance
    else
        soundChance = TIV.Config.StressLowSoundChance
    end
    -- An anchor near its limit groans whether or not the wind number alone says
    -- it should: this is the sound of a spike being dragged out of the ground.
    if (report.overloaded or 0) > 0 then
        soundChance = math.max(soundChance, 0.06)
    end
    if math.random() < soundChance then
        veh:EmitSound("physics/metal/metal_box_strain" .. math.random(1, 4) .. ".wav", 70, math.random(40, 65))
    end

    TIV.Loft.CheckArmorTear(veh, windMPH, TIV.Wind.GetForceVector(veh))

    -- Zero-spike mode: the world anchors were cut at the stressed limit from
    -- the start, so once the storm is past the threshold they can go at any
    -- moment and there is nothing else to wait for. (The check at the top of
    -- the next tick catches this too; doing it here just saves 50 ms.)
    if windMPH >= effectiveThreshold and TIV.Spikes.GetCount(data) == 0 and report.planted == 0 then
        if TIV.Anchor.LiveGroundAnchorCount(data) == 0 then
            TIV.Loft.TriggerLoft(veh, data)
        end
    end
end

timer.Create("TIV_LoftThink", 0.05, 0, function()
    for entIndex, data in pairs(TIV.Deploy.Vehicles or {}) do
        if data.state == "anchored" then
            local veh = Entity(entIndex)
            if IsValid(veh) then
                ProcessAnchored(entIndex, veh, data)
            end
        elseif TIV.Loft.WindTimers[entIndex] then
            CleanupLoftTracking(entIndex)
        end
    end
end)

-- ============================================================================
-- CLEANUP
-- ============================================================================


print("[TIV] Loft system loaded (physics-driven anchor failure)")
