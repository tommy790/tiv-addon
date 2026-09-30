-- ============================================================================
-- TIV LOFT SYSTEM
-- ============================================================================
--   Anchored : no artificial forces on the chassis; storm mods are told to
--              leave it alone (SetAnchoredImmunity). Stress feedback only.
--   Failing  : once the wind passes the threshold the storm acts on the
--              chassis (data.gravityReleased lets sv_wind push it), the airbag
--              springs pop first -- audibly, releasing real tension -- and
--              then the stakes physically overload one at a time. There is no
--              scripted break order: each spike's break force decays while the
--              storm holds, and the windward spikes carry the most load, so
--              the front or back tears out first depending on where the wind
--              is. Each torn spike rides on at the extension it had.
--   Loft     : when the last spike goes (or the chassis has already lifted
--              40 u) the hold is severed and that is the entire loft. This
--              addon applies no forces of its own afterwards: the wind system
--              and any tornado mod (whose immunity was just cleared) act on
--              the free body, and gravity does the rest.
--   Reset    : 15 s later the pistons still aboard stroke home, lost ones are
--              replaced and the vehicle is idle.
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
-- Prevents GStorms, XTwisters 2, XTwisters 3, and generic storm mods from suctioning,
-- orbiting, or teleporting the anchored vehicle while constrained to the ground.
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

local function CleanupLoftTracking(entIdx)
    TIV.Loft.WindTimers[entIdx]    = nil
    TIV.Loft.FailingGroups[entIdx] = nil
    local data = TIV.Deploy.Vehicles and TIV.Deploy.Vehicles[entIdx]
    if data and data.state == "anchored" then
        data.gravityReleased   = false
        -- Calm reset: restore the stakes' standard break caps and stop the
        -- decay, so the hold re-stabilizes at full strength on whatever
        -- spikes are left.
        data._stakeWeakenStart = nil
        data._stakeWeakenRate  = nil
        local veh  = Entity(entIdx)
        local phys = IsValid(veh) and veh:GetPhysicsObject()
        local mass = IsValid(phys) and math.max(phys:GetMass(), 100) or nil
        for _, stake in ipairs(data.stakes or {}) do
            if mass then
                stake.cap0 = mass * 600 * 1.2 * (0.85 + math.random() * 0.30)
            end
        end
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
-- TEAR SPIKE (the physical failure of one planted spike)
-- Called by the stake hold when a spike's carried load passes its break force
-- (and by the legacy list helper below). The ground gives: the spike is
-- pulled out and rides with the chassis at the extension it had. Every
-- constraint on it goes (ground weld, nocollide); with the wind now acting on
-- the chassis (gravityReleased) the freed side lurches and the spike visibly
-- slides out of the earth while the others take its load.
-- ============================================================================
function TIV.Loft.TearSpike(veh, data, sd)
    if not IsValid(veh) or not data or not sd then return false end
    if sd.failed or data.state ~= "anchored" then return false end
    local cheatGodmode = GetConVar("tiv_cheat_godmode_anchors")
    if cheatGodmode and cheatGodmode:GetBool() then return false end

    sd.failed = true
    TIV.Anchor.UnplantSingle(veh, data, sd.index)

    local spikeEnt = sd.entity
    if IsValid(spikeEnt) then
        local sparkFX = EffectData()
        sparkFX:SetOrigin(spikeEnt:GetPos())
        sparkFX:SetMagnitude(8)
        sparkFX:SetScale(3)
        util.Effect("Sparks", sparkFX)
        spikeEnt:EmitSound("physics/metal/metal_box_break" .. math.random(1, 2) .. ".wav", 90, math.random(60, 80))
        if TIV.SpikeAnim and TIV.SpikeAnim.ReparentSpikeTorn then
            TIV.SpikeAnim.ReparentSpikeTorn(veh, spikeEnt, sd)
        end
    end
    if data.spikeAnims then data.spikeAnims[sd.index] = "torn" end

    net.Start("TIV_AnchorWarning")
        net.WriteEntity(veh)
        net.WriteUInt(sd.index or 0, 8)
    net.Broadcast()
    hook.Run("TIV_SpikeFailure", veh, sd.index)

    -- Last hold gone? (world sockets in 0-spike mode never enter this path)
    local remaining = 0
    for _, other in ipairs(data.spikes or {}) do
        if other.phase == "deployed" and not other.failed and IsValid(other.entity) then
            remaining = remaining + 1
        end
    end
    if remaining == 0 then
        TIV.Loft.TriggerLoft(veh, data)
    end
    return true
end

-- Legacy helper: tear a list of spikes with a fixed stagger. The physical
-- cascade in the stake hold decides order on its own now; this remains for
-- anything that wants an explicit teardown.
function TIV.Loft.FailSpikeList(veh, data, spikesToFail, duration)
    if not IsValid(veh) or not data or #spikesToFail == 0 then return end
    veh:EmitSound("physics/metal/metal_box_break1.wav", 88, 55)
    local staggerPerSpike = (duration or 0.3) / math.max(1, #spikesToFail)
    for i, sd in ipairs(spikesToFail) do
        timer.Simple((i - 1) * staggerPerSpike, function()
            if not IsValid(veh) or data.state ~= "anchored" then return end
            TIV.Loft.TearSpike(veh, data, sd)
        end)
    end
end

-- ============================================================================
-- START DIRECTIONAL WINDWARD FAILURE
-- Calculates wind angle relative to vehicle and shears windward anchors first.
-- ============================================================================
function TIV.Loft.StartDirectionalFailure(veh, data)
    if not IsValid(veh) or not data then return end
    if data.state ~= "anchored" then return end

    local entIndex = veh:EntIndex()
    if TIV.Loft.WindTimers[entIndex] then return end

    TIV.Loft.WindTimers[entIndex]    = CurTime()
    TIV.Loft.FailingGroups[entIndex] = true

    -- From here the storm is allowed to act on the chassis (sv_wind applies
    -- its force to an anchored vehicle only while gravityReleased is set), so
    -- the vehicle strains against the spikes that are left.
    --
    -- THE AIRBAGS GO FIRST, and visibly. The springs are still attached and
    -- TENSE the whole anchored state (FinalizeAnchored keeps them), so this
    -- pop releases genuinely stored tension: sparks and a pneumatic crack at
    -- every mount and the chassis lurches onto the stakes alone -- which now
    -- carry it in visible tension, straining against the wind.
    local pd = data.pullDown
    if pd then
        local popped = 0
        for _, e in ipairs(pd.elastics or {}) do
            if IsValid(e.con) then
                popped = popped + 1
                local lp = e.localPos
                if lp then
                    local ed = EffectData()
                    ed:SetOrigin(veh:LocalToWorld(Vector(lp.x, lp.y, lp.z)))
                    ed:SetMagnitude(4)
                    ed:SetScale(1.5)
                    util.Effect("Sparks", ed)
                end
            end
        end
        if popped > 0 then
            veh:EmitSound("physics/metal/metal_box_break2.wav", 90, 130)
            veh:EmitSound("physics/metal/metal_box_strain2.wav", 80, 60)
            util.ScreenShake(veh:GetPos(), 5, 10, 0.4, 500)
        end
    end
    data.gravityReleased = true
    TIV.Anchor.ReleaseSprings(veh, data)

    -- Gather all live, deployed spikes
    local liveSpikes = {}
    for _, sd in ipairs(data.spikes or {}) do
        if sd.phase == "deployed" and not sd.failed and IsValid(sd.entity) then
            table.insert(liveSpikes, sd)
        end
    end

    if #liveSpikes == 0 then
        TIV.Loft.TriggerLoft(veh, data)
        return
    end

    -- Determine relative wind vector to calculate windward vs leeward exposure
    local windForceVec = TIV.Wind.GetForceVector(veh)
    local localWind    = veh:WorldToLocal(veh:GetPos() + windForceVec):GetNormalized()

    for _, sd in ipairs(liveSpikes) do
        local lpos = sd.offset or veh:WorldToLocal(sd.entity:GetPos())
        sd._windExposure = lpos:Dot(localWind)
    end

    -- Sort ascending: the most UPWIND mounts (negative projection along the
    -- downwind vector) come first. Whichever end faces the wind -- front or
    -- back -- is the end that tears out first.
    table.sort(liveSpikes, function(a, b)
        return (a._windExposure or 0) < (b._windExposure or 0)
    end)

    -- The further over its threshold the vehicle is, the faster its stakes
    -- weaken: the decay rate below scales with the overshoot (2x at twice
    -- the threshold).
    local threshold = (veh._TIVEffectiveStats and veh._TIVEffectiveStats.effective_loft_mph)
        or TIV.Config.LoftWindThreshold or 180
    local overshoot = math.Clamp(TIV.Wind.GetSpeed(veh) / math.max(threshold, 1), 1, 2)

    print(string.format(
        "[TIV] Vehicle #%d exceeding threshold (%.2fx). Airbags blown -- stakes weakening, windward will overload first (%d live)",
        entIndex, overshoot, #liveSpikes))

    -- From here the stakes physically fail in load order -- no script picks
    -- the order. Two timed steps make that measurement honest:
    --
    -- 1. (+0.25s) RE-GRIP: popping the airbags lets the suspension rebound,
    --    which would otherwise read as a huge vertical stake overload and rip
    --    everything out in one tick. Instead each stake re-takes its grip on
    --    the rebounded chassis (the spike shaft absorbs the stroke), and the
    --    only load left on it is the wind.
    -- 2. (+0.60s) HAND OUT CAPS: each stake's break force is set from the
    --    load it is ACTUALLY carrying x (1 + StakeBreakForce x per-stake
    --    variance), floored so a momentarily unloaded stake is not immortal.
    --    Break force then decays (rate from the overshoot), so the failure
    --    self-balances across wind speed, vehicle mass and stake count: the
    --    windward stakes carry the most and go first, on their own.
    data._stakeWeakenRate = 0.35 * overshoot

    timer.Simple(0.25, function()
        if not IsValid(veh) or data.state ~= "anchored" or not data.stakes then return end
        for _, stake in ipairs(data.stakes) do
            local sd = stake.sd
            if sd and not sd.failed and sd.phase == "deployed" and IsValid(sd.entity) then
                stake.localPos = veh:WorldToLocal(stake.anchor)
                stake.carrying = false
            end
        end
    end)

    timer.Simple(0.60, function()
        if not IsValid(veh) or data.state ~= "anchored" or not data.stakes then return end
        local phys = veh:GetPhysicsObject()
        local mass = IsValid(phys) and math.max(phys:GetMass(), 100) or 800
        local floor = mass * 600 * 0.5
        for _, stake in ipairs(data.stakes) do
            local sd = stake.sd
            if sd and not sd.failed and sd.phase == "deployed" and IsValid(sd.entity) then
                -- Re-base the break cap on the load this stake is actually
                -- carrying, then let it decay. Most-loaded (windward) stake
                -- hits its cap first as everything decays together.
                local carried = math.max(stake.load or 0, floor)
                stake.cap0 = carried * (1 + (TIV.Config.StakeBreakForce or 5.5) * (stake.strength or 1))
            end
        end
        -- Decay clock starts when the caps exist.
        data._stakeWeakenStart = CurTime()
    end)
end

-- ============================================================================
-- TRIGGER FULL LOFT
-- Clean anchor severance. No launch forces: natural Source gravity and the
-- storm physics handle the flight from the moment the hold is cut.
-- ============================================================================
function TIV.Loft.TriggerLoft(veh, data)
    if not IsValid(veh) then return end
    if data.state == "lofted" then return end

    local cheatGodmode = GetConVar("tiv_cheat_godmode_anchors")
    if cheatGodmode and cheatGodmode:GetBool() then
        return
    end

    local entIdx    = veh:EntIndex()
    local sessionID = data.sessionID

    print("[TIV] ================================")
    print("[TIV] === TIV LOFT TRIGGERED       ===")
    print(string.format("[TIV] === Wind: %.0f MPH at t=%.2f ===",
        TIV.Wind.GetSpeed(veh), CurTime()))
    print("[TIV] ================================")

    -- 1. Complete constraint severance: vehicle is fully freed from spikes & world
    TIV.Anchor.ForceDetach(veh, data)
    timer.Remove("TIV_Lower_" .. entIdx)
    timer.Remove("TIV_Raise_" .. entIdx)

    data.state       = "lofted"
    data.anchored    = false
    data.plantedPos  = nil

    -- 2. Clear external tornado mod immunity so storm naturally carries the vehicle
    TIV.Loft.SetAnchoredImmunity(veh, false)

    -- 3. Restore vehicle gravity, motion, and physics
    -- finalizeAnchored applied the handbrake; StartRetract releases it on the
    -- normal path but a loft bypasses retract entirely, so without this the
    -- vehicle lands with the handbrake on and will not drive. That presents as a
    -- frozen vehicle even though the physics are healthy.
    if TIV.Deploy.ReleaseHandbrake then
        TIV.Deploy.ReleaseHandbrake(veh)
    end
    data.handbrakeOn = nil

    local phys = veh:GetPhysicsObject()
    if IsValid(phys) then
        phys:EnableGravity(true)
        phys:EnableMotion(true)
        phys:Wake()
        -- Deliberately NO launch forces here. Severing the anchors is the
        -- whole loft; the wind system and any tornado mod (whose immunity was
        -- cleared above) supply every force from this point. Anything this
        -- addon added on top -- launch impulse, updraft, tumble steering --
        -- only ever fought the storm for ownership of the same body.
    end

    -- 4. Spikes: torn ones already ride with the chassis at their extension.
    --    Anything still planted when the vehicle tears free (failsafe paths)
    --    is pulled out the same way; stowed pistons just stay stowed.
    if ReleaseSpikesOnLoft() then
        if TIV.Spikes.ReleaseAll then
            TIV.Spikes.ReleaseAll(data)
        end
    else
        for _, sd in ipairs(data.spikes or {}) do
            if IsValid(sd.entity) and sd.phase == "deployed" and TIV.SpikeAnim and TIV.SpikeAnim.ReparentSpikeTorn then
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

    -- 5. Automatic reset 15 seconds after loft: the pistons still aboard are
    --    stroked home, anything lost is replaced, and the vehicle is idle.
    timer.Simple(15, function()
        local liveVeh  = Entity(entIdx)
        local liveData = TIV.Deploy.Vehicles and TIV.Deploy.Vehicles[entIdx]

        if not liveData or liveData.sessionID ~= sessionID then return end

        if IsValid(liveVeh) and TIV.SpikeAnim and TIV.SpikeAnim.StowAll then
            TIV.SpikeAnim.StowAll(liveVeh, liveData, function()
                -- EnsureSpikes only rebuilds when the surviving count no
                -- longer matches, and only from idle.
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

        if IsValid(liveVeh) then
            -- Re-assert the "idle means drivable" invariant rather than assuming
            -- the loft path left things clean. Every one of these calls only ever
            -- enables physics or removes this addon's own constraints, so this
            -- cannot itself be what traps a vehicle.
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
            -- Replaces spikes lost as debris right away (a full set that is
            -- merely being stroked home matches the count and is kept).
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
    local effectiveThreshold = (veh._TIVEffectiveStats and veh._TIVEffectiveStats.effective_loft_mph)
        or TIV.Config.LoftWindThreshold or 180

    if not data.plantedPos then data.plantedPos = veh:GetPos() end

    -- Displacement failsafe. The stake hold is SOFT by design -- it strains,
    -- rebounds when the airbags pop, and gives under load -- so a small
    -- displacement is normal behaviour, not failure. Only a large one means
    -- the hold has physically lost the body, and then the stakes tear out
    -- with full FX (the last one lofts, as always) instead of silently
    -- teleporting the vehicle into the lofted state.
    local distFromPlanted = veh:GetPos():Distance(data.plantedPos)
    if distFromPlanted > (TIV.Config.StakeFailDistance or 150) then
        print(string.format("[TIV] Vehicle #%d displaced %.1f units from its anchors - hold physically lost!",
            entIndex, distFromPlanted))
        local live = {}
        for _, sd in ipairs(data.spikes or {}) do
            if sd.phase == "deployed" and not sd.failed and IsValid(sd.entity) then
                live[#live + 1] = sd
            end
        end
        if #live > 0 then
            -- Tears synchronously; TearSpike triggers the loft itself when
            -- the last one goes, so state is "lofted" before this returns.
            for _, sd in ipairs(live) do
                TIV.Loft.TearSpike(veh, data, sd)
            end
        else
            TIV.Loft.TriggerLoft(veh, data)
        end
        return
    end

    if not veh.XT3Ignore or not veh.GStormsIgnore or not veh.XT2Ignore then
        TIV.Loft.SetAnchoredImmunity(veh, true)
    end

    local isFailing = TIV.Loft.FailingGroups[entIndex] or data.gravityReleased

    -- A planted spike that lost its stake outside a failure sequence
    -- (e.g. an admin cleanup) is re-staked; during failure it counts as gone.
    for i, sd in ipairs(data.spikes or {}) do
        if sd.phase == "deployed" and not sd.failed and IsValid(sd.entity) then
            local hasStake = false
            for _, st in ipairs(data.stakes or {}) do
                if st.sd == sd then hasStake = true break end
            end
            if not hasStake then
                if isFailing or distFromPlanted > (TIV.Config.StakeFailDistance or 150) * 0.6 then
                    sd.failed = true
                else
                    TIV.Anchor.AttachSingle(veh, data, sd, i)
                end
            end
        end
    end

    local liveStakes = 0
    for _, sd in ipairs(data.spikes or {}) do
        if sd.phase == "deployed" and not sd.failed and IsValid(sd.entity) then
            liveStakes = liveStakes + 1
        end
    end
    if liveStakes == 0 and TIV.Spikes.GetCount(data) > 0 then
        print(string.format("[TIV] All anchors torn out on #%d - triggering immediate loft!", entIndex))
        TIV.Loft.TriggerLoft(veh, data)
        return
    end

    if stress > 0.40 then
        data.nextShakeTime = data.nextShakeTime or 0
        if CurTime() > data.nextShakeTime then
            data.nextShakeTime = CurTime() + 0.30
            util.ScreenShake(veh:GetPos(), math.Clamp(stress * 3.0, 0.5, 3.0), 10, 0.35, 350)
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
    if math.random() < soundChance then
        veh:EmitSound("physics/metal/metal_box_strain" .. math.random(1, 4) .. ".wav", 70, math.random(40, 65))
    end

    TIV.Loft.CheckArmorTear(veh, windMPH, TIV.Wind.GetForceVector(veh))

    if windMPH >= effectiveThreshold then
        if TIV.Spikes.GetCount(data) == 0 then
            TIV.Loft.TriggerLoft(veh, data)
        else
            TIV.Loft.StartDirectionalFailure(veh, data)
        end
    elseif TIV.Loft.WindTimers[entIndex] and not isFailing and windMPH < effectiveThreshold * 0.70 then
        data.calmDuration = (data.calmDuration or 0) + 0.05
        if data.calmDuration >= 2.0 then
            print(string.format("[TIV] Wind sustained drop to %.0f MPH - sequence reset for #%d", windMPH, entIndex))
            CleanupLoftTracking(entIndex)
            data.calmDuration = 0
        end
    else
        data.calmDuration = 0
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


print("[TIV] Loft system loaded")
