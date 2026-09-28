-- ============================================================================
-- TIV DEPLOY SYSTEM
-- ============================================================================
-- State machine:
--
--   idle -> lowering -> deploying_spikes -> anchored
--   anchored -> retracting -> raising -> idle
--   anchored -> lofted -> idle            (sv_loft.lua)
--
--   lowering         : airbag springs at every layout mount shorten; the
--                      chassis is pulled onto its suspension by real force
--   deploying_spikes : hydraulic pistons stroke down from the lowered pose and
--                      plant in the ground (none fitted: wait until the
--                      chassis is at rest on the springs)
--   anchored         : limited ballsockets lock the settled pose; springs at
--                      mounts a spike holds go, the others stay
--   retracting       : springs hold the pose while the pistons withdraw
--   raising          : springs let out over LowerTime, suspension rebounds
--
-- The chassis physics object is a live body in every state. Nothing here
-- calls SetPos or EnableMotion(false) on the vehicle.
-- ============================================================================

TIV.Deploy = TIV.Deploy or {}

util.AddNetworkString("TIV_DeployStatus")
util.AddNetworkString("TIV_DeployRequest")

TIV.Deploy.Vehicles  = TIV.Deploy.Vehicles  or {}
TIV.Deploy.Cooldowns = TIV.Deploy.Cooldowns or {}

local COOLDOWN_TIME = 1.5
local RAISE_SETTLE  = 0.6

-- ============================================================================
-- STATE
-- ============================================================================
function TIV.Deploy.GetState(veh)
    if not IsValid(veh) then return nil end
    local idx = veh:EntIndex()
    local data = TIV.Deploy.Vehicles[idx]
    if not data then
        data = {
            state           = "idle",
            spikes          = {},
            constraints     = {},
            spikeAnims      = {},
            anchored        = false,
            spikesCreated   = false,
            sessionID       = nil,
            gravityReleased = false,
        }
        TIV.Deploy.Vehicles[idx] = data
    end
    return data
end

function TIV.Deploy.IsJeep(ent)
    return TIV.IsSupportedVehicle and TIV.IsSupportedVehicle(ent) or false
end

function TIV.Deploy.ResolveVehicle(ply)
    if TIV.ResolveVehicle then return TIV.ResolveVehicle(ply) end
    if not IsValid(ply) then return nil end
    local seat = ply:GetVehicle()
    return IsValid(seat) and seat or nil
end

function TIV.Deploy.BroadcastState(veh, state)
    net.Start("TIV_DeployStatus")
        net.WriteEntity(veh)
        net.WriteString(state)
    net.Broadcast()
    hook.Run("TIV_StateChanged", veh, state)
end

local function SetState(veh, data, state)
    data.state = state
    TIV.Deploy.BroadcastState(veh, state)
end

local function SpeedMult()
    local cv = GetConVar("tiv_deploy_speed")
    return cv and math.max(0.2, cv:GetFloat()) or 1
end

-- ============================================================================
-- HANDBRAKE
-- ============================================================================
local function ApplyHandbrake(veh)
    if not IsValid(veh) then return end
    local cv = GetConVar("tiv_deploy_handbrake")
    if cv and not cv:GetBool() then return end
    if veh.SetHandbrake then veh:SetHandbrake(true) end
    local data = TIV.Deploy.GetState(veh)
    if data then data.handbrakeOn = true end
end

local function ReleaseHandbrake(veh)
    if not IsValid(veh) then return end
    if veh.SetHandbrake then veh:SetHandbrake(false) end
    local data = TIV.Deploy.GetState(veh)
    if data then data.handbrakeOn = nil end
end
TIV.Deploy.ReleaseHandbrake = ReleaseHandbrake

-- Driving is blocked from the first frame of lowering until the vehicle is
-- idle again. The handbrake alone is not enough on prop_vehicle_jeep: the
-- engine still pushes against it, so the driver's inputs are dropped too.
local LOCKED_STATES = {
    lowering         = true,
    deploying_spikes = true,
    anchored         = true,
    retracting       = true,
    raising          = true,
}
TIV.Deploy.LockedStates = LOCKED_STATES

function TIV.Deploy.IsDriveLocked(veh)
    local data = TIV.Deploy.Vehicles[veh:EntIndex()]
    return data ~= nil and LOCKED_STATES[data.state] == true
end

local DRIVE_BUTTONS = bit.bor(IN_FORWARD, IN_BACK, IN_MOVELEFT, IN_MOVERIGHT, IN_JUMP, IN_SPEED)

hook.Add("StartCommand", "TIV_DriveLock", function(ply, cmd)
    local seat = ply:GetVehicle()
    if not IsValid(seat) then return end
    local veh = TIV.Deploy.IsJeep(seat) and seat or seat:GetParent()
    if not IsValid(veh) or not TIV.Deploy.IsDriveLocked(veh) then return end
    cmd:SetForwardMove(0)
    cmd:SetSideMove(0)
    cmd:SetUpMove(0)
    cmd:SetButtons(bit.band(cmd:GetButtons(), bit.bnot(DRIVE_BUTTONS)))
end)

-- The jeep's own input code toggles the handbrake off whenever it sees the
-- driver release it, and SetHandbrake(true) is not sticky, so the brake is
-- re-asserted every tick while a sequence is running.
hook.Add("Think", "TIV_HoldHandbrake", function()
    local cv = GetConVar("tiv_deploy_handbrake")
    if cv and not cv:GetBool() then return end
    for idx, data in pairs(TIV.Deploy.Vehicles) do
        if LOCKED_STATES[data.state] then
            local veh = Entity(idx)
            if IsValid(veh) and veh.SetHandbrake then
                veh:SetHandbrake(true)
                if veh.SetThrottle then veh:SetThrottle(0) end
                data.handbrakeOn = true
            end
        end
    end
end)

-- ============================================================================
-- SPIKE RECONCILIATION
-- ============================================================================
function TIV.Deploy.EnsureSpikes(veh, data)
    local desired = (TIV.Spikes.ResolveCount and TIV.Spikes.ResolveCount(veh))
        or math.Clamp(TIV.Config.SpikeCount, TIV.Config.SpikeCountConvarMin, TIV.Config.SpikeCountConvarMax)

    if data.spikesCreated then
        local valid = TIV.Spikes.GetCount(data)
        if valid == desired then return end
        if data.state ~= "idle" then return end
        if valid > 0 then
            print(string.format("[TIV] Spike count changed (%d -> %d), rebuilding spikes...", valid, desired))
        else
            print("[TIV] Spikes missing, recreating...")
        end
        TIV.Anchor.DetachAll(veh, data)
        TIV.Spikes.RemoveAll(data, veh:EntIndex())
        data.spikesCreated = false
    end

    TIV.Spikes.Create(veh, data)
    data.spikesCreated = true

    if TIV.Wire and TIV.Wire.EnsureController then TIV.Wire.EnsureController(veh) end
    if TIV.CustomComponents then
        if TIV.CustomComponents.EnsureArmor then TIV.CustomComponents.EnsureArmor(veh) end
        if TIV.CustomComponents.ApplyVehicleBonuses then TIV.CustomComponents.ApplyVehicleBonuses(veh) end
    end
end

-- ============================================================================
-- INPUT
-- ============================================================================
local function IsOnCooldown(ply)
    local id = ply:SteamID()
    local last = TIV.Deploy.Cooldowns[id] or 0
    if CurTime() - last < COOLDOWN_TIME then return true end
    TIV.Deploy.Cooldowns[id] = CurTime()
    return false
end

local function IsDriverOf(ply, veh)
    if not IsValid(ply) or not IsValid(veh) then return false end
    if veh.GetDriver then
        local driver = veh:GetDriver()
        if IsValid(driver) then return driver == ply end
    end
    local seat = ply:GetVehicle()
    if not IsValid(seat) then return false end
    if seat == veh then return true end
    if seat:GetParent() == veh then
        if seat.GetDriverSeat then return seat:GetDriverSeat() == seat end
        return true
    end
    return false
end
TIV.Deploy.IsDriverOf = IsDriverOf

function TIV.Deploy.HandleInput(ply, veh)
    if not IsValid(veh) or not IsValid(ply) then return end
    if IsOnCooldown(ply) then return end
    if not TIV.Deploy.IsJeep(veh) then return end
    if not IsDriverOf(ply, veh) then return end

    local data = TIV.Deploy.GetState(veh)
    TIV.Deploy.EnsureSpikes(veh, data)

    local s = data.state
    if s == "idle" then
        TIV.Deploy.StartDeploy(ply, veh)
    elseif s == "anchored" then
        TIV.Deploy.StartRetract(ply, veh)
    elseif s == "lowering" then
        TIV.Deploy.ReverseToLowering(veh, data)
    elseif s == "deploying_spikes" then
        TIV.Deploy.ReverseToRetracting(veh, data)
    elseif s == "retracting" then
        TIV.Deploy.ReverseToDeploying(veh, data)
    elseif s == "raising" then
        TIV.Deploy.ReverseToRaising(veh, data)
    end
end

-- ============================================================================
-- SUSPENSION LIMIT
-- ============================================================================
function TIV.Deploy.GetSuspensionLimit(veh)
    local cv = GetConVar("tiv_suspension_limit")
    if cv and cv:GetFloat() > 0 then return cv:GetFloat() end

    local limits = TIV.Config.SuspensionLimits
    if IsValid(veh) and limits then
        local class = string.lower(veh:GetClass() or "")
        local model = string.lower(veh:GetModel() or "")
        if class == "prop_vehicle_jalopy" or string.find(model, "jalopy", 1, true) or string.find(model, "vehicle.mdl", 1, true) then
            return limits.jalopy or TIV.Config.LowerAmount or 10
        elseif class == "prop_vehicle_apc" or string.find(model, "apc", 1, true) then
            return limits.apc or TIV.Config.LowerAmount or 10
        elseif limits.jeep then
            return limits.jeep
        end
    end
    return TIV.Config.LowerAmount or 10
end

-- ============================================================================
-- DEPLOY
-- ============================================================================
local function CanStartDeploy(veh, data)
    local phys = veh:GetPhysicsObject()
    if not IsValid(phys) then return false end
    -- A physgun-frozen vehicle stays frozen; deploying would have to unfreeze it.
    if not phys:IsMotionEnabled() then return false end
    if TIV.Compat and TIV.Compat.Enabled then
        if data.compatRecoverUntil and CurTime() < data.compatRecoverUntil then return false end
        if phys:GetVelocity():Length() > TIV.Compat.MaxDeployLinearVelocity
        or phys:GetAngleVelocity():Length() > TIV.Compat.MaxDeployAngularVelocity then
            return false
        end
    end
    return true
end

-- Locks the settled pose with ballsockets, then lets the springs go.
local function FinalizeAnchored(veh, data)
    if not IsValid(veh) then return end
    if data.state ~= "deploying_spikes" and data.state ~= "lowering" then return end
    timer.Remove("TIV_Lower_" .. veh:EntIndex())

    TIV.Anchor.AttachAll(veh, data)
    if TIV.Spikes.GetCount(data) == 0 then
        TIV.Anchor.AttachWorld(veh, data)
        TIV.Anchor.ReleaseSprings(veh, data)
    else
        TIV.Anchor.ReleaseCoveredSprings(veh, data)
    end
    TIV.Anchor.UnfreezeForDeploy(veh)

    data.anchored   = true
    data.plantedPos = veh:GetPos()
    if TIV.Loft and TIV.Loft.SetAnchoredImmunity then TIV.Loft.SetAnchoredImmunity(veh, true) end
    ApplyHandbrake(veh)
    util.ScreenShake(veh:GetPos(), 3, 5, 0.5, 200)
    SetState(veh, data, "anchored")
end

-- Spikes drive in from the already-lowered pose; the springs keep holding
-- until the ballsockets take over in FinalizeAnchored.
local function StartSpikeDeploy(veh, data)
    if not IsValid(veh) then return end
    if TIV.Spikes.GetCount(data) == 0 then
        SetState(veh, data, "deploying_spikes")
        -- With spikes the chassis has the whole piston stroke to come to rest
        -- on the shortened springs before the sockets capture its pose. With
        -- none it would be captured mid-bounce, so wait for it to stop.
        local settleName = "TIV_Settle_" .. veh:EntIndex()
        local deadline = CurTime() + 2
        timer.Create(settleName, 0.05, 0, function()
            if not IsValid(veh) or data.state ~= "deploying_spikes" then
                timer.Remove(settleName)
                return
            end
            local phys = veh:GetPhysicsObject()
            local still = not IsValid(phys)
                or (phys:GetVelocity():Length() < 4 and phys:GetAngleVelocity():Length() < 4)
            if still or CurTime() >= deadline then
                timer.Remove(settleName)
                FinalizeAnchored(veh, data)
            end
        end)
        return
    end
    SetState(veh, data, "deploying_spikes")
    TIV.Spikes.Deploy(veh, data, function()
        if not IsValid(veh) or data.state ~= "deploying_spikes" then return end
        FinalizeAnchored(veh, data)
    end)
end

-- Airbags first: springs to the ground shorten over LowerTime.
local function StartLowering(veh, data)
    if not IsValid(veh) then return end
    SetState(veh, data, "lowering")
    ApplyHandbrake(veh)
    if veh.SetThrottle then veh:SetThrottle(0) end

    local lowerAmount = TIV.Deploy.GetSuspensionLimit(veh)
    data.lowerAmount = lowerAmount
    local created = TIV.Anchor.StartPullDown(veh, data, lowerAmount)
    local debugOn = GetConVar("tiv_debug_freeze") and GetConVar("tiv_debug_freeze"):GetBool()
    local startZ  = veh:GetPos().z
    if created == 0 then
        -- Nothing solid below the mounts (airborne, over water, etc.).
        print(string.format("[TIV] #%d lowering skipped: no ground under any mount point", veh:EntIndex()))
        StartSpikeDeploy(veh, data)
        return
    end
    if debugOn then
        print(string.format("[TIV] #%d lowering: %d spring(s), target %.1f u over %.2fs",
            veh:EntIndex(), created, lowerAmount, (TIV.Config.LowerTime or 1) / SpeedMult()))
    end

    local lowerTime  = (TIV.Config.LowerTime or 1) / SpeedMult()
    local startTime  = CurTime()
    local timerName  = "TIV_Lower_" .. veh:EntIndex()
    local nextStrain = 0

    timer.Create(timerName, 0.02, 0, function()
        if not IsValid(veh) or data.state ~= "lowering" then
            timer.Remove(timerName)
            return
        end
        local frac = math.Clamp((CurTime() - startTime) / lowerTime, 0, 1)
        TIV.Anchor.UpdatePullDown(data, frac)

        if CurTime() >= nextStrain then
            nextStrain = CurTime() + math.Rand(0.3, 0.6)
            veh:EmitSound("physics/metal/metal_box_strain" .. math.random(1, 4) .. ".wav", 55, math.random(70, 90))
        end

        if frac >= 1 then
            timer.Remove(timerName)
            -- One more beat for the suspension to settle on the shortened
            -- springs before the pistons start from that height.
            timer.Simple(0.25, function()
                if not IsValid(veh) or data.state ~= "lowering" then return end
                if debugOn then
                    print(string.format("[TIV] #%d lowering done: chassis dropped %.1f u (asked %.1f)",
                        veh:EntIndex(), startZ - veh:GetPos().z, lowerAmount))
                end
                StartSpikeDeploy(veh, data)
            end)
        end
    end)
end

function TIV.Deploy.StartDeploy(ply, veh)
    if not IsValid(veh) then return end
    local data = TIV.Deploy.GetState(veh)
    if data.state ~= "idle" and data.state ~= "raising" then return end
    if not CanStartDeploy(veh, data) then return end

    timer.Remove("TIV_Raise_" .. veh:EntIndex())
    data.gravityReleased = false
    data.originalPos = veh:GetPos()
    StartLowering(veh, data)
end

-- Used by the wind auto-deploy feature.
function TIV.Deploy.Deploy(veh, data)
    if not IsValid(veh) then return end
    TIV.Deploy.EnsureSpikes(veh, data or TIV.Deploy.GetState(veh))
    TIV.Deploy.StartDeploy(nil, veh)
end

-- ============================================================================
-- RETRACT
-- ============================================================================
-- Springs are let out over LowerTime so the suspension comes back up at the
-- same rate it went down instead of snapping to ride height.
function TIV.Deploy.RaiseVehicle(ply, veh)
    if not IsValid(veh) then return end
    local data = TIV.Deploy.GetState(veh)
    SetState(veh, data, "raising")
    TIV.Anchor.ReleaseLock(veh, data)
    TIV.Anchor.UnfreezeForDeploy(veh)

    if not data.pullDown then TIV.Anchor.StartPullDown(veh, data, 0) end
    local riseAmount = data.lowerAmount or TIV.Deploy.GetSuspensionLimit(veh)
    local raiseTime  = (TIV.Config.LowerTime or 1) / SpeedMult()
    local startTime  = CurTime()
    local timerName  = "TIV_Raise_" .. veh:EntIndex()

    local function Finish()
        timer.Remove(timerName)
        if not IsValid(veh) or data.state ~= "raising" then return end
        TIV.Anchor.DetachAll(veh, data)
        data.anchored   = false
        data.plantedPos = nil
        if TIV.Loft and TIV.Loft.SetAnchoredImmunity then TIV.Loft.SetAnchoredImmunity(veh, false) end
        ReleaseHandbrake(veh)
        SetState(veh, data, "idle")

        if TIV.Spikes.GetCount(data) == 0
            and math.Clamp(TIV.Config.SpikeCount, 0, TIV.Config.SpikeCountConvarMax) > 0 then
            print("[TIV] Spikes lost during retract, recreating...")
            data.spikesCreated = false
            TIV.Deploy.EnsureSpikes(veh, data)
        end
    end

    if not data.pullDown or #data.pullDown.elastics == 0 then
        timer.Create(timerName, RAISE_SETTLE / SpeedMult(), 1, Finish)
        return
    end

    timer.Create(timerName, 0.02, 0, function()
        if not IsValid(veh) or data.state ~= "raising" then
            timer.Remove(timerName)
            return
        end
        local frac = math.Clamp((CurTime() - startTime) / raiseTime, 0, 1)
        TIV.Anchor.UpdateRaise(data, frac, riseAmount)
        if frac >= 1 then
            timer.Remove(timerName)
            timer.Simple(RAISE_SETTLE / SpeedMult(), Finish)
        end
    end)
end

-- Mirror of deploy: the body stays held down (springs at the current pose)
-- while the pistons withdraw, then RaiseVehicle lets the suspension back up.
function TIV.Deploy.StartRetract(ply, veh)
    if not IsValid(veh) then return end
    local data = TIV.Deploy.GetState(veh)
    if data.state ~= "anchored" then return end

    data.plantedPos = nil
    data.anchored   = false
    if TIV.Loft and TIV.Loft.SetAnchoredImmunity then TIV.Loft.SetAnchoredImmunity(veh, false) end
    if TIV.Loft and TIV.Loft.CleanupTracking then TIV.Loft.CleanupTracking(veh:EntIndex()) end
    ApplyHandbrake(veh)
    SetState(veh, data, "retracting")

    TIV.Anchor.StartPullDown(veh, data, 0)
    TIV.Anchor.ReleaseLock(veh, data)

    if TIV.Spikes.GetCount(data) == 0 then
        TIV.Deploy.RaiseVehicle(ply, veh)
        return
    end
    TIV.Spikes.Retract(veh, data, function()
        if not IsValid(veh) or data.state ~= "retracting" then return end
        TIV.Deploy.RaiseVehicle(ply, veh)
    end)
end

-- ============================================================================
-- MID-SEQUENCE REVERSALS
-- ============================================================================
-- Pressed while the pistons are going down: pull them back, springs stay.
function TIV.Deploy.ReverseToRetracting(veh, data)
    if not IsValid(veh) or not data then return end
    SetState(veh, data, "retracting")
    TIV.Anchor.ReleaseLock(veh, data)
    if TIV.Spikes.GetCount(data) == 0 then
        TIV.Deploy.RaiseVehicle(nil, veh)
        return
    end
    TIV.Spikes.InterruptAndRetract(veh, data, function()
        if not IsValid(veh) or data.state ~= "retracting" then return end
        TIV.Deploy.RaiseVehicle(nil, veh)
    end)
end

-- Pressed during the pull-down: nothing is in the ground yet, just come up.
function TIV.Deploy.ReverseToLowering(veh, data)
    if not IsValid(veh) or not data then return end
    timer.Remove("TIV_Lower_" .. veh:EntIndex())
    TIV.Deploy.RaiseVehicle(nil, veh)
end

-- Pressed while the pistons are coming up: drive them back in. The springs
-- from StartRetract are still holding the pose.
function TIV.Deploy.ReverseToDeploying(veh, data)
    if not IsValid(veh) or not data then return end
    if not data.pullDown then TIV.Anchor.StartPullDown(veh, data, 0) end
    SetState(veh, data, "deploying_spikes")
    if TIV.Spikes.GetCount(data) == 0 then
        FinalizeAnchored(veh, data)
        return
    end
    TIV.Spikes.InterruptAndDeploy(veh, data, function()
        if not IsValid(veh) or data.state ~= "deploying_spikes" then return end
        FinalizeAnchored(veh, data)
    end)
end

function TIV.Deploy.ReverseToRaising(veh, data)
    if not IsValid(veh) or not data then return end
    timer.Remove("TIV_Raise_" .. veh:EntIndex())
    TIV.Anchor.ReleaseSprings(veh, data)
    TIV.Deploy.StartDeploy(nil, veh)
end

-- ============================================================================
-- HOOKS
-- ============================================================================
hook.Add("PlayerEnteredVehicle", "TIV_FirstEnter", function(ply, veh)
    local tivVeh = veh
    if not TIV.Deploy.IsJeep(tivVeh) then
        local parent = IsValid(veh) and veh:GetParent() or nil
        if IsValid(parent) and TIV.Deploy.IsJeep(parent) then
            tivVeh = parent
        else
            tivVeh = TIV.Deploy.ResolveVehicle(ply)
        end
    end
    if not IsValid(tivVeh) or not TIV.Deploy.IsJeep(tivVeh) then return end
    TIV.Deploy.EnsureSpikes(tivVeh, TIV.Deploy.GetState(tivVeh))
end)

hook.Add("PlayerButtonDown", "TIV_DeployBind", function(ply, button)
    if not TIV.Config or button ~= TIV.Config.DeployKey then return end
    local veh = TIV.Deploy.ResolveVehicle(ply)
    if IsValid(veh) then TIV.Deploy.HandleInput(ply, veh) end
end)

net.Receive("TIV_DeployRequest", function(_, ply)
    local veh = TIV.Deploy.ResolveVehicle(ply)
    if IsValid(veh) then TIV.Deploy.HandleInput(ply, veh) end
end)

hook.Add("PlayerDisconnected", "TIV_ForgetCooldown", function(ply)
    TIV.Deploy.Cooldowns[ply:SteamID()] = nil
end)

hook.Add("EntityRemoved", "TIV_VehicleCleanup", function(ent)
    local idx = ent:EntIndex()
    local data = TIV.Deploy.Vehicles[idx]
    if not data then return end

    timer.Remove("TIV_Lower_" .. idx)
    timer.Remove("TIV_Raise_" .. idx)
    timer.Remove("TIV_Settle_" .. idx)
    if ent.SetHandbrake then ReleaseHandbrake(ent) end
    TIV.Anchor.DetachAll(ent, data)
    TIV.Spikes.RemoveAll(data, idx)
    TIV.Deploy.Vehicles[idx] = nil

    if TIV.Wire and TIV.Wire.OnVehicleRemoved then TIV.Wire.OnVehicleRemoved(ent) end
    if TIV.CustomComponents and TIV.CustomComponents.RemoveArmorProps then TIV.CustomComponents.RemoveArmorProps(ent) end
    hook.Run("TIV_VehicleRemoved", ent)
end)

print("[TIV] Deploy system loaded")
