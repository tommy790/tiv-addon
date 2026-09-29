-- ============================================================================
-- TIV ANCHOR SYSTEM
-- ============================================================================
-- Everything that physically ties the chassis to the ground lives here.
--
--   Plant    : a spike that has reached its drive depth becomes a LIVE physics
--              body -- motion on, gravity on, colliding with the terrain -- and
--              is gripped by two soft soil elastics of its own (one vertical,
--              one lateral). It is never frozen, never welded to the world, and
--              never a rigid prop: it can be dragged, it can slip, and it can
--              be torn out.
--   Hold     : one gimbaled hold per spike ties that spike to the chassis.
--              Wire Grabber weld when Wiremod is installed, limited ballsocket
--              when it is not -- whichever is available, chosen automatically.
--              Because it is a gimbal and not a weld, the spike leans as the
--              chassis tilts instead of dragging the chassis flat.
--   Pull-down: elastic constraints from every layout mount to a point below the
--              ground under it are shortened over LowerTime. The chassis is
--              pulled down onto its own suspension by real constraint force.
--
-- There is no single constraint holding the vehicle down. Six spikes means six
-- independent anchors, each with its own soil grip, its own hold, its own load
-- and its own moment of letting go. That is what makes the rear lift while the
-- front stays planted.
--
-- The chassis physics object is never frozen, never teleported and keeps its
-- gravity throughout. Nothing in here calls SetPos/SetAngles on the vehicle.
-- ============================================================================

TIV.Anchor = TIV.Anchor or {}

-- Reuses the message cl_instruments already listens for (sound + HUD anchor-fail
-- marker), so a spike losing the ground is visible to the driver. Declared here
-- as well as in sv_loft because this file loads first.
util.AddNetworkString("TIV_AnchorWarning")

-- ============================================================================
-- CONSTRAINT RECORDS
-- ============================================================================
-- Every constraint this system creates is recorded here so it can be found,
-- re-cut or removed by type. Kinds:
--   "ballsocket"   chassis<->spike gimbal, or chassis<->world anchor
--   "grabber"      Wire Grabber weld to the spike (its Weld constraint)
--   "grabbermount" unbreakable weld holding the grabber body to the chassis
--   "embed"        soil elastic holding one spike in the ground
--   "nocollide"    collision pair suppression
--   "elastic"      airbag pull-down spring
local function Track(data, con, spikeData, kind, extra)
    data.constraints = data.constraints or {}
    local rec = {
        constraint      = con,
        spikeIndex      = spikeData and spikeData.index or 0,
        spikeTableIndex = spikeData and spikeData.tableIndex,
        type            = kind,
        forcelimit      = nil,
        torquelimit     = nil,
        stressed        = false,
    }
    if extra then
        for k, v in pairs(extra) do rec[k] = v end
    end
    data.constraints[#data.constraints + 1] = rec
    return rec
end

local function Untrack(data, rec)
    if not data.constraints or not rec then return end
    for i = #data.constraints, 1, -1 do
        if data.constraints[i] == rec then
            table.remove(data.constraints, i)
            return
        end
    end
end

local function VehicleMass(veh)
    local phys = veh:GetPhysicsObject()
    return IsValid(phys) and math.max(phys:GetMass(), 100) or 800
end

-- Every hold in this system is cut through here, so the flag set cannot drift
-- between the first cut, the stressed re-cut and the world anchors.
--
-- onlyRotation is deliberately 0. It means "only limit rotation, free
-- movement": with it set the constraint pins nothing positionally, so a live
-- spike is held by its soil springs alone -- it slides out of the ground and
-- swings on the end of the gimbal. Positional pinning is what makes the spike
-- behave like a ram bolted to the chassis, and the gimbal's friction is what
-- stops it oscillating inside its cone afterwards.
local function CutHoldSocket(veh, ent2, localPos, forceLimit, torqueLimit)
    local limit    = math.Clamp(TIV.AnchorSetting("SpikePivotLimit", 10), 1, 60)
    local friction = math.max(0, TIV.AnchorSetting("SpikePivotFriction", 40))
    return constraint.AdvBallsocket(
        veh, ent2, 0, 0,
        localPos, vector_origin,
        forceLimit, torqueLimit,
        -limit, -limit, -limit,
         limit,  limit,  limit,
        friction, friction, friction,
        0,      -- onlyRotation: 0 = pin position, 1 = free movement
        0       -- noCollide: this system keeps its own explicit pairs
    )
end

-- The force/torque limits of a Source constraint are read once, at Spawn, from
-- the entity's keyvalues -- they are not live Lua fields. The only way to give
-- an existing hold a new break number is to cut a new one. This does that in a
-- single frame: the replacement is created first and the old one removed
-- second, so there is never a physics tick without a hold on the spike.
--
-- The anchor point is re-derived from where the two bodies actually are right
-- now, not from where they were when the original was cut. Re-using the stored
-- local position would snap the spike back to the chassis the instant the hold
-- was re-cut -- precisely the kind of teleport this system must not do.
-- Returns true when the hold was re-cut, false when it could not be, and nil
-- when it was already cut at that number and was left alone. Callers use the
-- distinction so "already right" is never counted as a change or as a failure.
local function RecutHold(veh, data, rec, forceLimit, torqueLimit)
    if not IsValid(rec.constraint) then return false end
    -- Already cut at this number: leave it alone. Re-cutting is not free.
    if rec.forcelimit == forceLimit then return nil end

    local ent2 = rec.ent2 or rec.constraint.Ent2
    if not ent2 or not IsValid(ent2) then return false end

    if rec.type == "ballsocket" then
        local localPos
        if ent2:IsWorld() then
            localPos = rec.localPos or vector_origin
        else
            localPos = veh:WorldToLocal(ent2:GetPos())
        end

        local replacement = CutHoldSocket(veh, ent2, localPos, forceLimit, torqueLimit)
        if not IsValid(replacement) then return false end

        local old = rec.constraint
        rec.constraint  = replacement
        rec.localPos    = localPos
        rec.forcelimit  = forceLimit
        rec.torquelimit = torqueLimit
        rec.stressed    = forceLimit > 0
        old:Remove()

        -- Removing a constraint re-enables collisions between its two bodies,
        -- and this one carried the nocollide spawnflag. Put the explicit pair
        -- back in the same frame so the spike cannot start shoving the chassis.
        if not ent2:IsWorld() and ent2.IsTIVSpike then
            constraint.NoCollide(veh, ent2, 0, 0)
        end
        return true
    end

    if rec.type == "grabber" then
        if not (TIV.WireAnchor and TIV.WireAnchor.Regrab(rec.grabber, forceLimit)) then return false end
        rec.constraint  = rec.grabber.Weld
        rec.forcelimit  = forceLimit
        rec.torquelimit = 0
        rec.stressed    = forceLimit > 0
        return IsValid(rec.constraint)
    end

    return false
end

--- Raises every hold on this vehicle to the stressed force limit.
-- This is the whole "do not remove the constraints" requirement: the anchors
-- stay physically attached and keep resisting, they simply stop being
-- unbreakable. Physics then decides which one loses, and when.
function TIV.Anchor.StressAll(veh, data)
    if not IsValid(veh) or not data.constraints then return 0 end

    local force  = TIV.AnchorHoldForce(true)
    local torque = TIV.AnchorHoldTorque(true)
    local done, failed, already = 0, 0, 0

    for _, rec in ipairs(data.constraints) do
        -- The airbag springs and the grabber mounts are not the anchors; they
        -- are not what the storm is fighting and they stay unbreakable.
        if rec.type == "ballsocket" or rec.type == "grabber" then
            if IsValid(rec.constraint) then
                local r = RecutHold(veh, data, rec, force, torque)
                if r == true then done = done + 1
                elseif r == false then failed = failed + 1
                else already = already + 1 end
            end
        end
    end

    data.anchorStressed = (done + already) > 0
    if done > 0 then
        print(string.format("[TIV] #%d anchors re-cut at %.0f N (%d hold(s)%s) -- they now resist but can lose",
            veh:EntIndex(), force, done, failed > 0 and string.format(", %d failed", failed) or ""))
    end
    -- Only the number actually changed, so a second call is a quiet no-op
    -- rather than churning every constraint again and re-logging.
    return done
end

--- Back to the unbreakable hold force (wind dropped off again). World anchors
-- are skipped: with no spikes in the ground they are the only thing holding the
-- chassis and they must stay breakable or the vehicle could never be lofted.
function TIV.Anchor.UnstressAll(veh, data)
    if not IsValid(veh) or not data.constraints then return 0 end
    local force  = TIV.AnchorHoldForce(false)
    local torque = TIV.AnchorHoldTorque(false)
    local done = 0
    for _, rec in ipairs(data.constraints) do
        if (rec.type == "ballsocket" or rec.type == "grabber") and not rec.keepStressed and IsValid(rec.constraint) then
            if RecutHold(veh, data, rec, force, torque) then done = done + 1 end
        end
    end
    if done > 0 then
        data.anchorStressed = nil
        print(string.format("[TIV] #%d wind dropped: %d anchor hold(s) back to the unbreakable limit", veh:EntIndex(), done))
    end
    return done
end

function TIV.Anchor.IsStressed(data)
    return data ~= nil and data.anchorStressed == true
end

-- ============================================================================
-- PLANT (spike becomes a live body gripped by its own soil anchors)
-- ============================================================================
local function CreateEmbeds(veh, data, spikeData, spike)
    local cfg       = TIV.Config.Anchor
    local ang       = spike:GetAngles()
    local ramDir    = ang:Forward()      -- world; points down the shaft into the ground
    local right     = ang:Right()
    local spikePos  = spike:GetPos()

    -- The soil grips a LENGTH of buried shaft, not a single point, and that is
    -- not a nicety -- it is the whole reason the anchors hold.
    --
    -- A force applied exactly at a ball-and-socket pivot has no lever arm about
    -- that pivot, so it cannot produce any moment. Both springs used to attach
    -- at the spike's origin, which is the very point the chassis hold pins, so
    -- however stiff the soil was it could never resist the spike ROTATING: it
    -- only ever loaded the hold. The spike was then free to twist and lean in
    -- its hole with nothing to bring it back, which is what "bent and rotated"
    -- was.
    --
    -- Spread along the shaft instead, the grips act at different radii from
    -- the pivot and so produce a real restoring moment.
    --
    -- Every grip sits BELOW the origin, so the set stays buried even at the
    -- shallowest drive depth and stays clear of the pivot.
    local lateral = cfg.LateralEmbedOffset or 9

    -- Grip geometry comes from the ground pierce system when it is loaded, so
    -- the interceptor's spikes and any other pierced prop share one definition
    -- of "how the soil holds a shaft" and can never drift apart. Everything
    -- downstream of this stays exactly as it was: the springs are tracked in
    -- data.constraints, and the load measurement and tear-out in
    -- UpdateSpikeLoad are unchanged. TIV.Anchor keeps ownership -- it does not
    -- register the spikes with TIV.Ground, so nothing measures them twice.
    --
    -- With UseForSpikes off, the original two-point geometry below is used.
    local grips
    if TIV.Ground and TIV.Ground.GripPoints and tobool(TIV.GroundSetting("UseForSpikes", 1)) then
        local span = math.max(2, tonumber(cfg.SoilGripLength or 14) or 14)
        grips = TIV.Ground.GripPoints(spike, {
            axis      = ramDir,
            lateral   = lateral,
            firstGrip = math.max(1, tonumber(cfg.SoilAnchorDepth or 5) or 5),
            -- Half the old span between grips, so a 3-grip set covers the same
            -- buried length the 2-grip set did, with one more in the middle.
            spacing   = math.max(1, span * 0.5),
        })
    end

    if not grips or #grips == 0 then
        local grip = math.max(2, tonumber(cfg.SoilGripLength or 14) or 14)
        local top  = math.max(1, tonumber(cfg.SoilAnchorDepth or 5) or 5)
        grips = {
            { depth = top,         localPos = Vector(top,        0, 0), point = spikePos + ramDir *  top         - right * lateral },
            { depth = top + grip,  localPos = Vector(top + grip, 0, 0), point = spikePos + ramDir * (top + grip) + right * lateral },
        }
    end

    local world = game.GetWorld()

    local constant = math.max(200, tonumber(cfg.EmbedConstant or 6000) or 6000)
    local damping  = math.max(10, tonumber(cfg.EmbedDamping or 400) or 400)

    spikeData.embedConstant = constant
    -- Deepest and shallowest grip, straight off whatever geometry was chosen,
    -- so the bookkeeping cannot disagree with it.
    spikeData.anchorDepth = grips[#grips] and grips[#grips].depth or 0
    spikeData.gripCount   = #grips

    local made = 0
    for _, g in ipairs(grips) do
        -- stretchonly: soil grips, it does not push. Each spring is exactly at
        -- its rest length at plant time, so it develops tension only as the
        -- spike is dragged or twisted away from its hole -- and never shoves
        -- the spike deeper in when the chassis drops onto it.
        local el = constraint.Elastic(spike, world, 0, 0, g.localPos, g.point,
            constant, damping, 0, "", 0, true)
        if IsValid(el) then
            Track(data, el, spikeData, "embed", { embedPos = g.point })
            made = made + 1
        end
    end

    if made == 0 then
        print(string.format("[TIV] #%d spike %d: soil anchors failed to create", veh:EntIndex(), spikeData.index))
    end
    return made
end

function TIV.Anchor.PlantSingle(veh, data, spikeData)
    if not IsValid(veh) or not IsValid(spikeData.entity) then return end
    local spike = spikeData.entity
    local pos, ang = spike:GetPos(), spike:GetAngles()

    -- The spike stays exactly where the hydraulic stroke put it: no reposition,
    -- no snap, and the visual pose the driver just watched is the pose the
    -- physics now takes over. It is already driven below the surface, so it is
    -- genuinely in contact with the terrain it is planted in.
    if IsValid(spike:GetParent()) then
        spike:SetParent(nil)
    end
    spike:SetMoveType(MOVETYPE_VPHYSICS)
    spike:SetCollisionGroup(COLLISION_GROUP_NONE)

    local sp = spike:GetPhysicsObject()
    if IsValid(sp) then
        sp:SetPos(pos)
        sp:SetAngles(ang)
        sp:SetVelocity(vector_origin)
        sp:SetAngleVelocity(vector_origin)
        sp:SetMass(math.max(15, TIV.AnchorSetting("SpikeMass", 40)))
        sp:EnableGravity(true)
        -- Held frozen at the planted pose until its hold is cut. Spikes plant
        -- one at a time (staggered by group) but the holds are all cut together
        -- once the last one is home, so a spike released here would be a live
        -- body with nothing positional holding it for a quarter of a second --
        -- long enough to drop out of the ground and be captured in the wrong
        -- place. AttachSingle lets it go the instant it is actually held.
        --
        -- It is never welded to the world: that is the "rigid world-locked
        -- prop" behaviour this system replaces.
        sp:EnableMotion(false)
        spikeData.pendingMotion = true
    end

    -- The spike passes through its own vehicle's hull on the way down; without
    -- this the two would shove each other on every stroke.
    if not constraint.Find(veh, spike, "NoCollide", 0, 0) then
        local nocol = constraint.NoCollide(veh, spike, 0, 0)
        if IsValid(nocol) then Track(data, nocol, spikeData, "nocollide") end
    end
    -- And it must never become a club for whoever is standing next to it.
    for _, ply in ipairs(player.GetAll()) do
        if not constraint.Find(spike, ply, "NoCollide", 0, 0) then
            constraint.NoCollide(spike, ply, 0, 0)
        end
    end

    spikeData.plantedPos  = pos
    spikeData.plantedAng  = ang
    spikeData.ramDir      = ang:Forward()
    spikeData.plantedAt   = CurTime()
    spikeData.slipped     = nil
    spikeData.slipNoticed = nil
    spikeData.pullDist    = 0
    spikeData.slipDist    = 0
    spikeData.load        = 0
    spikeData.phase       = "deployed"

    CreateEmbeds(veh, data, spikeData, spike)
end

-- ============================================================================
-- PULL-DOWN (airbag elastics chassis -> ground)
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
-- pinned afterwards.
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

-- Ground surface at a mount's x/y.
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

local RemoveByType

function TIV.Anchor.StartPullDown(veh, data, lowerAmount)
    if not IsValid(veh) then return 0 end
    RemoveByType(data, "elastic")
    local world = game.GetWorld()
    if not world then return 0 end
    lowerAmount = lowerAmount or 0

    local mounts = MountPoints(veh, data)
    local filter = GroundTraceFilter(veh, data)
    local mass = VehicleMass(veh)
    local overshoot = 12

    local anchorDepth = lowerAmount + overshoot + 8

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

function TIV.Anchor.ReleaseSprings(veh, data)
    RemoveByType(data, "elastic")
    data.pullDown = nil
end

-- Drops the soil anchors of one spike only. This is what "a spike loses ground
-- contact" physically is: its own two springs let go and nothing else about the
-- vehicle changes.
function TIV.Anchor.ReleaseEmbeds(veh, data, spikeIndex)
    local removed = 0
    for i = #(data.constraints or {}), 1, -1 do
        local c = data.constraints[i]
        if c.type == "embed" and c.spikeIndex == spikeIndex then
            if IsValid(c.constraint) then c.constraint:Remove() end
            table.remove(data.constraints, i)
            removed = removed + 1
        end
    end
    return removed
end

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

-- Drops the holds only; the springs (if any) keep the body down.
function TIV.Anchor.ReleaseLock(veh, data)
    RemoveByType(data, "ballsocket")
    RemoveByType(data, "grabber")
    RemoveByType(data, "embed")
    data.anchorStressed = nil
end

-- ============================================================================
-- HOLD (one gimbaled anchor per spike: Wire Grabber, or ballsocket)
-- ============================================================================
local function AttachWithGrabber(veh, data, spikeData, spikeTableIndex)
    local spike = spikeData.entity
    local grabber, mount, nocollide = TIV.WireAnchor.CreateGrabber(veh, data, spikeData)
    if not IsValid(grabber) then return false end

    local force = TIV.AnchorHoldForce(data.anchorStressed == true)
    if not TIV.WireAnchor.Grab(grabber, force) then
        print(string.format("[TIV] #%d grabber %d failed to grab its spike, falling back to a ballsocket",
            veh:EntIndex(), spikeData.index))
        TIV.WireAnchor.Remove(grabber)
        if IsValid(mount) then mount:Remove() end
        if IsValid(nocollide) then nocollide:Remove() end
        return false
    end

    spikeData.tableIndex = spikeTableIndex or spikeData.tableIndex
    if IsValid(mount) then
        Track(data, mount, spikeData, "grabbermount", { grabber = grabber, forcelimit = 0 })
    end
    if IsValid(nocollide) then
        Track(data, nocollide, spikeData, "nocollide")
    end
    Track(data, grabber.Weld, spikeData, "grabber", {
        ent2        = spike,
        grabber     = grabber,
        forcelimit  = force,
        torquelimit = 0,
        stressed    = force > 0,
    })
    spikeData.grabber = grabber
    return true
end

local function AttachWithBallsocket(veh, data, spikeData, spikeTableIndex)
    local spike = spikeData.entity
    local sp = spike:GetPhysicsObject()

    -- Zero the spike's motion at the instant the hold is cut so the gimbal is
    -- captured at rest rather than mid-swing.
    if IsValid(sp) then
        sp:SetVelocity(vector_origin)
        sp:SetAngleVelocity(vector_origin)
    end

    local force = TIV.AnchorHoldForce(data.anchorStressed == true)
    local torque = TIV.AnchorHoldTorque(data.anchorStressed == true)
    local localAttachPos = veh:WorldToLocal(spike:GetPos())

    local bs = CutHoldSocket(veh, spike, localAttachPos, force, torque)
    if not IsValid(bs) then
        print("[TIV] WARNING: Ballsocket failed for spike " .. tostring(spikeData.index))
        return false
    end

    spikeData.tableIndex = spikeTableIndex or spikeData.tableIndex
    Track(data, bs, spikeData, "ballsocket", {
        ent2        = spike,
        localPos    = localAttachPos,
        localPos2   = vector_origin,
        forcelimit  = force,
        torquelimit = torque,
        stressed    = force > 0,
    })

    if not constraint.Find(veh, spike, "NoCollide", 0, 0) then
        local nocol = constraint.NoCollide(veh, spike, 0, 0)
        if IsValid(nocol) then Track(data, nocol, spikeData, "nocollide") end
    end
    return true
end

-- Lets a planted spike become a live body. Called the moment its hold exists,
-- never before: from here on the spike is held positionally by the chassis and
-- by its own soil anchors, so it can move, tilt and be dragged out -- but it
-- cannot simply fall out of the ground while nothing is holding it.
local function ReleaseSpikeMotion(spikeData)
    if not spikeData or not spikeData.pendingMotion then return end
    spikeData.pendingMotion = nil
    local spike = spikeData.entity
    if not IsValid(spike) then return end
    local sp = spike:GetPhysicsObject()
    if not IsValid(sp) then return end
    sp:SetVelocity(vector_origin)
    sp:SetAngleVelocity(vector_origin)
    sp:EnableMotion(true)
    sp:Wake()
end

function TIV.Anchor.AttachSingle(veh, data, spikeData, spikeTableIndex)
    if not IsValid(veh) or not IsValid(spikeData.entity) then return end

    -- Whichever anchoring method is available, automatically. Wiremod present
    -- and grabbers enabled: the spike hold is a Wire Grabber weld. Otherwise
    -- (or if the grab refused) the ballsocket hold does exactly the same job.
    local held
    if TIV.WireAnchor and TIV.WireAnchor.IsAvailable() then
        held = AttachWithGrabber(veh, data, spikeData, spikeTableIndex)
    end
    if not held then
        held = AttachWithBallsocket(veh, data, spikeData, spikeTableIndex)
    end
    if held then ReleaseSpikeMotion(spikeData) end
end

local function HasHold(data, spikeIndex)
    for _, c in ipairs(data.constraints or {}) do
        if c.spikeIndex == spikeIndex and (c.type == "ballsocket" or c.type == "grabber") and IsValid(c.constraint) then
            return true
        end
    end
    return false
end
TIV.Anchor.HasHold = HasHold

function TIV.Anchor.AttachAll(veh, data)
    if not IsValid(veh) then return end
    for i, sd in ipairs(data.spikes or {}) do
        if sd.phase == "deployed" and IsValid(sd.entity) then
            if not HasHold(data, sd.index) then
                TIV.Anchor.AttachSingle(veh, data, sd, i)
            end
        end
    end
end

-- 0-spike mode: hold the chassis to the world directly. One socket per mount
-- point (the same corners the springs pulled on). With no spikes there are no
-- soil anchors to lose, so these are cut at the stressed limit straight away:
-- a chassis with nothing in the ground has to be able to be lifted.
function TIV.Anchor.AttachWorld(veh, data)
    if not IsValid(veh) then return end
    local world = game.GetWorld()
    if not world then return end
    local force = TIV.AnchorHoldForce(true)
    local torque = TIV.AnchorHoldTorque(true)
    local created = 0
    for _, mountLocal in ipairs(MountPoints(veh, data)) do
        local bs = CutHoldSocket(veh, world, mountLocal, force, torque)
        if IsValid(bs) then
            Track(data, bs, nil, "ballsocket", {
                isWorldAnchor = true,
                ent2          = world,
                localPos      = mountLocal,
                localPos2     = veh:LocalToWorld(mountLocal),
                forcelimit    = force,
                torquelimit   = torque,
                stressed      = force > 0,
                -- With no spikes in the ground these are the only anchors, and
                -- they must stay breakable for the vehicle to ever be lofted.
                keepStressed  = true,
            })
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
-- PER-SPIKE GROUND CONTACT
-- ============================================================================
-- Each spike carries its own measurement of how hard the ground is holding it.
-- pullDist is how far it has been dragged out along its own ram axis, slipDist
-- how far sideways, load a 0..1 estimate of the force in its soil springs
-- against the current break number. All three come from where the spike
-- actually is -- nothing is scripted.
function TIV.Anchor.UpdateSpikeLoad(veh, data, sd)
    if not sd or not IsValid(sd.entity) then return end
    -- "deployed" is a spike still gripping the soil; "slipping" is the same
    -- spike one think later, after it reported strain. Both still have to be
    -- measured, or a spike that complained once would have its load zeroed on
    -- the next tick and could never reach the point where it lets go -- it
    -- would just strain forever while its hole stopped holding it.
    if (sd.phase ~= "deployed" and sd.phase ~= "slipping") or not sd.plantedPos then
        sd.pullDist, sd.slipDist, sd.load = 0, 0, 0
        return
    end

    local ramDir = sd.ramDir or veh:GetAngles():Forward()
    local delta  = sd.entity:GetPos() - sd.plantedPos
    -- ramDir points DOWN into the ground, so a spike dragged UP out of its hole
    -- moves against it: the pull is the component along -ramDir.
    local along  = delta:Dot(ramDir)
    local lateral = delta - ramDir * along

    sd.pullDist = math.max(0, -along)
    sd.slipDist = lateral:Length()

    local pullOut = math.max(1, tonumber(TIV.AnchorSetting("PullOutDistance", 11)) or 11)
    local slipOut = math.max(1, tonumber(TIV.AnchorSetting("SlipOutDistance", 15)) or 15)
    local force   = (sd.embedConstant or 6000) * math.max(sd.pullDist, sd.slipDist)
    local limit   = TIV.AnchorHoldForce(data.anchorStressed == true)

    sd.load = math.Clamp(math.max(sd.pullDist / pullOut, sd.slipDist / slipOut), 0, 1)
    sd.anchorForce = force
    sd.overLimit   = limit > 0 and force > limit

    -- A spike that has been dragged past what its hole can grip has lost the
    -- ground. Only its own soil springs go; the hold to the chassis stays, so
    -- the piston comes out of the earth and rides with the vehicle while the
    -- spikes that still have grip keep their end of the vehicle down.
    --
    -- Two guards keep a legitimate plant from reading as a tear-out: the body
    -- has to have settled first (a spike that has just been driven in is still
    -- absorbing the impact), and while nothing is stressing the anchors the
    -- hole gets more slack -- a calm vehicle does not lose its spikes just
    -- because the solver nudged one a couple of units.
    local settle = math.max(0, tonumber(TIV.AnchorSetting("SettleTime", 0.75)) or 0)
    if sd.plantedAt and CurTime() - sd.plantedAt < settle then return end

    local slack = 1
    if not data.anchorStressed then
        slack = math.max(1, tonumber(TIV.AnchorSetting("CalmSlack", 2.5)) or 1)
    end

    if sd.pullDist >= pullOut * slack or sd.slipDist >= slipOut * slack then
        -- The godmode cheat promises the spikes never break. The load is still
        -- measured and reported, so the readouts stay honest; only the letting
        -- go is suppressed.
        local godmode = GetConVar("tiv_cheat_godmode_anchors")
        if not (godmode and godmode:GetBool()) then
            TIV.Anchor.TearOutSpike(veh, data, sd)
            return
        end
    end
    if not sd.slipNoticed and sd.load >= (tonumber(TIV.AnchorSetting("OverloadFraction", 0.7)) or 0.7) then
        sd.slipNoticed = true
        sd.phase = "slipping"
        if data.spikeAnims then data.spikeAnims[sd.index] = "slipping" end
        if IsValid(sd.entity) then
            sd.entity:EmitSound("physics/metal/metal_box_strain" .. math.random(1, 4) .. ".wav", 62, math.random(55, 75))
        end
    end
end

function TIV.Anchor.TearOutSpike(veh, data, sd)
    if not sd or sd.slipped then return end
    sd.slipped    = true
    sd.failed     = true
    sd.load       = 1
    sd.phase      = "slipped"
    if data and data.spikeAnims then data.spikeAnims[sd.index] = "slipped" end

    TIV.Anchor.ReleaseEmbeds(veh, data, sd.index)

    local spike = sd.entity
    if IsValid(spike) then
        local spark = EffectData()
        spark:SetOrigin(spike:GetPos())
        spark:SetMagnitude(6)
        spark:SetScale(2.5)
        util.Effect("Sparks", spark)
        spike:EmitSound("physics/concrete/gravel_impact_bullet" .. math.random(1, 4) .. ".wav", 78, math.random(70, 90))
    end

    if IsValid(veh) then
        util.ScreenShake(veh:GetPos(), 2.5, 12, 0.3, 260)
        net.Start("TIV_AnchorWarning")
            net.WriteEntity(veh)
            net.WriteUInt(sd.index or 0, 8)
        net.Broadcast()
        hook.Run("TIV_SpikeFailure", veh, sd.index)
    end

    print(string.format("[TIV] #%d spike %d lost ground contact (pull %.1f u, slip %.1f u) -- %d anchor(s) still holding",
        IsValid(veh) and veh:EntIndex() or 0, sd.index or 0,
        sd.pullDist or 0, sd.slipDist or 0, TIV.Anchor.LiveAnchorCount(data)))
end

--- Measures every planted spike and returns the anchor tally the loft system
-- drives itself from.
function TIV.Anchor.UpdateAnchors(veh, data)
    local report = { planted = 0, holding = 0, slipped = 0, worst = 0, worstIndex = 0, overloaded = 0 }
    if not IsValid(veh) or not data then return report end

    for _, sd in ipairs(data.spikes or {}) do
        if IsValid(sd.entity) and (sd.phase == "deployed" or sd.phase == "slipping") then
            TIV.Anchor.UpdateSpikeLoad(veh, data, sd)
            report.planted = report.planted + 1
            if sd.slipped then
                report.slipped = report.slipped + 1
            else
                report.holding = report.holding + 1
                if (sd.load or 0) > report.worst then
                    report.worst = sd.load
                    report.worstIndex = sd.index
                end
                if (sd.load or 0) >= (tonumber(TIV.AnchorSetting("OverloadFraction", 0.7)) or 0.7) then
                    report.overloaded = report.overloaded + 1
                end
            end
        end
    end
    data.anchorReport = report
    return report
end

function TIV.Anchor.LiveAnchorCount(data)
    local n = 0
    for _, c in ipairs((data and data.constraints) or {}) do
        if (c.type == "ballsocket" or c.type == "grabber" or c.type == "embed") and IsValid(c.constraint) then
            n = n + 1
        end
    end
    return n
end

--- Counts only the constraints that actually reach the GROUND: a spike's soil
-- elastics, or a chassis<->world anchor.
--
-- This is the number that decides whether the vehicle is still tied down, and
-- it is deliberately NOT the same as LiveAnchorCount. A chassis<->spike hold
-- whose spike has been dragged out of the earth is still a perfectly healthy
-- constraint -- it is just holding the vehicle to a loose piece of metal. Once
-- every spike has lost the ground, those holds are dead weight and the vehicle
-- is free, however many constraints are still on the list.
function TIV.Anchor.LiveGroundAnchorCount(data)
    if not data then return 0 end
    local n = 0
    for _, c in ipairs(data.constraints or {}) do
        if IsValid(c.constraint) then
            if c.type == "ballsocket" and c.isWorldAnchor then
                n = n + 1
            elseif c.type == "embed" then
                -- A soil grip only anchors THIS vehicle while the spike carrying
                -- it is still held by the chassis. Once the hold has let go the
                -- spike is a spike standing in the ground next to the vehicle,
                -- not an anchor, and counting it would keep the loft failsafe
                -- quiet while the vehicle was already free -- which is exactly
                -- how a TIV ends up riding out wind its anchors were never
                -- rated for.
                if (c.spikeIndex or 0) > 0 and HasHold(data, c.spikeIndex) then
                    n = n + 1
                end
            end
        end
    end
    return n
end

-- The force the storm has to beat to separate the vehicle from its own anchors:
-- the summed force limit of every live chassis hold, at whatever rating those
-- holds are currently cut at. The filter deliberately mirrors StressAll's, so
-- this number is exactly what the wind is fighting and nothing else.
--
-- The soil springs are NOT part of it. constraint.Elastic takes no force limit
-- at all -- a spike's grip on the ground is measured in distance travelled
-- (PullOutDistance), not in force -- so folding EmbedConstant in here would
-- invent a resistance that does not exist.
--
-- Returns the total and the hold count, because the debug report wants both.
function TIV.Anchor.TotalHoldForce(data)
    if not data or not data.constraints then return 0, 0 end

    local force = TIV.AnchorHoldForce(data.anchorStressed == true)
    if force <= 0 then
        -- Unstressed holds are unbreakable, so at any wind speed they are not
        -- the thing that gives. Report the stressed rating rather than 0, so
        -- that a caller asking "what would this take" gets a real answer
        -- instead of a division by zero.
        force = TIV.AnchorHoldForce(true)
    end

    local n = 0
    for _, c in ipairs(data.constraints) do
        if (c.type == "ballsocket" or c.type == "grabber") and IsValid(c.constraint) then
            n = n + 1
        end
    end
    return force * n, n
end

-- ============================================================================
-- DETACH
-- ============================================================================
function TIV.Anchor.DetachAll(veh, data)
    for _, c in ipairs(data.constraints or {}) do
        if IsValid(c.constraint) then c.constraint:Remove() end
    end
    data.constraints  = {}
    data.pullDown     = nil
    data.anchorStressed = nil

    -- The grabber bodies belong to this anchoring set and go with it.
    for _, sd in ipairs(data.spikes or {}) do
        if sd.grabber then
            TIV.WireAnchor.Remove(sd.grabber)
            sd.grabber = nil
        end
    end

    if IsValid(veh) then
        TIV.Anchor.UnfreezeForDeploy(veh)
    end
end

function TIV.Anchor.ForceDetach(veh, data)
    TIV.Anchor.DetachAll(veh, data)
    data.anchored = false
end

-- Removes only the hold-down constraints (holds + soil + airbag springs) so
-- the suspension springs back; nocollides stay until the spikes retract.
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
    if broke and TIV.WireAnchor then
        for _, sd in ipairs(data.spikes or {}) do
            if sd.index == spikeIndex and sd.grabber then
                TIV.WireAnchor.Remove(sd.grabber)
                sd.grabber = nil
            end
        end
    end
    return broke
end

-- Drops every constraint record for one spike (hold, soil anchors, nocollide)
-- and the grabber body, so it can stroke back into its cylinder cleanly.
function TIV.Anchor.UnplantSingle(veh, data, spikeIndex)
    for i = #(data.constraints or {}), 1, -1 do
        local c = data.constraints[i]
        if c.spikeIndex == spikeIndex then
            if IsValid(c.constraint) then c.constraint:Remove() end
            table.remove(data.constraints, i)
        end
    end
    if TIV.WireAnchor then
        for _, sd in ipairs(data.spikes or {}) do
            if sd.index == spikeIndex and sd.grabber then
                TIV.WireAnchor.Remove(sd.grabber)
                sd.grabber = nil
            end
        end
    end
    for _, sd in ipairs(data.spikes or {}) do
        if sd.index == spikeIndex then
            sd.slipped       = nil
            sd.slipNoticed   = nil
            sd.plantedPos    = nil
            sd.pendingMotion = nil
            sd.pullDist      = 0
            sd.slipDist      = 0
            sd.load          = 0
        end
    end
end

-- ============================================================================
-- QUERIES
-- ============================================================================
-- "Intact" means the vehicle is still tied to the GROUND, so this counts soil
-- anchors and world anchors rather than every hold: a hold on a spike that has
-- come out of the earth is intact as a constraint and useless as an anchor.
function TIV.Anchor.CheckIntegrity(veh, data)
    if not data.constraints then return true end
    local ground = 0
    for i = #data.constraints, 1, -1 do
        local c = data.constraints[i]
        if not IsValid(c.constraint) then
            table.remove(data.constraints, i)
        elseif c.type == "embed" or (c.type == "ballsocket" and c.isWorldAnchor) then
            ground = ground + 1
        end
    end
    return ground > 0
end

-- counts.ballsockets is the "how many anchors are down" number the wire
-- controller and the HUD already read, so grabber holds are counted there too.
function TIV.Anchor.GetCounts(data)
    local counts = {
        total = 0, ballsockets = 0, anchors = 0, nocollide = 0, elastics = 0,
        grabbers = 0, embeds = 0, holds = 0,
    }
    for _, c in ipairs(data.constraints or {}) do
        if IsValid(c.constraint) then
            counts.total = counts.total + 1
            if c.type == "ballsocket" then
                if c.isWorldAnchor then
                    counts.anchors = counts.anchors + 1
                else
                    counts.ballsockets = counts.ballsockets + 1
                end
                counts.holds = counts.holds + 1
            elseif c.type == "grabber" then
                counts.grabbers = counts.grabbers + 1
                counts.ballsockets = counts.ballsockets + 1
                counts.holds = counts.holds + 1
            elseif c.type == "embed" then counts.embeds = counts.embeds + 1
            elseif c.type == "nocollide" then counts.nocollide = counts.nocollide + 1
            elseif c.type == "elastic" then counts.elastics = counts.elastics + 1
            end
        end
    end
    return counts
end

--- One line per spike, for the audit and tiv_spike_debug.
function TIV.Anchor.ReportLines(veh, data)
    local lines = {}
    if not data then return lines end
    local counts = TIV.Anchor.GetCounts(data)
    lines[#lines + 1] = string.format(
        "  Anchors: mode=%s stressed=%s holds=%d (ballsocket %d / grabber %d / world %d) soil=%d force=%.0f N",
        TIV.WireAnchor and TIV.WireAnchor.Describe() or "ballsocket",
        tostring(data.anchorStressed == true), counts.holds, counts.ballsockets,
        counts.grabbers, counts.anchors, counts.embeds,
        TIV.AnchorHoldForce(data.anchorStressed == true))

    for _, sd in ipairs(data.spikes or {}) do
        if IsValid(sd.entity) then
            local hold = HasHold(data, sd.index) and "hold" or "NO-HOLD"
            local soil = 0
            for _, c in ipairs(data.constraints or {}) do
                if c.type == "embed" and c.spikeIndex == sd.index and IsValid(c.constraint) then soil = soil + 1 end
            end
            lines[#lines + 1] = string.format(
                "  Spike #%-2d %-12s %-9s [%s] soil=%d pull=%5.1fu slip=%5.1fu load=%3.0f%%%s",
                sd.index or 0, tostring(sd.name or "?"), tostring(sd.phase), hold, soil,
                sd.pullDist or 0, sd.slipDist or 0, (sd.load or 0) * 100,
                sd.overLimit and "  OVERLOADED" or "")
        end
    end
    return lines
end

print("[TIV] Anchor system loaded")
