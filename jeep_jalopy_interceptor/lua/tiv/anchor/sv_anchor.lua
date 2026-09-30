-- ============================================================================
-- TIV ANCHOR SYSTEM
-- ============================================================================
-- Everything that physically ties the chassis to the ground lives here.
--
--   Plant   : a spike that has reached its drive depth becomes a static body
--             (motion disabled) -- it is now part of the world.
--   Pull-down: elastic constraints from every layout mount to a point below
--             the ground under it are shortened over LowerTime. The chassis is
--             pulled down onto its own suspension by real constraint force;
--             the raycast wheels compress exactly as far as the suspension
--             allows. Independent of how many spikes are fitted.
--   Lock    : planted spikes pin the chassis in real time -- no ballsocket
--             joint between chassis and spike. Every tick the hold thinks, it
--             measures how far the spike's mount point has drifted from where
--             the spike planted and applies a restoring spring-damper force at
--             that point (world sockets take this job when no spikes are
--             fitted). At rest the stakes carry nothing; in wind the body
--             visibly strains, rocks on the planted spikes and each spike
--             carries a measurable load. When a spike's load passes its break
--             force it tears out -- which spike goes first is decided by the
--             wind, not a script. The pull-down springs STAY attached and
--             tense the whole anchored state: stakes pin, springs pre-load
--             down. tiv_cheat_godmode_anchors makes the stakes unbreakable.
--
-- The chassis physics object is never frozen, never teleported and keeps its
-- gravity throughout. Releasing the constraints is what raises the vehicle:
-- the suspension springs back on its own.
-- ============================================================================

TIV.Anchor = TIV.Anchor or {}

local function GetPivotLimit()
    return math.Clamp(tonumber(TIV.Config.AnchorPivotLimit) or 28, 5, 60)
end

local function Track(data, con, spikeData, kind, extra)
    data.constraints = data.constraints or {}
    local rec = {
        constraint      = con,
        spikeIndex      = spikeData and spikeData.index or 0,
        spikeTableIndex = spikeData and spikeData.tableIndex,
        type            = kind,
    }
    if extra then
        for k, v in pairs(extra) do rec[k] = v end
    end
    data.constraints[#data.constraints + 1] = rec
    return rec
end

local function VehicleMass(veh)
    local phys = veh:GetPhysicsObject()
    return IsValid(phys) and math.max(phys:GetMass(), 100) or 800
end

-- ============================================================================
-- PLANT (spike becomes static, chassis and spike ignore each other)
-- ============================================================================
function TIV.Anchor.PlantSingle(veh, data, spikeData)
    if not IsValid(veh) or not IsValid(spikeData.entity) then return end
    local spike = spikeData.entity
    local pos, ang = spike:GetPos(), spike:GetAngles()

    -- The spike sits below the surface on purpose. It must never be simulated
    -- as a live body there or the solver ejects it: freeze first, then
    -- unparent, then hand the (already frozen) physics object its position.
    local sp = spike:GetPhysicsObject()
    if IsValid(sp) then
        sp:EnableMotion(false)
        sp:EnableGravity(false)
    end
    spike:SetCollisionGroup(COLLISION_GROUP_WORLD)

    if IsValid(spike:GetParent()) then
        spike:SetParent(nil)
    end
    spike:SetMoveType(MOVETYPE_VPHYSICS)
    spike:SetPos(pos)
    spike:SetAngles(ang)
    if IsValid(sp) then
        sp:SetPos(pos)
        sp:SetAngles(ang)
        sp:SetVelocity(vector_origin)
        sp:SetAngleVelocity(vector_origin)
        sp:EnableMotion(false)
    end

    -- Welded to the world: this is what holds it in the ground; the motion
    -- flag is only a solver shortcut. A weld to a frozen body is not solved,
    -- so it cannot generate a penetration push either.
    local groundWeld = constraint.Weld(spike, game.GetWorld(), 0, 0, 0, true, false)
    if IsValid(groundWeld) then Track(data, groundWeld, spikeData, "groundweld") end

    local nocol = constraint.NoCollide(veh, spike, 0, 0)
    if IsValid(nocol) then Track(data, nocol, spikeData, "nocollide") end

    spikeData.plantedPos = pos
    spikeData.phase = "deployed"
end

-- ============================================================================
-- PULL-DOWN (elastics chassis -> ground)
-- ============================================================================
-- The springs run from the chassis mounts to points on the world found by
-- tracing straight down, so lowering does not depend on spikes existing.
local function GroundTraceFilter(veh, data)
    return function(ent)
        if not IsValid(ent) then return true end
        if ent == veh or ent:GetParent() == veh then return false end
        if ent.TIV_OwnerVehicle == veh or ent.IsTIVArmor or ent.IsTIVSpike then return false end
        if ent:IsPlayer() or ent:IsVehicle() then return false end
        for _, sd in ipairs(data.spikes or {}) do
            if sd.entity == ent then return false end
        end
        return true
    end
end

-- The airbag mounts are ALL the spike mounts of the vehicle's layout
-- (TIV.Config.SpikeOffsets), whatever number of spikes is actually fitted:
-- the airbags lower the whole vehicle, the spikes only decide where it is
-- pinned afterwards. Using only the fitted spikes' mounts made a two-spike
-- vehicle kneel on its nose. An earlier no-spike fallback used the
-- render-bounds corners near the wheel bottoms, where the ground trace could
-- start inside a slope and the lopsided pull threw the vehicle around.
local function MountPoints(veh, data)
    local mounts = {}
    local offsets = TIV.SpikeAnim and TIV.SpikeAnim.GetOffsetsForVehicle and TIV.SpikeAnim.GetOffsetsForVehicle(veh)
    for _, off in ipairs(offsets or {}) do
        if isvector(off.pos) then mounts[#mounts + 1] = Vector(off.pos.x, off.pos.y, off.pos.z) end
    end
    if #mounts > 0 then return mounts end

    for _, sd in ipairs(data.spikes or {}) do
        local lp = sd.storedLocalPos or sd.localPos or sd.offset
        if lp then mounts[#mounts + 1] = lp end
    end
    if #mounts > 0 then return mounts end

    local mins, maxs = veh:OBBMins(), veh:OBBMaxs()
    local ix, iy = (maxs.x - mins.x) * 0.2, (maxs.y - mins.y) * 0.2
    return {
        Vector(maxs.x - ix, maxs.y - iy, 0),
        Vector(maxs.x - ix, mins.y + iy, 0),
        Vector(mins.x + ix, maxs.y - iy, 0),
        Vector(mins.x + ix, mins.y + iy, 0),
    }
end
TIV.Anchor.MountPoints = MountPoints

-- Ground surface at a mount's x/y. The spike mounts sit at the chassis
-- origin, i.e. at ground level on a jeep at ride height and BELOW the
-- surface once the vehicle has been pulled down, so the trace starts well
-- above the mount and the surface may legitimately be above it. The vehicle
-- and everything it carries are excluded by the filter, so whatever the
-- trace hits is ground.
local TRACE_LIFT = 48
local function GroundUnder(mountWorld, filter)
    local tr = util.TraceLine({
        start  = mountWorld + Vector(0, 0, TRACE_LIFT),
        endpos = mountWorld - Vector(0, 0, 300),
        filter = filter,
        mask   = MASK_SOLID,
    })
    if not tr.Hit or tr.StartSolid then return nil end
    return tr.HitPos
end

-- Returns the number of springs created. `lowerAmount` is how far the chassis
-- should end up below its current height; the suspension is the real limit,
-- the spring only supplies the pull. lowerAmount 0 just holds the current pose.
local RemoveByType

function TIV.Anchor.StartPullDown(veh, data, lowerAmount)
    if not IsValid(veh) then return 0 end
    -- Springs kept through the anchored state (mounts with no spike) would
    -- otherwise hold the old length against the new set.
    RemoveByType(data, "elastic")
    -- game.GetWorld() is never IsValid(); constraint.* accepts it directly.
    local world = game.GetWorld()
    if not world then return 0 end
    lowerAmount = lowerAmount or 0

    local mounts = MountPoints(veh, data)
    local filter = GroundTraceFilter(veh, data)
    local mass = VehicleMass(veh)
    local overshoot = 12

    -- The spring's ground end sits below the surface by the full stroke plus
    -- a margin. A spring is only ever shortened by lowerAmount + overshoot,
    -- so its length can never be asked to go below the margin no matter how
    -- close the mount is to the ground; with the end on the surface itself a
    -- mount at ground level (the spike mounts sit at the chassis origin) left
    -- nothing to shorten and the vehicle barely moved.
    local anchorDepth = lowerAmount + overshoot + 8

    -- Find the ground first so the per-spring force is shared between the
    -- springs that actually exist, not the mounts that were asked for.
    local anchors = {}
    for _, mountLocal in ipairs(mounts) do
        local mountWorld = veh:LocalToWorld(mountLocal)
        local hit = GroundUnder(mountWorld, filter)
        if hit then
            local anchorPos = hit - Vector(0, 0, anchorDepth)
            anchors[#anchors + 1] = { localPos = mountLocal, hitPos = anchorPos, restLength = mountWorld:Distance(anchorPos) }
        end
    end

    data.pullDown = { elastics = {}, startTime = CurTime(), lowerAmount = lowerAmount, overshoot = overshoot }
    local n = #anchors
    if n == 0 then return 0 end
    if n < #mounts then
        print(string.format("[TIV] #%d pull-down: ground under %d of %d mounts", veh:EntIndex(), n, #mounts))
    end
    if GetConVar("tiv_debug_freeze") and GetConVar("tiv_debug_freeze"):GetBool() then
        for i, a in ipairs(anchors) do
            print(string.format("[TIV] #%d spring %d: mount (%.0f %.0f %.0f) rest %.1f u, will shorten by %.1f u",
                veh:EntIndex(), i, a.localPos.x, a.localPos.y, a.localPos.z, a.restLength, lowerAmount + overshoot))
        end
    end

    -- At full shortening the springs pull with roughly 8x the vehicle weight,
    -- spread across the springs.
    local constant = (mass * 600 * 8) / (n * (lowerAmount + overshoot))
    local damping  = (mass * 40) / n

    for _, a in ipairs(anchors) do
        local el = constraint.Elastic(veh, world, 0, 0, a.localPos, a.hitPos,
            constant, damping, 0, "", 0, true)
        if IsValid(el) then
            el:Fire("SetSpringLength", tostring(a.restLength))
            Track(data, el, nil, "elastic", { restLength = a.restLength, localPos = a.localPos })
            data.pullDown.elastics[#data.pullDown.elastics + 1] = { con = el, restLength = a.restLength }
        end
    end
    return #data.pullDown.elastics
end

-- frac 0..1 of the lowering stroke; drives the spring lengths.
function TIV.Anchor.UpdatePullDown(data, frac)
    local pd = data.pullDown
    if not pd then return end
    local ease = frac * frac * (3 - 2 * frac)
    local shorten = (pd.lowerAmount + pd.overshoot) * ease
    for _, e in ipairs(pd.elastics) do
        if IsValid(e.con) then
            e.con:Fire("SetSpringLength", tostring(math.max(e.restLength - shorten, 1)))
        end
    end
end

-- frac 0..1 of the raise stroke; the stretch-only springs act as a ceiling
-- that is let out gradually, so the suspension rebounds at hydraulic speed.
function TIV.Anchor.UpdateRaise(data, frac, riseAmount)
    local pd = data.pullDown
    if not pd then return end
    local ease = frac * frac * (3 - 2 * frac)
    local extend = (riseAmount + pd.overshoot) * ease
    for _, e in ipairs(pd.elastics) do
        if IsValid(e.con) then
            e.con:Fire("SetSpringLength", tostring(e.restLength + extend))
        end
    end
end

RemoveByType = function(data, wanted)
    for i = #(data.constraints or {}), 1, -1 do
        local c = data.constraints[i]
        if c.type == wanted then
            if IsValid(c.constraint) then c.constraint:Remove() end
            table.remove(data.constraints, i)
        end
    end
end

-- Drops the springs only; used once the ballsockets hold the pose.
function TIV.Anchor.ReleaseSprings(veh, data)
    RemoveByType(data, "elastic")
    data.pullDown = nil
end

-- Once the spikes are locked, the springs at mounts a planted spike now
-- holds are dropped; the springs at mounts WITHOUT a spike stay and keep
-- that part of the vehicle down (the airbag under it is still inflated),
-- so a partial spike set still holds the whole vehicle lowered. They go
-- with everything else on retract or when the hold is broken.
local COVER_RADIUS = 24
function TIV.Anchor.ReleaseCoveredSprings(veh, data)
    if not IsValid(veh) then return end
    local planted = {}
    for _, sd in ipairs(data.spikes or {}) do
        if sd.phase == "deployed" and IsValid(sd.entity) then
            planted[#planted + 1] = veh:WorldToLocal(sd.entity:GetPos())
        end
    end
    if #planted == 0 then return end

    local kept = {}
    for i = #(data.constraints or {}), 1, -1 do
        local c = data.constraints[i]
        if c.type == "elastic" then
            local covered = false
            if c.localPos then
                for _, lp in ipairs(planted) do
                    if (Vector(lp.x, lp.y, 0) - Vector(c.localPos.x, c.localPos.y, 0)):Length() <= COVER_RADIUS then
                        covered = true
                        break
                    end
                end
            end
            if covered or not IsValid(c.constraint) then
                if IsValid(c.constraint) then c.constraint:Remove() end
                table.remove(data.constraints, i)
            else
                kept[#kept + 1] = c
            end
        end
    end

    if data.pullDown then
        local remaining = {}
        for _, e in ipairs(data.pullDown.elastics) do
            if IsValid(e.con) then remaining[#remaining + 1] = e end
        end
        data.pullDown.elastics = remaining
        if #remaining == 0 then data.pullDown = nil end
    end
end

-- Releases the hold: the stake forces stop and any world sockets go. The
-- springs (if any) keep the body down until their own release step.
function TIV.Anchor.ReleaseLock(veh, data)
    TIV.Anchor.ReleaseStakes(veh, data)
    RemoveByType(data, "ballsocket")
end

-- ============================================================================
-- STAKES (real-time hold, no chassis<->spike joint)
-- A planted spike is already welded to the world (PlantSingle). What holds the
-- CHASSIS is the stake force: every tick, for every planted spike, the mount
-- point of the chassis is spring-damper pulled back toward the pose the
-- vehicle settled in when the spike bit the ground. At rest the drift is zero
-- and the stakes apply nothing at all. Under wind the drift grows, the force
-- ramps, the body strains and rocks on the planted spikes, and a spike whose
-- carried load exceeds its break force is torn out by the loft module --
-- physically, in load order (the windward spikes carry the most).
-- ============================================================================
-- Break force for one stake, as multiples of vehicle weight. tiv_spike_force
-- > 0 overrides it with an absolute value; the godmode cheat makes stakes
-- unbreakable. Strength gets a per-stake +-15% variance so failures space out
-- organically instead of in lockstep.
local STAKE_TICK = 0.015

local function StakeBaseCap(veh)
    local god = GetConVar("tiv_cheat_godmode_anchors")
    if god and god:GetBool() then return math.huge end
    local cv = GetConVar("tiv_spike_force")
    local absolute = cv and cv:GetFloat() or 0
    if absolute and absolute > 0 then return absolute end
    local phys = veh:GetPhysicsObject()
    local mass = IsValid(phys) and math.max(phys:GetMass(), 100) or 800
    return mass * 600 * (TIV.Config.StakeBreakForce or 5.5)
end

local function StartStakeThink(veh, data)
    if data._stakeTimer then return end
    local timerName = "TIV_StakeHold_" .. veh:EntIndex()
    data._stakeTimer = timerName
    timer.Create(timerName, STAKE_TICK, 0, function()
        if not IsValid(veh) or not data.stakes or data.state ~= "anchored" then
            timer.Remove(timerName)
            if data then data._stakeTimer = nil end
            return
        end
        TIV.Anchor.StakeThink(veh, data)
    end)
end

function TIV.Anchor.AttachSingle(veh, data, spikeData, spikeTableIndex)
    if not IsValid(veh) or not IsValid(spikeData.entity) then return end
    spikeData.tableIndex = spikeTableIndex or spikeData.tableIndex

    data.stakes = data.stakes or {}
    for _, st in ipairs(data.stakes) do
        if st.sd == spikeData then return end -- already staked
    end

    local anchor = spikeData.plantedPos or spikeData.entity:GetPos()
    data.stakes[#data.stakes + 1] = {
        sd       = spikeData,
        localPos = veh:WorldToLocal(anchor),
        anchor   = Vector(anchor.x, anchor.y, anchor.z),
        strength = 0.85 + math.random() * 0.30,
        load     = 0,
    }
    StartStakeThink(veh, data)
end

function TIV.Anchor.AttachAll(veh, data)
    if not IsValid(veh) then return end
    for i, sd in ipairs(data.spikes or {}) do
        if sd.phase == "deployed" and not sd.failed and IsValid(sd.entity) then
            TIV.Anchor.AttachSingle(veh, data, sd, i)
        end
    end
end

-- Current break force of one stake: base x per-stake variance, decayed once
-- the failure sequence has started (data._stakeWeakenStart). The decay means
-- sustained over-threshold wind ALWAYS wins eventually -- physically, because
-- the spikes are progressively tearing loose -- and faster the harder the
-- wind blows (rate is set at failure start from the overshoot).
local function StakeCap(veh, data, stake, base)
    if base == math.huge then return math.huge end
    local cap = base * (stake.strength or 1)
    if data._stakeWeakenStart then
        local age = math.max(0, CurTime() - data._stakeWeakenStart)
        cap = cap * math.max(0.12, math.exp(-(data._stakeWeakenRate or 0.25) * age))
    end
    return cap
end

function TIV.Anchor.StakeThink(veh, data)
    local phys = veh:GetPhysicsObject()
    if not IsValid(phys) then return end
    local base  = StakeBaseCap(veh)
    local mass  = math.max(phys:GetMass(), 100)
    local now   = CurTime()
    local debug = GetConVar("tiv_debug_freeze") and GetConVar("tiv_debug_freeze"):GetBool()

    for si = #data.stakes, 1, -1 do
        local stake = data.stakes[si]
        local sd    = stake.sd
        if not sd or sd.failed or sd.phase ~= "deployed" or not IsValid(sd.entity) then
            table.remove(data.stakes, si)
        else
            local P     = veh:LocalToWorld(stake.localPos)
            local delta = P - stake.anchor
            local drift = delta:Length()
            stake.load  = 0

            -- Rest (or near-rest): the stake carries nothing. A fully
            -- anchored, calm vehicle gets zero applied force.
            if drift > 0.75 or stake.carrying then
                local v = phys:GetVelocityAtPoint(P)
                stake.carrying = drift > 0.75

                -- Stiffness: ~10 units of visible give at the break force.
                local k = base * 0.10 / math.max(1, stake.strength)
                local c = math.sqrt(k * mass) * 0.30
                local F = delta * -k - v * c

                -- One-sided: the stake only ever PULLS the mount back toward
                -- its planted spot (it is buried in the ground, not a strut
                -- from below). If the chassis is already returning on its
                -- own, let it.
                if F:Dot(-delta) > 0 then
                    local cap  = StakeCap(veh, data, stake, base)
                    local need = F:Length()
                    if need > cap then
                        stake.load = need
                        if TIV.Loft and TIV.Loft.TearSpike then
                            TIV.Loft.TearSpike(veh, data, sd)
                        end
                        if debug then
                            print(string.format("[TIV] stake %d on #%d overloaded: %.0f > cap %.0f",
                                sd.index or 0, veh:EntIndex(), need, cap))
                        end
                    else
                        stake.load = need
                        phys:ApplyForceOffset(F:GetNormalized() * need, P)

                        -- Strain feedback: creaks past 65% of the cap, sparks
                        -- past 90% -- you can hear the spikes giving before
                        -- they go.
                        if cap ~= math.huge then
                            local frac = need / cap
                            if frac > 0.65 and now > (stake.nextCreak or 0) then
                                stake.nextCreak = now + 0.5 + math.random() * 0.7
                                sd.entity:EmitSound("physics/metal/metal_box_strain" .. math.random(1, 4) .. ".wav", 75, math.random(45, 60))
                            end
                            if frac > 0.90 and now > (stake.nextSpark or 0) then
                                stake.nextSpark = now + 0.25
                                local ed = EffectData()
                                ed:SetOrigin(P)
                                ed:SetMagnitude(2)
                                ed:SetScale(1)
                                util.Effect("Sparks", ed)
                            end
                        end
                    end
                end
            end
        end
    end
end

function TIV.Anchor.ReleaseStakes(veh, data)
    if data._stakeTimer then
        timer.Remove(data._stakeTimer)
        data._stakeTimer = nil
    end
    data.stakes = nil
end

-- 0-spike mode fallback: hold the chassis to the world directly. One socket per mount
-- point (the same corners the springs pulled on), so the pose is fixed by
-- geometry exactly as it is by four planted spikes. A single centre socket
-- left the chassis free to rotate into its angular limits, and the compressed
-- suspension pushing against those limits is what shook the vehicle.
-- With no spikes there is nothing to stake, so these joints do the holding;
-- they are unbreakable unless the player sets a real tiv_spike_force.
local function WorldSocketForceLimit()
    local god = GetConVar("tiv_cheat_godmode_anchors")
    if god and god:GetBool() then return 0 end
    local cv = GetConVar("tiv_spike_force")
    local absolute = cv and cv:GetFloat() or 0
    if absolute and absolute > 0 then return absolute end
    return 0
end

function TIV.Anchor.AttachWorld(veh, data)
    if not IsValid(veh) then return end
    local world = game.GetWorld()
    if not world then return end
    local limit = GetPivotLimit()
    local created = 0
    for _, mountLocal in ipairs(MountPoints(veh, data)) do
        local bs = constraint.AdvBallsocket(
            veh, world, 0, 0,
            mountLocal, veh:LocalToWorld(mountLocal),
            WorldSocketForceLimit(), 0,
            -limit, -limit, -limit,
             limit,  limit,  limit,
            0, 0, 0,
            0, 0, 0,
            1
        )
        if IsValid(bs) then
            Track(data, bs, nil, "ballsocket", { isWorldAnchor = true, localPos = mountLocal })
            created = created + 1
        end
    end
    if created == 0 then
        print(string.format("[TIV] WARNING: world anchor failed for #%d", veh:EntIndex()))
    end
end

-- ============================================================================
-- CHASSIS PHYSICS INVARIANT
-- The chassis is always a live body. Kept under the old name because the
-- loft/wire modules call it.
-- ============================================================================
function TIV.Anchor.UnfreezeForDeploy(veh)
    if not IsValid(veh) then return end
    local phys = veh:GetPhysicsObject()
    if not IsValid(phys) then return end
    if not phys:IsGravityEnabled() then phys:EnableGravity(true) end
    if not phys:IsMotionEnabled() then phys:EnableMotion(true) end
    phys:Wake()
end
TIV.Anchor.EnsureLive = TIV.Anchor.UnfreezeForDeploy

-- ============================================================================
-- DETACH
-- ============================================================================
function TIV.Anchor.DetachAll(veh, data)
    TIV.Anchor.ReleaseStakes(veh, data)
    for _, c in ipairs(data.constraints or {}) do
        if IsValid(c.constraint) then c.constraint:Remove() end
    end
    data.constraints = {}
    data.pullDown = nil
    if IsValid(veh) then
        TIV.Anchor.UnfreezeForDeploy(veh)
    end
end

function TIV.Anchor.ForceDetach(veh, data)
    TIV.Anchor.DetachAll(veh, data)
    data.anchored = false
end

-- Removes only the hold-down constraints (ballsockets + elastics) so the
-- suspension springs back; nocollides stay until the spikes retract.
function TIV.Anchor.ReleaseHold(veh, data)
    TIV.Anchor.ReleaseLock(veh, data)
    TIV.Anchor.ReleaseSprings(veh, data)
    if IsValid(veh) then TIV.Anchor.UnfreezeForDeploy(veh) end
end

function TIV.Anchor.BreakSpike(veh, data, spikeIndex)
    if not data.constraints then return false end
    local broke = false
    for i = #data.constraints, 1, -1 do
        local c = data.constraints[i]
        if c.spikeIndex == spikeIndex and c.type ~= "nocollide" then
            if IsValid(c.constraint) then c.constraint:Remove() end
            table.remove(data.constraints, i)
            broke = true
        end
    end
    return broke
end

-- Drops every constraint record for one spike (ground weld, nocollide, and
-- any hold) so it can stroke back into its cylinder cleanly.
function TIV.Anchor.UnplantSingle(veh, data, spikeIndex)
    for i = #(data.constraints or {}), 1, -1 do
        local c = data.constraints[i]
        if c.spikeIndex == spikeIndex then
            if IsValid(c.constraint) then c.constraint:Remove() end
            table.remove(data.constraints, i)
        end
    end
end

-- ============================================================================
-- QUERIES
-- ============================================================================
function TIV.Anchor.CheckIntegrity(veh, data)
    local liveStakes = 0
    for i = #(data.stakes or {}), 1, -1 do
        local sd = data.stakes[i].sd
        if sd and not sd.failed and sd.phase == "deployed" and IsValid(sd.entity) then
            liveStakes = liveStakes + 1
        else
            table.remove(data.stakes, i)
        end
    end
    if liveStakes > 0 then return true end

    if not data.constraints then return true end
    local ballsockets = 0
    for i = #data.constraints, 1, -1 do
        local c = data.constraints[i]
        if not IsValid(c.constraint) then
            table.remove(data.constraints, i)
        elseif c.type == "ballsocket" then
            ballsockets = ballsockets + 1
        end
    end
    return ballsockets > 0
end

function TIV.Anchor.GetCounts(data)
    local counts = { total = 0, ballsockets = 0, anchors = 0, nocollide = 0, elastics = 0, stakes = 0 }
    for _, st in ipairs(data.stakes or {}) do
        local sd = st.sd
        if sd and not sd.failed and sd.phase == "deployed" and IsValid(sd.entity) then
            counts.stakes = counts.stakes + 1
            counts.total  = counts.total + 1
            counts.ballsockets = counts.ballsockets + 1 -- wire/E2 "anchor count"
        end
    end
    for _, c in ipairs(data.constraints or {}) do
        if IsValid(c.constraint) then
            counts.total = counts.total + 1
            if c.type == "ballsocket" then
                if c.isWorldAnchor then counts.anchors = counts.anchors + 1 else counts.ballsockets = counts.ballsockets + 1 end
            elseif c.type == "nocollide" then counts.nocollide = counts.nocollide + 1
            elseif c.type == "elastic" then counts.elastics = counts.elastics + 1
            end
        end
    end
    return counts
end

print("[TIV] Anchor system loaded")
