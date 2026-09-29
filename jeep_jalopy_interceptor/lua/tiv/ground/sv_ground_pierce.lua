-- ============================================================================
-- TIV GROUND PIERCE
-- ============================================================================
-- A standalone system for driving a prop into the terrain and having the
-- terrain actually hold it. Nothing here knows anything about the interceptor:
-- hand it any physics prop and it will embed it, grip it, measure the load on
-- it and let it come out progressively when the load is too much.
--
--   local handle = TIV.Ground.Pierce(prop, { depth = 18 })
--   ...
--   TIV.Ground.Release(handle)
--
-- THE THREE RULES THIS IS BUILT ON
--
-- 1. A pierced prop is never welded to the world and never frozen. A rigid
--    world weld turns the prop into an immovable pin that drags whatever it is
--    attached to flat; a frozen prop does the same and additionally stops
--    reporting any load at all.
--
-- 2. The grip is spread along the BURIED LENGTH of the prop, never attached at
--    a single point. This is the whole ballgame. A force applied exactly at a
--    pivot has no lever arm about that pivot, so a spring attached at the same
--    point a hold pins cannot produce any moment -- it can never resist the
--    prop ROTATING, however stiff it is. Grips at different depths can, because
--    they act at different radii. Get this wrong and the prop spins freely in
--    its hole while appearing to be anchored.
--
-- 3. The prop is repositioned exactly once, at pierce time, and never again.
--    That single move is the piercing itself -- the equivalent of hammering a
--    stake in. After it, physics owns the prop entirely: no per-tick SetPos, no
--    snapping back, no scripted recovery.
--
-- COMPATIBILITY WITH THE INTERCEPTOR
--
-- TIV.Anchor asks this module for its spikes' grip geometry (see
-- TIV.Config.Ground.UseForSpikes) and keeps ownership of everything else: the
-- spikes' load measurement, their tear-out, their chassis holds and all the
-- existing telemetry. It passes manage = false, which means this module builds
-- the grips and then leaves them alone, so the two systems can never fight
-- over the same springs. Set UseForSpikes to 0 and the interceptor falls back
-- to the grip code that used to live inside sv_anchor.lua.
-- ============================================================================

TIV = TIV or {}
TIV.Ground = TIV.Ground or {}

local Ground = TIV.Ground

-- ============================================================================
-- REGISTRY
-- ============================================================================
-- Handles are keyed by the entity so a caller holding only the prop can still
-- find its pierce. The array is what the think iterates.
local handles = {}     -- [entity] = handle
local active  = {}     -- [n] = handle

local function Dbg(...)
    if tobool(TIV.GroundSetting("Debug", 0)) then print("[TIV:Ground]", ...) end
end

local function indexOf(list, handle)
    for i = 1, #list do
        if list[i] == handle then return i end
    end
    return nil
end

-- ============================================================================
-- GEOMETRY
-- ============================================================================
-- Resolves opts.axis to a world direction. Accepts an Angle (its Forward), a
-- Vector, or nothing at all, in which case the prop's own Forward is used --
-- which for the interceptor's spikes is straight down the ram.
local function ResolveAxis(ent, axis)
    if isangle(axis) then return axis:Forward():GetNormalized() end
    if isvector(axis) then
        local l = axis:Length()
        if l > 0.0001 then return axis:GetNormalized() end
    end
    return ent:GetAngles():Forward():GetNormalized()
end

-- A unit vector perpendicular to the axis, used to offset the anchors sideways.
-- The prop's own Right is preferred so a pierced prop grips in a predictable
-- plane; the cross-product fallback covers the case where Right is parallel to
-- the axis.
local function Perpendicular(ent, axis)
    local r = ent:GetRight()
    local perp = r - axis * r:Dot(axis)
    if perp:LengthSqr() < 0.000001 then
        perp = axis:Cross(math.abs(axis.z) < 0.9 and Vector(0, 0, 1) or Vector(1, 0, 0))
    end
    return perp:GetNormalized()
end

--- The grip attach points for a prop, in both spaces.
-- This is the single piece of geometry the whole system -- and the
-- interceptor's spikes -- share. Returns an array of
-- { depth, localPos, point, side }, shallowest first.
--
-- localPos is in the PROP's local space (what constraint.Elastic wants as
-- LPos1); point is a WORLD position, because when the second body of a
-- constraint is the world, its "local" space is world space.
function Ground.GripPoints(ent, opts)
    if not IsValid(ent) then return {} end
    opts = opts or {}

    local axis      = ResolveAxis(ent, opts.axis)
    local side      = Perpendicular(ent, axis)
    local origin    = ent:GetPos()
    local grips     = math.Clamp(math.floor(tonumber(opts.grips) or TIV.GroundSettingCvar("Grips", 3)), 2, 12)
    local spacing   = math.max(1, tonumber(opts.spacing) or TIV.GroundSettingCvar("GripSpacing", 7))
    local firstGrip = math.max(0.5, tonumber(opts.firstGrip) or TIV.GroundSettingCvar("FirstGripDepth", 4))
    local lateral   = math.max(1, tonumber(opts.lateral) or TIV.GroundSettingCvar("LateralOffset", 7))

    -- The axis expressed in the prop's own local space, so the attach points
    -- follow the prop as it tilts instead of being frozen to one direction.
    local localOrigin = ent:WorldToLocal(origin)
    local localAxis   = (ent:WorldToLocal(origin + axis) - localOrigin):GetNormalized()

    local out = {}
    for i = 1, grips do
        local depth = firstGrip + (i - 1) * spacing
        -- Alternating sides. Every spring therefore has `lateral` as its rest
        -- length: a little slack before the ground pushes back, plus the
        -- sideways bite that stops the prop sliding out of its hole.
        local s = (i % 2 == 1) and -1 or 1
        out[i] = {
            depth    = depth,
            side     = s,
            localPos = localOrigin + localAxis * depth,
            point    = origin + axis * depth + side * (s * lateral),
        }
    end
    return out
end

-- ============================================================================
-- CONSTRAINT BUDGET
-- ============================================================================
-- Source caps a physics system at MAX_CONSTRAINTS_PER_SYSTEM (100). A pierced
-- prop spends one constraint per grip, so check before adding rather than
-- silently breaking whatever else is attached to the entity.
local function constraintHeadroom(ent, wanted)
    local existing = 0
    local list = constraint.GetTable(ent)
    if list then
        for _ in pairs(list) do existing = existing + 1 end
    end
    local cap = math.max(4, tonumber(TIV.GroundSetting("MaxConstraintsPerEntity", 64)) or 64)
    return (existing + wanted) <= cap, existing
end

-- ============================================================================
-- PIERCE
-- ============================================================================
--- Drive a prop into the ground and grip it there.
--
-- opts:
--   axis       Angle | Vector  direction to drive along (default: prop Forward)
--   depth      number          how far past the surface to drive the origin
--   drive      bool (true)     actually move the prop in. Pass false when
--                              something else already positioned it -- the
--                              interceptor's hydraulic stroke does, so its
--                              spikes are pierced with drive = false and are
--                              never repositioned by this module.
--   grips      number          grip count (default Grips, min 2)
--   spacing    number          distance between grips along the shaft
--   firstGrip  number          depth of the shallowest grip below the surface
--   lateral    number          sideways offset of each anchor = spring rest len
--   constant   number          spring constant
--   damping    number          spring damping
--   pullOut    number          axial pull that releases the deepest grip
--   slipOut    number          lateral slip that releases the deepest grip
--   filter     function        extra trace filter predicate
--   manage     bool (true)     run load measurement and progressive failure.
--                              Pass false to hand the grips to another system.
--   noCollide  bool            exempt this prop from world collisions
--   tag        string          label for the debug output
--   onGripLost function(ent, handle, gripIndex)
--   onTearOut  function(ent, handle)
--
-- Returns the handle, or nil if the prop cannot be pierced.
function Ground.Pierce(ent, opts)
    if not IsValid(ent) then return nil end
    if not tobool(TIV.GroundSetting("Enabled", 1)) then
        Dbg("refused: system disabled")
        return nil
    end

    opts = opts or {}
    local phys = ent:GetPhysicsObject()
    if not IsValid(phys) then
        Dbg("refused: " .. tostring(ent:GetClass()) .. " has no physics object (is a model set?)")
        return nil
    end

    -- Re-piercing the same prop would double its grips. Release first so the
    -- call is idempotent.
    Ground.Release(ent)

    local grips = math.Clamp(math.floor(tonumber(opts.grips) or TIV.GroundSettingCvar("Grips", 3)), 2, 12)
    local ok, existing = constraintHeadroom(ent, grips)
    if not ok then
        Dbg(string.format("refused: %s already carries %d constraints, no room for %d grips",
            tostring(ent:GetClass()), existing, grips))
        return nil
    end

    local axis = ResolveAxis(ent, opts.axis)

    -- ------------------------------------------------------------------
    -- FIND THE SURFACE AND DRIVE
    -- The one and only reposition this module ever performs.
    -- ------------------------------------------------------------------
    local drive = (opts.drive == nil) and true or tobool(opts.drive)
    local depth = math.max(0, tonumber(opts.depth) or TIV.GroundSettingCvar("DriveDepth", 15))
    local traceDist = math.max(depth + 8, tonumber(TIV.GroundSetting("TraceDistance", 350)) or 350)
    local surface, hitNormal

    local start = ent:GetPos()
    local tr = util.TraceLine({
        start  = start,
        endpos = start + axis * traceDist,
        filter = opts.filter,
        mask   = MASK_SOLID,
    })
    if tr.Hit then
        surface    = tr.HitPos
        hitNormal  = tr.HitNormal
    else
        surface    = start + axis * (tonumber(TIV.GroundSetting("MissFallbackDepth", 60)) or 60)
        hitNormal  = -axis
    end

    if drive then
        local target = surface + axis * depth
        phys:SetVelocity(vector_origin)
        phys:SetAngleVelocity(vector_origin)
        phys:SetPos(target)
    end

    -- ------------------------------------------------------------------
    -- BUILD THE HANDLE
    -- ------------------------------------------------------------------
    local handle = {
        entity     = ent,
        tag        = opts.tag or ent:GetClass(),
        axis       = axis,
        surface    = surface,
        hitNormal  = hitNormal,
        drive      = drive,
        depth      = depth,
        manage     = (opts.manage == nil) and true or tobool(opts.manage),
        stressed   = false,
        grips      = {},          -- live grip springs, shallowest first
        gripTotal  = 0,
        origin     = ent:GetPos(),   -- reference pose, for measuring load
        piercedAt  = CurTime(),
        pull       = 0,
        slip       = 0,
        load       = 0,
        torn       = false,
        onGripLost = opts.onGripLost,
        onTearOut  = opts.onTearOut,
        pullOut    = math.max(1, tonumber(opts.pullOut) or TIV.GroundSettingCvar("PullOutDistance", 11)),
        slipOut    = math.max(1, tonumber(opts.slipOut) or TIV.GroundSettingCvar("SlipOutDistance", 15)),
    }

    -- ------------------------------------------------------------------
    -- CUT THE GRIPS
    -- ------------------------------------------------------------------
    local constant = math.max(50, tonumber(opts.constant) or TIV.GroundSettingCvar("Constant", 6000))
    local damping  = math.max(1,  tonumber(opts.damping)  or TIV.GroundSettingCvar("Damping", 1500))
    local world    = game.GetWorld()

    for i, g in ipairs(Ground.GripPoints(ent, {
        axis = axis, grips = grips,
        spacing   = opts.spacing,
        firstGrip = opts.firstGrip,
        lateral   = opts.lateral,
    })) do
        -- stretchonly: soil grips, it never pushes. Each spring is exactly at
        -- its rest length at pierce time, so it only develops tension as the
        -- prop is dragged or twisted out of its hole -- it never shoves the
        -- prop deeper when something drops onto it.
        local spring = constraint.Elastic(ent, world, 0, 0, g.localPos, g.point,
            constant, damping, 0, "", 0, true)
        if IsValid(spring) then
            handle.grips[#handle.grips + 1] = {
                index    = i,
                depth    = g.depth,
                spring   = spring,
                point    = g.point,
                localPos = g.localPos,
            }
        end
    end

    handle.gripTotal = #handle.grips
    handle.gripsLive = handle.gripTotal
    handle.constant  = constant

    if handle.gripTotal == 0 then
        Dbg(string.format("failed: %s produced no grip springs", tostring(handle.tag)))
        return nil
    end

    -- ------------------------------------------------------------------
    -- LET GO OF THE PROP -- but only now that the grips exist.
    -- Releasing a live body before the constraint that holds it has been cut
    -- leaves it falling with nothing to catch it.
    -- ------------------------------------------------------------------
    phys:SetMass(math.max(5, phys:GetMass()))
    phys:EnableGravity(true)
    if not phys:IsMotionEnabled() then
        phys:EnableMotion(true)
    end
    phys:Wake()

    -- An embedded prop intersects the world brush; without this the solver
    -- shoves it straight back out of the hole it was just driven into.
    handle.noCollide = (opts.noCollide == nil) and tobool(TIV.GroundSetting("NoWorldCollide", 1))
                                           or tobool(opts.noCollide)

    handles[ent] = handle
    active[#active + 1] = handle

    Dbg(string.format("%s pierced: %d grip(s), depth %.1f u, manage=%s",
        tostring(handle.tag), handle.gripTotal, depth, tostring(handle.manage)))
    return handle
end

-- ============================================================================
-- RELEASE
-- ============================================================================
--- Remove a prop's grips and unregister it. Safe to call with a handle, an
-- entity, or something already released.
function Ground.Release(handleOrEnt)
    local handle = handleOrEnt
    if not handle then return 0 end
    if not handle.grips then handle = handles[handleOrEnt] end
    if not handle then return 0 end

    local removed = 0
    for _, g in ipairs(handle.grips) do
        if IsValid(g.spring) then
            g.spring:Remove()
            removed = removed + 1
        end
    end
    handle.grips      = {}
    handle.gripsLive  = 0
    handle.torn       = true
    handle.releasedAt = CurTime()

    handles[handle.entity] = nil
    local i = indexOf(active, handle)
    if i then table.remove(active, i) end

    Dbg(string.format("%s released (%d grip(s))", tostring(handle.tag), removed))
    return removed
end

-- ============================================================================
-- QUERY
-- ============================================================================
function Ground.ForEntity(ent)
    return handles[ent]
end

function Ground.IsPierced(handleOrEnt)
    local h = handleOrEnt and handleOrEnt.grips and handleOrEnt or handles[handleOrEnt]
    return h ~= nil and h.gripsLive > 0
end

-- Aliases that read better at a call site.
Ground.IsHolding = Ground.IsPierced

function Ground.Load(handleOrEnt)
    local h = handleOrEnt and handleOrEnt.grips and handleOrEnt or handles[handleOrEnt]
    return h and h.load or 0
end

--- Live grips, total grips. A prop losing its grip from the top down reads as
-- 2/3, 1/3, 0/3 rather than snapping from held to gone.
function Ground.Grips(handleOrEnt)
    local h = handleOrEnt and handleOrEnt.grips and handleOrEnt or handles[handleOrEnt]
    if not h then return 0, 0 end
    return h.gripsLive or 0, h.gripTotal or 0
end

function Ground.Count()
    return #active
end

function Ground.All()
    return active
end

--- Marks a prop as being actively pulled on, which removes the calm slack from
-- its failure thresholds. Without a stress state a prop would lose its grips
-- just because the solver nudged it.
function Ground.SetStressed(handleOrEnt, stressed)
    local h = handleOrEnt and handleOrEnt.grips and handleOrEnt or handles[handleOrEnt]
    if h then h.stressed = tobool(stressed) end
end

-- ============================================================================
-- LOAD AND PROGRESSIVE FAILURE
-- ============================================================================
local function dropGrip(handle, n)
    local g = handle.grips[n]
    if not g then return end
    if IsValid(g.spring) then g.spring:Remove() end
    table.remove(handle.grips, n)
    handle.gripsLive = #handle.grips

    Dbg(string.format("%s lost grip %d (%.1f u deep) -- %d left",
        tostring(handle.tag), g.index, g.depth, handle.gripsLive))

    if handle.onGripLost then
        local okcall, err = pcall(handle.onGripLost, handle.entity, handle, g.index)
        if not okcall then print("[TIV:Ground] onGripLost error: " .. tostring(err)) end
    end

    if handle.gripsLive == 0 and not handle.torn then
        handle.torn = true
        Dbg(string.format("%s tore out of the ground", tostring(handle.tag)))
        if handle.onTearOut then
            local okcall, err = pcall(handle.onTearOut, handle.entity, handle)
            if not okcall then print("[TIV:Ground] onTearOut error: " .. tostring(err)) end
        end
    end
end

--- Measure one prop's grip and let go of whatever the soil can no longer hold.
-- Returns the handle's state table, or nil if it is not pierced.
--
-- Only called by the think for handles created with manage = true; anything
-- that owns its own failure logic (the interceptor's spikes do) measures for
-- itself and leaves this alone.
function Ground.Update(handleOrEnt)
    local handle = handleOrEnt and handleOrEnt.grips and handleOrEnt or handles[handleOrEnt]
    if not handle then return nil end

    local ent = handle.entity
    if not IsValid(ent) then
        Ground.Release(handle)
        return nil
    end
    if handle.gripsLive <= 0 then
        handle.pull, handle.slip, handle.load = 0, 0, handle.load
        return handle
    end

    local delta = ent:GetPos() - handle.origin
    local along = delta:Dot(handle.axis)
    local lateral = delta - handle.axis * along

    -- The axis points INTO the ground, so a prop coming out moves against it.
    handle.pull = math.max(0, -along)
    handle.slip = lateral:Length()
    handle.load = math.Clamp(math.max(handle.pull / handle.pullOut, handle.slip / handle.slipOut), 0, 1)

    -- A prop that has just been driven in is still absorbing the impact.
    local settle = math.max(0, tonumber(TIV.GroundSetting("SettleTime", 0.75)) or 0)
    if CurTime() - handle.piercedAt < settle then return handle end

    -- While nothing is stressing the prop the thresholds get more slack.
    local slack = 1
    if not handle.stressed then
        slack = math.max(1, tonumber(TIV.GroundSetting("CalmSlack", 2.5)) or 1)
    end

    -- Grips fail from the top down: the shallowest has the least soil above it
    -- and goes first, then the next, so a heavily loaded prop comes out
    -- progressively instead of letting go all at once.
    local start = math.Clamp(tonumber(TIV.GroundSetting("GripFailureStart", 0.6)) or 0.6, 0.05, 1)
    local total = math.max(1, handle.gripTotal)
    local n = 1
    while handle.grips[n] do
        local rank = handle.grips[n].index
        local threshold = (start + (1 - start) * (rank - 1) / total) * slack
        if handle.load >= threshold then
            dropGrip(handle, n)
        else
            n = n + 1
        end
    end

    return handle
end

-- ============================================================================
-- THINK
-- ============================================================================
local nextThink = 0
hook.Add("Think", "TIV_GroundPierce", function()
    if #active == 0 then return end
    local now = CurTime()
    if now < nextThink then return end
    nextThink = now + 0.05

    for i = #active, 1, -1 do
        local handle = active[i]
        if not handle then
            table.remove(active, i)
        elseif not IsValid(handle.entity) then
            Ground.Release(handle)
        elseif handle.manage then
            Ground.Update(handle)
        end
    end
end)

hook.Add("EntityRemoved", "TIV_GroundPierce", function(ent)
    if handles[ent] then Ground.Release(handles[ent]) end
end)

-- ============================================================================
-- COLLISION
-- ============================================================================
-- A prop embedded in terrain intersects the world brush and the solver will
-- push it back out. This refuses that one specific pair and returns nil for
-- everything else, so no other collision decision in the game is affected.
hook.Add("ShouldCollide", "TIV_GroundPierce", function(a, b)
    local ha, hb = handles[a], handles[b]
    if not ha and not hb then return nil end

    local other = ha and b or a
    local mine  = ha or hb
    if not mine.noCollide then return nil end

    if other:IsWorld() then return false end
    -- Two pierced props in the same hole should not shove each other apart
    -- either; the grips are what position them.
    if handles[other] then return false end
    return nil
end)

-- ============================================================================
-- REPORTING
-- ============================================================================
function Ground.ReportLines()
    local lines = {}
    lines[#lines + 1] = string.format("Ground pierce : %d active prop(s)", #active)
    for _, h in ipairs(active) do
        lines[#lines + 1] = string.format("  %-22s grips %d/%d  load %3.0f%%  pull %5.1f u  slip %5.1f u  %s",
            tostring(h.tag), h.gripsLive or 0, h.gripTotal or 0, (h.load or 0) * 100,
            h.pull or 0, h.slip or 0,
            h.torn and "TORN OUT" or (h.manage and "managed" or "external"))
    end
    return lines
end

-- ============================================================================
-- CONSOLE COMMANDS
-- ============================================================================
if not GetConVar("tiv_ground_debug") then
    CreateConVar("tiv_ground_debug", "0", FCVAR_ARCHIVE)
end
if not GetConVar("tiv_ground_grips") then
    CreateConVar("tiv_ground_grips", tostring(TIV.GroundSetting("Grips", 3)), FCVAR_ARCHIVE)
end
if not GetConVar("tiv_ground_gripspacing") then
    CreateConVar("tiv_ground_gripspacing", tostring(TIV.GroundSetting("GripSpacing", 7)), FCVAR_ARCHIVE)
end
if not GetConVar("tiv_ground_constant") then
    CreateConVar("tiv_ground_constant", tostring(TIV.GroundSetting("Constant", 6000)), FCVAR_ARCHIVE)
end
if not GetConVar("tiv_ground_damping") then
    CreateConVar("tiv_ground_damping", tostring(TIV.GroundSetting("Damping", 1500)), FCVAR_ARCHIVE)
end
if not GetConVar("tiv_ground_enabled") then
    CreateConVar("tiv_ground_enabled", tostring(TIV.GroundSetting("Enabled", 1)), FCVAR_ARCHIVE)
end

concommand.Add("tiv_ground_report", function()
    for _, line in ipairs(Ground.ReportLines()) do print(line) end
end)

print("[TIV] Ground pierce system loaded")
