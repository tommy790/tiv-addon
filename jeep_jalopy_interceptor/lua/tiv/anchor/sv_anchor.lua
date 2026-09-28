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
--   Lock    : limited ballsockets between chassis and planted spikes hold the
--             pulled-down pose (world sockets when no spikes are fitted).
--             Springs at mounts without a spike stay on. Force limit 0 means
--             the loft system is the only thing that ever breaks them.
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

-- Drops the ballsockets only; the springs (if any) keep the body down.
function TIV.Anchor.ReleaseLock(veh, data)
    RemoveByType(data, "ballsocket")
end

-- ============================================================================
-- LOCK (limited ballsocket chassis <-> spike at the settled pose)
-- ============================================================================
function TIV.Anchor.AttachSingle(veh, data, spikeData, spikeTableIndex)
    if not IsValid(veh) or not IsValid(spikeData.entity) then return end
    spikeData.tableIndex = spikeTableIndex or spikeData.tableIndex

    local spike = spikeData.entity
    local sp = spike:GetPhysicsObject()
    if IsValid(sp) and sp:IsMotionEnabled() then
        sp:SetVelocity(vector_origin)
        sp:SetAngleVelocity(vector_origin)
        sp:EnableMotion(false)
    end

    local limit = GetPivotLimit()
    local localAttachPos = veh:WorldToLocal(spike:GetPos())
    local bs = constraint.AdvBallsocket(
        veh, spike, 0, 0,
        localAttachPos, vector_origin,
        TIV.Config.BallSocketForceLimit or 0, 0,
        -limit, -limit, -limit,
         limit,  limit,  limit,
        0, 0, 0,
        0, 0, 0,
        1
    )
    if IsValid(bs) then
        Track(data, bs, spikeData, "ballsocket", { localPos = localAttachPos })
    else
        print("[TIV] WARNING: Ballsocket failed for spike " .. tostring(spikeData.index))
    end

    local hasNoCollide = false
    for _, c in ipairs(data.constraints or {}) do
        if c.type == "nocollide" and c.spikeIndex == spikeData.index and IsValid(c.constraint) then
            hasNoCollide = true
            break
        end
    end
    if not hasNoCollide then
        local nocol = constraint.NoCollide(veh, spike, 0, 0)
        if IsValid(nocol) then Track(data, nocol, spikeData, "nocollide") end
    end
end

function TIV.Anchor.AttachAll(veh, data)
    if not IsValid(veh) then return end
    for i, sd in ipairs(data.spikes or {}) do
        if sd.phase == "deployed" and IsValid(sd.entity) then
            local has = false
            for _, c in ipairs(data.constraints or {}) do
                if c.type == "ballsocket" and c.spikeIndex == sd.index and IsValid(c.constraint) then
                    has = true
                    break
                end
            end
            if not has then TIV.Anchor.AttachSingle(veh, data, sd, i) end
        end
    end
end

-- 0-spike mode: hold the chassis to the world directly. One socket per mount
-- point (the same corners the springs pulled on), so the pose is fixed by
-- geometry exactly as it is by four planted spikes. A single centre socket
-- left the chassis free to rotate into its angular limits, and the compressed
-- suspension pushing against those limits is what shook the vehicle.
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
            TIV.Config.BallSocketForceLimit or 0, 0,
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
    local counts = { total = 0, ballsockets = 0, anchors = 0, nocollide = 0, elastics = 0 }
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
