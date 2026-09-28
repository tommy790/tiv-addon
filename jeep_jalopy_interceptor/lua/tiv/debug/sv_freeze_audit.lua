-- ============================================================================
-- TIV FREEZE AUDIT (server, debug + safety net)
-- ============================================================================
-- Exists because a TIV was left hanging in mid-air after an intercept. The cause
-- of that kind of bug is never visible from the outside, so this reads the actual
-- physics and constraint state and prints it instead of guessing.
--
--   tiv_debug_freeze 1   -- print a per-vehicle audit once a second
--   tiv_debug_freeze 2   -- also print every state transition
--
-- The watchdog half is separate from the printing and is on by default
-- (tiv_freeze_watchdog). It enforces one invariant: a TIV in the "idle" state is
-- a normal, drivable vehicle. If gravity or motion is off, or one of this addon's
-- own constraints is still attached, that is a leaked anchor and it is cleared.
--
-- It only ever ENABLES physics and only ever removes constraints this addon
-- created itself. It never freezes anything, never adds a constraint, and never
-- touches a vehicle that is mid-sequence.
-- ============================================================================

TIV.Debug = TIV.Debug or {}

CreateConVar("tiv_debug_freeze", "0", { FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED },
    "TIV: 0 = off, 1 = audit TIV physics/constraints once a second, 2 = also log state transitions.")
CreateConVar("tiv_freeze_watchdog", "1", { FCVAR_ARCHIVE, FCVAR_NOTIFY },
    "TIV: restore gravity/motion and drop leftover TIV constraints on any TIV that has returned to idle.")

local AUDIT_INTERVAL = 1.0

-- ----------------------------------------------------------------------------
-- READING THE ACTUAL STATE
-- ----------------------------------------------------------------------------
local function CountConstraints(veh)
    local tbl = constraint.GetTable(veh)
    local n, kinds = 0, {}
    for _, c in ipairs(tbl or {}) do
        n = n + 1
        local t = c.Type or "?"
        kinds[t] = (kinds[t] or 0) + 1
    end
    local parts = {}
    for t, c in pairs(kinds) do parts[#parts + 1] = string.format("%s x%d", t, c) end
    table.sort(parts)
    return n, table.concat(parts, ", ")
end

-- How many of this addon's own constraints are still attached to the vehicle.
local function CountOwnConstraints(data)
    local live, list = 0, {}
    for _, c in ipairs(data.constraints or {}) do
        if IsValid(c.constraint) then
            live = live + 1
            list[#list + 1] = (c.type or "?") .. (c.isWorldAnchor and "(world)" or "")
        end
    end
    return live, table.concat(list, ", ")
end

local function SpikeCounts(data)
    local live, deployed, failed = 0, 0, 0
    for _, sd in ipairs(data.spikes or {}) do
        if IsValid(sd.entity) then
            live = live + 1
            if sd.phase == "deployed" then
                deployed = deployed + 1
                if sd.failed then failed = failed + 1 end
            end
        end
    end
    return live, deployed, failed
end

local function TimerNames(entIndex)
    local names = {}
    for _, n in ipairs({
        "TIV_Lower_" .. entIndex,
        "TIV_Raise_" .. entIndex,
        "TIV_WaveFail_" .. entIndex .. "_1",
        "TIV_WaveFail_" .. entIndex .. "_2",
        "TIV_WaveFail_" .. entIndex .. "_3",
    }) do
        if timer.Exists(n) then names[#names + 1] = n end
    end
    return table.concat(names, ", ")
end

-- A vehicle whose entity position and physics position disagree is being
-- teleported or having SetPos forced on it every tick. That is the single most
-- useful freeze symptom, and it is invisible from the driver's seat.
local function PositionDrift(veh, phys)
    local ep, pp = veh:GetPos(), phys:GetPos()
    return ep:Distance(pp)
end

function TIV.Debug.AuditVehicle(entIndex, data)
    local veh = Entity(entIndex)
    if not IsValid(veh) then
        print(string.format("[TIV audit] #%d data present but entity is gone (leaked state)", entIndex))
        return
    end

    local phys = veh:GetPhysicsObject()
    if not IsValid(phys) then
        print(string.format("[TIV audit] #%d has NO physics object", entIndex))
        return
    end

    local totalCons, kinds = CountConstraints(veh)
    local ownCons, ownList = CountOwnConstraints(data)
    local liveSpikes, deployed, failed = SpikeCounts(data)
    local tracking = (TIV.Loft.WindTimers and TIV.Loft.WindTimers[entIndex] ~= nil)
        or (TIV.Loft.FailingGroups and TIV.Loft.FailingGroups[entIndex] ~= nil)

    print(string.format(
        "[TIV audit] #%d state=%s anchored=%s gravityReleased=%s planted=%s | motion=%s gravity=%s asleep=%s collision=%s | drift=%.2f | vel=%.1f",
        entIndex, tostring(data.state), tostring(data.anchored), tostring(data.gravityReleased),
        data.plantedPos and "yes" or "no",
        tostring(phys:IsMotionEnabled()), tostring(phys:IsGravityEnabled()),
        tostring(phys:IsAsleep()), tostring(phys:IsCollisionEnabled()),
        PositionDrift(veh, phys), phys:GetVelocity():Length()))

    print(string.format(
        "[TIV audit]      constraints total=%d [%s] own=%d [%s] | spikes live=%d deployed=%d failed=%d | loftTracking=%s | timers=[%s] | immunity=%s",
        totalCons, kinds, ownCons, ownList, liveSpikes, deployed, failed,
        tostring(tracking), TimerNames(entIndex),
        tostring(veh.GStormsIgnore or veh.XT3Ignore or veh.XT2Ignore or false)))

    -- The combinations that actually leave a vehicle stuck in the air.
    if data.state == "idle" then
        if not phys:IsGravityEnabled() then
            print(string.format("[TIV audit]      !! WARN #%d is idle with GRAVITY DISABLED -- it will not fall", entIndex))
        end
        if not phys:IsMotionEnabled() then
            print(string.format("[TIV audit]      !! WARN #%d is idle with MOTION DISABLED -- it is frozen", entIndex))
        end
        if ownCons > 0 then
            print(string.format("[TIV audit]      !! WARN #%d is idle but still holds %d TIV constraint(s): %s", entIndex, ownCons, ownList))
        end
    elseif data.state == "lofted" then
        if ownCons > 0 then
            print(string.format("[TIV audit]      !! WARN #%d lofted but %d TIV constraint(s) survived: %s", entIndex, ownCons, ownList))
        end
        if not phys:IsGravityEnabled() then
            print(string.format("[TIV audit]      !! WARN #%d lofted with GRAVITY DISABLED -- it will hang in the air", entIndex))
        end
    end
end

-- ----------------------------------------------------------------------------
-- WATCHDOG
--
-- Invariant: idle means drivable. Restores physics and drops this addon's own
-- leftover constraints. Deliberately does nothing while a deploy/raise/loft
-- sequence is running, because those states legitimately freeze the body.
-- ----------------------------------------------------------------------------
function TIV.Debug.WatchdogVehicle(entIndex, data)
    if data.state ~= "idle" or data.anchored then return false end

    local veh = Entity(entIndex)
    if not IsValid(veh) then return false end
    local phys = veh:GetPhysicsObject()
    if not IsValid(phys) then return false end

    local fixed = {}

    local ownCons = 0
    for i = #(data.constraints or {}), 1, -1 do
        local c = data.constraints[i]
        if IsValid(c.constraint) then
            ownCons = ownCons + 1
            c.constraint:Remove()
        end
        table.remove(data.constraints, i)
    end
    if ownCons > 0 then fixed[#fixed + 1] = string.format("removed %d leftover constraint(s)", ownCons) end

    if not phys:IsGravityEnabled() then
        phys:EnableGravity(true)
        fixed[#fixed + 1] = "gravity restored"
    end
    -- Only undo motion this addon itself disabled; a physgun freeze (or any
    -- other addon's freeze) is the player's business.
    if not phys:IsMotionEnabled() and not veh.TIV_PlayerFrozen then
        phys:EnableMotion(true)
        phys:Wake()
        fixed[#fixed + 1] = "motion restored"
    end

    -- A leaked handbrake leaves the vehicle sitting there after an intercept even
    -- with perfectly healthy physics, which reads exactly like a freeze. The flag
    -- is set by ApplyHandbrake/ReleaseHandbrake in sv_deploy.lua.
    if veh.SetHandbrake and data.handbrakeOn then
        veh:SetHandbrake(false)
        data.handbrakeOn = nil
        fixed[#fixed + 1] = "handbrake released"
    end

    if #fixed > 0 then
        print(string.format("[TIV watchdog] #%d was idle but not free: %s", entIndex, table.concat(fixed, ", ")))
        return true
    end
    return false
end

local function IsTIVVehicle(ent)
    return IsValid(ent) and TIV.Deploy and TIV.Deploy.Vehicles[ent:EntIndex()] ~= nil
end

hook.Add("OnPhysgunFreeze", "TIV_MarkPlayerFreeze", function(_, phys, ent)
    if IsTIVVehicle(ent) then ent.TIV_PlayerFrozen = true end
end)

hook.Add("PlayerUnfrozeObject", "TIV_ClearPlayerFreeze", function(_, ent)
    if IsTIVVehicle(ent) then ent.TIV_PlayerFrozen = nil end
end)

hook.Add("PhysgunPickup", "TIV_ClearPlayerFreezeOnPickup", function(_, ent)
    if IsTIVVehicle(ent) then ent.TIV_PlayerFrozen = nil end
end)

-- ----------------------------------------------------------------------------
-- THINK
-- ----------------------------------------------------------------------------
local nextAudit = 0

hook.Add("Think", "TIV_FreezeAudit", function()
    local dbg = GetConVar("tiv_debug_freeze")
    local level = dbg and dbg:GetInt() or 0
    local watchCv = GetConVar("tiv_freeze_watchdog")
    local watch = not watchCv or watchCv:GetBool()
    if level <= 0 and not watch then return end

    local now = CurTime()
    local doAudit = level > 0 and now >= nextAudit
    if doAudit then
        nextAudit = now + AUDIT_INTERVAL
        print("[TIV audit] ---- " .. tostring(now) .. " ----")
    end

    for entIndex, data in pairs(TIV.Deploy.Vehicles or {}) do
        if doAudit then TIV.Debug.AuditVehicle(entIndex, data) end
        if watch then TIV.Debug.WatchdogVehicle(entIndex, data) end
    end
end)

-- State transitions are where a leak is introduced, so log them at level 2.
hook.Add("TIV_StateChanged", "TIV_FreezeAuditTransitions", function(veh, state)
    local dbg = GetConVar("tiv_debug_freeze")
    if not dbg or dbg:GetInt() < 2 then return end
    if not IsValid(veh) then return end

    local phys = veh:GetPhysicsObject()
    local data = TIV.Deploy.Vehicles[veh:EntIndex()]
    print(string.format("[TIV audit] #%d -> %s | motion=%s gravity=%s own_constraints=%d",
        veh:EntIndex(), tostring(state),
        IsValid(phys) and tostring(phys:IsMotionEnabled()) or "n/a",
        IsValid(phys) and tostring(phys:IsGravityEnabled()) or "n/a",
        data and select(1, CountOwnConstraints(data)) or 0))
end)

print("[TIV] Freeze audit loaded (tiv_debug_freeze, tiv_freeze_watchdog)")
