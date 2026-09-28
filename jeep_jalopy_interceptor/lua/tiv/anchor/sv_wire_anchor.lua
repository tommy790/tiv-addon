-- ============================================================================
-- TIV WIRE GRABBER ANCHORS (server)
-- ============================================================================
-- The alternative hold for a planted spike. Instead of a ballsocket welded
-- straight to the spike, a Wire Grabber is bolted to the chassis under each
-- mount and told to grab the spike: the grabber welds itself to whatever its
-- trace hits, which is the spike, and its own "Strength" input is exactly the
-- break force we want to raise when the storm arrives.
--
-- This module never assumes Wiremod exists. TIV.WireAnchor.IsAvailable() is
-- the only gate, it is re-evaluated lazily (Wiremod can finish loading after
-- this file), and every entry point is a no-op when it answers false. The
-- caller (sv_anchor) falls back to its ballsocket holds in that case, so the
-- addon behaves identically with or without Wiremod installed.
-- ============================================================================

TIV.WireAnchor = TIV.WireAnchor or {}

local GRABBER_CLASS = "gmod_wire_grabber"

-- ============================================================================
-- DETECTION
-- ============================================================================
-- Three things have to be true for a grabber anchor to work:
--   1. the grabber SENT is registered (Wiremod present and loaded),
--   2. WireLib is up, because base_wire_entity's Initialize needs it,
--   3. the server has not been told to stick with ballsockets.
-- Cached, but re-probed while it is still answering false so a slow-loading
-- Wiremod is picked up on the first deploy rather than never.
local cached = nil

function TIV.WireAnchor.IsAvailable()
    if cached == true then return true end

    local ok = false
    if scripted_ents and isfunction(scripted_ents.GetStored) then
        ok = scripted_ents.GetStored(GRABBER_CLASS) ~= nil
    end
    if ok then
        local wire = rawget(_G, "WireLib")
        ok = istable(wire) and isfunction(wire.TriggerOutput)
    end
    if ok then
        ok = tobool(TIV.AnchorSetting("UseGrabbers", 1)) ~= false
    end

    if ok then cached = true end
    return ok
end

-- Lets the convar flip the system over without a map change.
function TIV.WireAnchor.InvalidateCache()
    cached = nil
end

function TIV.WireAnchor.Describe()
    if TIV.WireAnchor.IsAvailable() then return "wire_grabber" end
    return "ballsocket"
end

-- ============================================================================
-- GRABBER CREATION
-- ============================================================================
-- A grabber traces along its own +Z (self:GetUp()), NOT along its forward
-- vector -- see gmod_wire_grabber.lua: `endpos = vStart + (vForward * ...)`
-- where vForward is `self:GetUp()`. So the angle has to be built so that UP
-- lands on the spike. `dir:Angle()` would point the grabber's nose at it and
-- leave the beam sweeping 90 degrees off to the side, missing every time.
--
-- For roll 0 the up vector is (cos(y)sin(p), sin(y)sin(p), cos(p)), which
-- inverts directly: p = acos(d.z), y = atan2(d.y, d.x).
local function AimUpAt(fromPos, targetPos)
    local dir = targetPos - fromPos
    if dir:LengthSqr() < 0.0001 then return Angle(180, 0, 0) end
    dir = dir:GetNormalized()
    local pitch = math.deg(math.acos(math.Clamp(dir.z, -1, 1)))
    local yaw   = math.deg(math.atan2(dir.y, dir.x))
    return Angle(pitch, yaw, 0)
end

local function GrabberOrigin(veh, mountLocal, spikeWorldPos)
    local hullDrop = math.abs(veh:OBBMins().z) + TIV.AnchorSetting("GrabberHullClearance", 5)
    local pos = veh:LocalToWorld(Vector(mountLocal.x, mountLocal.y, mountLocal.z - hullDrop))
    -- Never let the body start out inside the spike: the grab trace begins at
    -- the grabber's own origin, so an overlapping start reads as a miss.
    local toSpike = spikeWorldPos - pos
    if toSpike:Length() < 8 then
        pos = spikeWorldPos - toSpike:GetNormalized() * 8
    end
    return pos
end

local function TagGrabber(grabber, veh, data, spikeData)
    grabber:SetNWBool("TIV_Spike", true)
    grabber:SetNWEntity("TIV_OwnerVehicle", veh)
    grabber.TIV_OwnerVehicle     = veh
    grabber.IsTIVSpike           = true
    grabber.IsTIVAnchorGrabber   = true
    grabber.PhysgunDisabled      = true
    grabber.DoNotDuplicate       = true
    -- Storm mods must not pick the anchor bodies up and carry them off.
    grabber:SetNWBool("GStormsIgnore", true)
    grabber:SetNWBool("XT3Ignore", true)
    grabber:SetNWBool("XT2Ignore", true)
    grabber:SetNWBool("XTwister2Ignore", true)
    grabber.GStormsIgnore        = true
    grabber.XT3Ignore            = true
    grabber.XT3DoNotApplyPhysics = true
    grabber.XT2Ignore            = true
    grabber.XT2DoNotApplyPhysics = true
    grabber.XTwister2Ignore      = true

    grabber:SetNoDraw(TIV.Config.HideSpikes == true)
    grabber:DrawShadow(false)

    local sp = grabber:GetPhysicsObject()
    if IsValid(sp) then
        sp:SetMass(math.max(10, TIV.AnchorSetting("GrabberMass", 120)))
    end

    -- The grabber must follow the chassis through every tilt and roll, so it
    -- is welded to it rigidly. This weld is the mount, not the anchor: it is
    -- cut unbreakable and is never the thing that gives way.
    local mount = constraint.Weld(veh, grabber, 0, 0, 0, true, false)
    return mount
end

--- Creates one grabber for one spike and returns (grabber, mountWeld) or nil.
function TIV.WireAnchor.CreateGrabber(veh, data, spikeData)
    if not TIV.WireAnchor.IsAvailable() then return nil end
    if not IsValid(veh) or not IsValid(spikeData.entity) then return nil end

    local spike = spikeData.entity
    local mountLocal = spikeData.storedLocalPos or spikeData.localPos or spikeData.offset or vector_origin
    local pos = GrabberOrigin(veh, mountLocal, spike:GetPos())

    local grabber = ents.Create(GRABBER_CLASS)
    if not IsValid(grabber) then return nil end

    grabber:SetPos(pos)
    grabber:SetAngles(AimUpAt(pos, spike:GetPos()))
    grabber:Spawn()
    grabber:Activate()

    local owner = TIV.ResolveOwner and TIV.ResolveOwner(veh) or nil
    if IsValid(owner) then
        grabber:SetOwner(owner)
        grabber:SetNWEntity("Owner", owner)
        -- CPPI, when present, so prop protection does not reject the grab.
        if isfunction(grabber.CPPISetOwner) then grabber:CPPISetOwner(owner) end
    end

    local mount = TagGrabber(grabber, veh, data, spikeData)
    if not IsValid(mount) then
        grabber:Remove()
        return nil
    end

    -- The grabber and its own spike must be free to overlap; the weld between
    -- them is what holds, not collision.
    local nocollide = constraint.NoCollide(grabber, spike, 0, 0)

    if isfunction(grabber.Setup) then
        grabber:Setup(TIV.AnchorSetting("GrabberRange", 160), false)
    end

    return grabber, mount, nocollide
end

-- ============================================================================
-- GRAB / RELEASE
-- ============================================================================
-- The grabber's own inputs do the work: "Strength" is the weld's break force
-- and "Grab" runs the trace. Driving the real inputs (rather than welding by
-- hand) is the point -- the constraint is genuinely the grabber's.
local function Grab(grabber, strength)
    if not IsValid(grabber) or not isfunction(grabber.TriggerInput) then return false end
    grabber:TriggerInput("Strength", strength or 0)
    grabber:TriggerInput("Grab", 1)
    return IsValid(grabber.Weld)
end

function TIV.WireAnchor.Grab(grabber, forceLimit)
    return Grab(grabber, forceLimit)
end

function TIV.WireAnchor.Release(grabber)
    if not IsValid(grabber) then return end
    if isfunction(grabber.TriggerInput) then
        grabber:TriggerInput("Grab", 0)
    end
end

--- Re-cuts the grab at a new break force.
-- The grabber stores its strength and applies it when the weld is made, so
-- changing the number means letting go and grabbing again. Both happen inside
-- one Lua frame, i.e. with no physics tick in between, so the anchor is never
-- actually absent for a moment of simulation.
function TIV.WireAnchor.Regrab(grabber, forceLimit)
    if not IsValid(grabber) then return false end
    TIV.WireAnchor.Release(grabber)
    return Grab(grabber, forceLimit)
end

function TIV.WireAnchor.IsHolding(grabber)
    return IsValid(grabber) and IsValid(grabber.Weld)
end

function TIV.WireAnchor.Remove(grabber)
    if not IsValid(grabber) then return end
    TIV.WireAnchor.Release(grabber)
    grabber:Remove()
end

print("[TIV] Wire grabber anchor module loaded (Wiremod "
    .. (rawget(_G, "WireLib") and "detected" or "not detected yet") .. ")")
