-- ============================================================================
-- TIV WIREMOD INTEGRATION - SERVER
-- Full Wiremod compatibility layer for Tornado Intercept Vehicles.
-- Reuses all existing TIV deployment, spike, anchor, loft, and wind systems.
-- Safe fallback when Wiremod is absent: zero errors, no overhead.
-- ============================================================================

TIV = TIV or {}
TIV.Wire = TIV.Wire or {}

-- Active controllers and telemetry caches
TIV.Wire.Controllers       = TIV.Wire.Controllers or {}       -- [vehEntIndex] = primaryControllerEntity
TIV.Wire.AllControllers    = TIV.Wire.AllControllers or {}    -- [ctrlEntIndex] = controllerEntity
TIV.Wire.VehicleFailures   = TIV.Wire.VehicleFailures or {}   -- [vehEntIndex] = { spikeFailUntil = N, anchorFailUntil = N }
TIV.Wire.DirectVehicles    = TIV.Wire.DirectVehicles or {}    -- [vehEntIndex] = veh (vehicles with direct wire ports)

local UNITS_TO_MPH = 0.0568182  -- 1 source unit/sec ~= 0.0568182 MPH
local PULSE_DURATION = 2.5      -- failure pulse duration in seconds

-- ============================================================================
-- SAFE WIREMOD DETECTION
-- ============================================================================
function TIV.Wire.IsAvailable()
    local wire = rawget(_G, "WireLib")
    if not istable(wire) then return false end
    if not isfunction(wire.CreateInputs) then return false end
    if not isfunction(wire.CreateOutputs) then return false end
    if not isfunction(wire.TriggerOutput) then return false end
    return true
end

-- ============================================================================
-- MULTIPLAYER PERMISSION VALIDATION
-- ============================================================================
function TIV.Wire.CanControl(ply, veh)
    if not IsValid(ply) then return true end -- console, map logic, environment
    if game.SinglePlayer() then return true end
    if ply:IsAdmin() then return true end
    if not IsValid(veh) then return false end

    -- Check CPPI prop protection if available
    if isfunction(veh.CPPIGetOwner) then
        local owner = veh:CPPIGetOwner()
        if not IsValid(owner) or owner == ply then return true end
        if isfunction(veh.CPPICanTool) and veh:CPPICanTool(ply, "wire") then return true end
        if isfunction(veh.CPPICanUse) and veh:CPPICanUse(ply) then return true end
        return false
    end

    -- WireLib permissions check if available
    local wire = rawget(_G, "WireLib")
    if istable(wire) and isfunction(wire.CanTool) then
        if wire.CanTool(ply, veh, "wire_vehicle") then return true end
    end

    -- Check if player is the active driver
    if isfunction(veh.GetDriver) and veh:GetDriver() == ply then return true end

    return true
end

-- ============================================================================
-- PORT DEFINITIONS
-- ============================================================================
TIV.Wire.Inputs = {
    { name = "Deploy",         type = "NORMAL", desc = "Deploy vehicle (start lower, spikes, anchor sequence) when > 0" },
    { name = "Retract",        type = "NORMAL", desc = "Retract vehicle (unanchor, retract spikes, raise vehicle) when > 0" },
    { name = "ToggleDeploy",   type = "NORMAL", desc = "Toggle between Deploy and Retract on rising edge" },
    { name = "EmergencyStop",  type = "NORMAL", desc = "Emergency stop/abort active sequence and safely recover vehicle to idle" },
    { name = "Reset",          type = "NORMAL", desc = "Emergency reset vehicle systems and recreate spikes to fresh idle state" },
    { name = "Enable",         type = "NORMAL", desc = "Enable Wire deployment control (1 = enabled, 0 = locked/disabled)" },
    { name = "ManualWind",     type = "NORMAL", desc = "Override wind simulation with manual values (1 = manual, 0 = auto)" },
    { name = "WindSpeed",      type = "NORMAL", desc = "Manual wind speed in MPH (when ManualWind is active)" },
    { name = "WindDirection",  type = "VECTOR", desc = "Manual wind direction vector (when ManualWind is active)" },
    { name = "Vehicle",        type = "ENTITY", desc = "Link controller to a specific TIV vehicle entity" },
}

TIV.Wire.Outputs = {
    -- Deployment state
    { name = "State",             type = "STRING", desc = "Current deployment state (idle, lowering, deploying_spikes, anchored, retracting, raising, lofted)" },
    { name = "IsDeployed",        type = "NORMAL", desc = "1 if vehicle is fully anchored and deployed, 0 otherwise" },
    { name = "IsDeploying",       type = "NORMAL", desc = "1 if currently in deploy sequence (lowering or deploying spikes), 0 otherwise" },
    { name = "IsRetracting",      type = "NORMAL", desc = "1 if currently in retract sequence (retracting spikes or raising), 0 otherwise" },
    { name = "IsAnchored",        type = "NORMAL", desc = "1 if anchored, 0 otherwise" },
    { name = "IsIdle",            type = "NORMAL", desc = "1 if completely idle and ready for deploy, 0 otherwise" },

    -- Vehicle telemetry
    { name = "Speed",             type = "NORMAL", desc = "Vehicle ground speed in MPH" },
    { name = "Altitude",          type = "NORMAL", desc = "Vehicle altitude (Z position in world units)" },
    { name = "VerticalVelocity",  type = "NORMAL", desc = "Vehicle vertical velocity in MPH" },
    { name = "Health",            type = "NORMAL", desc = "Vehicle current health" },
    { name = "Vehicle",           type = "ENTITY", desc = "The linked TIV vehicle entity" },

    -- Wind telemetry
    { name = "WindSpeed",         type = "NORMAL", desc = "Current wind speed at vehicle in MPH" },
    { name = "WindDirection",     type = "VECTOR", desc = "Current wind direction vector at vehicle" },
    { name = "WindX",             type = "NORMAL", desc = "Wind direction vector X component" },
    { name = "WindY",             type = "NORMAL", desc = "Wind direction vector Y component" },
    { name = "WindZ",             type = "NORMAL", desc = "Wind direction vector Z component" },

    -- Spikes & anchors
    { name = "SpikeCount",        type = "NORMAL", desc = "Total number of spikes installed on vehicle" },
    { name = "ActiveSpikes",      type = "NORMAL", desc = "Number of intact and deployed spikes" },
    { name = "SpikeState",        type = "STRING", desc = "Current overall spike state (idle, deploying, deployed, retracting, none)" },
    { name = "AnchorCount",       type = "NORMAL", desc = "Number of active vehicle-to-spike ballsocket constraints" },
    { name = "ConstraintCount",   type = "NORMAL", desc = "Total active constraints (ballsockets, world anchors, nocollides)" },
    { name = "AnchorIntegrity",   type = "NORMAL", desc = "1 if anchor constraints are holding, 0 if compromised or broken" },

    -- Individual spike statuses
    { name = "Spike1",            type = "NORMAL", desc = "Spike 1 status (1 = deployed/active, 0 = inactive/broken)" },
    { name = "Spike2",            type = "NORMAL", desc = "Spike 2 status (1 = deployed/active, 0 = inactive/broken)" },
    { name = "Spike3",            type = "NORMAL", desc = "Spike 3 status (1 = deployed/active, 0 = inactive/broken)" },
    { name = "Spike4",            type = "NORMAL", desc = "Spike 4 status (1 = deployed/active, 0 = inactive/broken)" },
    { name = "Spike5",            type = "NORMAL", desc = "Spike 5 status (1 = deployed/active, 0 = inactive/broken)" },
    { name = "Spike6",            type = "NORMAL", desc = "Spike 6 status (1 = deployed/active, 0 = inactive/broken)" },

    -- Stress & loft
    { name = "Stress",            type = "NORMAL", desc = "Wind stress ratio on anchors (0.0 to 1.0)" },
    { name = "LoftRisk",          type = "NORMAL", desc = "1 if vehicle is at high risk of lofting (stress >= 0.7 or wind >= threshold)" },
    { name = "IsLofted",          type = "NORMAL", desc = "1 if vehicle has been lofted into the air by a tornado, 0 otherwise" },

    -- Damage & failure warnings
    { name = "AnchorFailure",        type = "NORMAL", desc = "Pulsed to 1 when an anchor ballsocket fails" },
    { name = "SpikeFailure",         type = "NORMAL", desc = "Pulsed to 1 when a spike fails or breaks off" },
    { name = "SystemFailure",        type = "NORMAL", desc = "1 if overall anchor integrity failed or emergency loft in progress" },
    { name = "EmergencyState",       type = "NORMAL", desc = "1 if vehicle is in an emergency state (directional failure or lofted)" },

    -- Progression & upgrades
    { name = "Points",               type = "NORMAL", desc = "Spendable upgrade points balance" },
    { name = "TotalPoints",          type = "NORMAL", desc = "Lifetime career points earned" },
    { name = "Intercepts",           type = "NORMAL", desc = "Total count of successful tornado intercepts" },
    { name = "CurrentIntercepts",    type = "NORMAL", desc = "Spendable points balance (legacy alias)" },
    { name = "TotalIntercepts",      type = "NORMAL", desc = "Total career intercepts (legacy alias)" },
    { name = "UpgradeCount",         type = "NORMAL", desc = "Number of purchased upgrades" },
    { name = "UnlockedUpgrades",     type = "STRING", desc = "Comma-separated string of unlocked upgrade IDs" },
    { name = "HasAngledSpikes",      type = "NORMAL", desc = "1 if Angled Spikes upgrade unlocked, 0 otherwise" },
    { name = "HasSideArmor",         type = "NORMAL", desc = "1 if Side Armor Panels upgrade unlocked, 0 otherwise" },
    { name = "HasFrontArmor",        type = "NORMAL", desc = "1 if Front Armor Panels upgrade unlocked, 0 otherwise" },
    { name = "HasPathScreen",        type = "NORMAL", desc = "1 if Tactical Path Prediction Screen upgrade unlocked, 0 otherwise" },

    -- Armor & protection
    { name = "ArmorCount",           type = "NORMAL", desc = "Number of active armor panels installed on vehicle" },
    { name = "ArmorProtection",      type = "NORMAL", desc = "Total kinetic impact protection percentage (0 to 100)" },
    { name = "LoftThreshold",        type = "NORMAL", desc = "Effective loft wind threshold in MPH including all upgrades and armor" },
    { name = "WindResistanceScale",  type = "NORMAL", desc = "Effective aerodynamic wind resistance drag factor (lower = better)" },

    -- Tornado path & radar tracking
    { name = "TornadoDetected",      type = "NORMAL", desc = "1 if an active tornado is within detection range, 0 otherwise" },
    { name = "TornadoDistance",      type = "NORMAL", desc = "Distance to nearest tornado in Source hammer units" },
    { name = "TornadoDistanceM",     type = "NORMAL", desc = "Distance to nearest tornado in meters" },
    { name = "TornadoBearing",       type = "NORMAL", desc = "Compass bearing from vehicle to tornado (0-360 degrees)" },
    { name = "TornadoSpeed",         type = "NORMAL", desc = "Translational movement speed of tornado in MPH" },
    { name = "TornadoETA",           type = "NORMAL", desc = "Estimated seconds until tornado closest point of approach" },
    { name = "TornadoCoreRadius",    type = "NORMAL", desc = "Radius of tornado core / maximum wind zone in units" },
    { name = "TornadoOuterRadius",   type = "NORMAL", desc = "Radius of tornado outer circulation in units" },
    { name = "TornadoImpactType",    type = "NORMAL", desc = "Impact classification: 0=receding/clear, 1=miss, 2=side sweep, 3=direct core hit" },
    { name = "TornadoPathX",         type = "NORMAL", desc = "Predicted trajectory vector X component" },
    { name = "TornadoPathY",         type = "NORMAL", desc = "Predicted trajectory vector Y component" },
}

-- Pre-build formatted port and desc lists for WireLib
TIV.Wire.InputNames = {}
TIV.Wire.InputDescs = {}
for i, port in ipairs(TIV.Wire.Inputs) do
    TIV.Wire.InputNames[i] = (port.type == "NORMAL") and port.name or string.format("%s [%s]", port.name, port.type)
    TIV.Wire.InputDescs[i] = port.desc
end

TIV.Wire.OutputNames = {}
TIV.Wire.OutputDescs = {}
for i, port in ipairs(TIV.Wire.Outputs) do
    TIV.Wire.OutputNames[i] = (port.type == "NORMAL") and port.name or string.format("%s [%s]", port.name, port.type)
    TIV.Wire.OutputDescs[i] = port.desc
end

-- ============================================================================
-- PORT SETUP
-- ============================================================================
function TIV.Wire.SetupPorts(ent)
    if not TIV.Wire.IsAvailable() or not IsValid(ent) then return end
    WireLib.CreateInputs(ent, TIV.Wire.InputNames, TIV.Wire.InputDescs)
    WireLib.CreateOutputs(ent, TIV.Wire.OutputNames, TIV.Wire.OutputDescs)
    ent._tivLastOutputs = {}
end

-- ============================================================================
-- CACHED OUTPUT TRIGGER (Reduces redundant networking)
-- ============================================================================
local function ValuesDiffer(lastVal, newVal)
    if lastVal == nil then return true end
    if isvector(lastVal) and isvector(newVal) then
        return lastVal:DistToSqr(newVal) > 0.0001
    end
    return lastVal ~= newVal
end

function TIV.Wire.TriggerCachedOutput(ent, name, value)
    if not IsValid(ent) or not ent.Outputs or not ent.Outputs[name] then return end
    ent._tivLastOutputs = ent._tivLastOutputs or {}

    local lastVal = ent._tivLastOutputs[name]
    if ValuesDiffer(lastVal, value) then
        if isvector(value) then
            ent._tivLastOutputs[name] = Vector(value.x, value.y, value.z)
        else
            ent._tivLastOutputs[name] = value
        end
        WireLib.TriggerOutput(ent, name, value)
    end
end

-- ============================================================================
-- EMERGENCY STOP
-- Halts any in-progress deployment/retraction, restores physics motion,
-- unanchors safely, reparents spikes, and returns vehicle to idle.
-- ============================================================================
function TIV.Wire.EmergencyStop(veh)
    if not IsValid(veh) then return end
    local entIdx = veh:EntIndex()
    local data   = TIV.Deploy.GetState(veh)
    if not data then return end

    -- Cancel lower/raise timers
    timer.Remove("TIV_Lower_" .. entIdx)
    timer.Remove("TIV_Raise_" .. entIdx)

    -- Cancel any active spike animation jobs for this session
    if data.sessionID and TIV.SpikeAnim and TIV.SpikeAnim.ActiveJobs then
        local prefix = data.sessionID .. "_"
        for jobKey in pairs(TIV.SpikeAnim.ActiveJobs) do
            if string.sub(jobKey, 1, #prefix) == prefix then
                TIV.SpikeAnim.ActiveJobs[jobKey] = nil
            end
        end
    end

    -- Detach all anchor constraints
    TIV.Anchor.DetachAll(veh, data)
    data.anchored = false

    -- Release handbrake
    if veh.SetHandbrake then veh:SetHandbrake(false) end

    -- Reparent any deployed or loose spikes back to the vehicle
    for _, sd in ipairs(data.spikes or {}) do
        if IsValid(sd.entity) and TIV.SpikeAnim and TIV.SpikeAnim.ReparentSpike then
            TIV.SpikeAnim.ReparentSpike(veh, sd.entity, sd)
        end
        if data.spikeAnims and sd.index then
            data.spikeAnims[sd.index] = "idle"
        end
    end

    -- Restore vehicle physics
    local phys = veh:GetPhysicsObject()
    if IsValid(phys) then
        phys:EnableGravity(true)
        phys:EnableMotion(true)
        phys:Wake()
    end

    data.state            = "idle"
    data.gravityReleased  = false

    if TIV.Loft and TIV.Loft.CleanupTracking then
        TIV.Loft.CleanupTracking(entIdx)
    end

    TIV.Deploy.BroadcastState(veh, "idle")
    TIV.Wire.UpdateOutputs(veh)
end

-- ============================================================================
-- RESET
-- Fully restores vehicle and spikes to fresh idle state.
-- ============================================================================
function TIV.Wire.Reset(veh)
    if not IsValid(veh) then return end
    local entIdx = veh:EntIndex()
    local data   = TIV.Deploy.GetState(veh)
    if not data then return end

    TIV.Wire.EmergencyStop(veh)

    -- Remove existing spikes and recreate them clean
    TIV.Spikes.RemoveAll(data, entIdx)
    data.spikesCreated = false

    TIV.Deploy.EnsureSpikes(veh, data)

    -- Clear failure pulses
    TIV.Wire.VehicleFailures[entIdx] = nil
    timer.Remove("TIV_Wire_PulseReset_" .. entIdx)

    TIV.Deploy.BroadcastState(veh, "idle")
    TIV.Wire.UpdateOutputs(veh)
end

-- ============================================================================
-- INPUT HANDLER
-- Processes inputs from Wire controllers or directly wired vehicles.
-- Calls existing TIV logic as the single source of truth.
-- ============================================================================
function TIV.Wire.HandleInput(sourceEnt, iname, value, veh)
    if not IsValid(sourceEnt) then return end

    -- Normalize aliases
    if iname == "Toggle" then iname = "ToggleDeploy" end
    if iname == "Stop" then iname = "EmergencyStop" end

    -- Entity linking input
    if iname == "Vehicle" then
        if isentity(value) and IsValid(value) and TIV.IsSupportedVehicle(value) then
            if sourceEnt.LinkEnt then sourceEnt:LinkEnt(value) end
        elseif not IsValid(value) then
            if sourceEnt.UnlinkEnt then sourceEnt:UnlinkEnt() end
        end
        return
    end

    -- Controller enable/disable lockout
    if iname == "Enable" then
        sourceEnt._wireEnabled = (value ~= 0)
        return
    elseif iname == "Disable" then
        sourceEnt._wireEnabled = (value == 0)
        return
    end

    -- Manual wind inputs
    if iname == "ManualWind" then
        sourceEnt._manualWindActive = (value ~= 0)
        if sourceEnt._manualWindActive then
            local spd = sourceEnt._manualWindSpeed or 0
            TIV.Wind.SetSpeed(spd)
            if sourceEnt._manualWindDir then
                TIV.Wind.SetDirection(sourceEnt._manualWindDir)
            end
        else
            TIV.Wind.ClearManual()
        end
        return
    elseif iname == "WindSpeed" then
        if isnumber(value) and value == value and value >= 0 then
            sourceEnt._manualWindSpeed = math.Clamp(value, 0, TIV.Config.WindMaxSimulated or 350)
            if sourceEnt._manualWindActive then
                TIV.Wind.SetSpeed(sourceEnt._manualWindSpeed)
            end
        end
        return
    elseif iname == "WindDirection" then
        if isvector(value) and value:LengthSqr() > 0.001 then
            sourceEnt._manualWindDir = value:GetNormalized()
            if sourceEnt._manualWindActive then
                TIV.Wind.SetDirection(sourceEnt._manualWindDir)
            end
        end
        return
    end

    -- Deployment commands require a valid TIV vehicle
    veh = veh or sourceEnt.Vehicle
    if not IsValid(veh) or not TIV.IsSupportedVehicle(veh) then return end

    -- Check if wire control is disabled on this controller
    if sourceEnt._wireEnabled == false then return end

    -- Multiplayer permissions validation
    local ply = (sourceEnt.GetPlayer and sourceEnt:GetPlayer()) or nil
    if IsValid(ply) and not TIV.Wire.CanControl(ply, veh) then return end

    local data = TIV.Deploy.GetState(veh)
    if not data then return end

    sourceEnt._lastInputs = sourceEnt._lastInputs or {}
    local prevVal = sourceEnt._lastInputs[iname] or 0
    sourceEnt._lastInputs[iname] = value

    if iname == "Deploy" then
        -- Rising edge: value > 0 and was <= 0
        if value > 0 and prevVal <= 0 then
            TIV.Deploy.EnsureSpikes(veh, data)
            if data.state == "idle" then
                TIV.Deploy.StartDeploy(ply, veh)
            end
        end
    elseif iname == "Retract" then
        -- Rising edge
        if value > 0 and prevVal <= 0 then
            if data.state == "anchored" then
                TIV.Deploy.StartRetract(ply, veh)
            end
        end
    elseif iname == "ToggleDeploy" then
        -- Rising edge: toggle between idle deploy and anchored retract
        if value > 0 and prevVal <= 0 then
            TIV.Deploy.EnsureSpikes(veh, data)
            if data.state == "idle" then
                TIV.Deploy.StartDeploy(ply, veh)
            elseif data.state == "anchored" then
                TIV.Deploy.StartRetract(ply, veh)
            end
        end
    elseif iname == "EmergencyStop" then
        if value > 0 and prevVal <= 0 then
            TIV.Wire.EmergencyStop(veh)
        end
    elseif iname == "Reset" then
        if value > 0 and prevVal <= 0 then
            TIV.Wire.Reset(veh)
        end
    end
end

-- ============================================================================
-- OUTPUT UPDATE
-- Queries authoritative TIV state and triggers outputs on all linked devices.
-- ============================================================================
function TIV.Wire.UpdateOutputs(veh)
    if not IsValid(veh) then return end
    if not TIV.Wire.IsAvailable() then return end

    local entIdx = veh:EntIndex()
    local data   = TIV.Deploy.GetState(veh)
    if not data then return end

    -- Collect all targets associated with this vehicle (controller + direct vehicle)
    local targets = {}
    local primaryCtrl = TIV.Wire.Controllers[entIdx]
    if IsValid(primaryCtrl) then table.insert(targets, primaryCtrl) end

    for _, ctrl in pairs(TIV.Wire.AllControllers) do
        if IsValid(ctrl) and ctrl ~= primaryCtrl and ctrl.Vehicle == veh then
            table.insert(targets, ctrl)
        end
    end

    if TIV.Wire.DirectVehicles[entIdx] and IsValid(veh) then
        table.insert(targets, veh)
    end

    if #targets == 0 then return end

    -- Telemetry: Speed & Velocity
    local phys = veh:GetPhysicsObject()
    local speed = 0
    local velZ = 0
    local altitude = veh:GetPos().z

    if IsValid(phys) then
        local vel = phys:GetVelocity()
        speed = vel:Length() * UNITS_TO_MPH
        velZ  = vel.z * UNITS_TO_MPH
    end

    -- Telemetry: Health
    local health = veh:Health()
    if health <= 0 and veh.GetMaxHealth and veh:GetMaxHealth() > 0 then
        health = veh:GetMaxHealth()
    end
    if health <= 0 then health = 100 end

    -- Telemetry: Wind
    local windSpeed = TIV.Wind.GetSpeed(veh) or 0
    local windDir   = TIV.Wind.GetDirection(veh) or Vector(1, 0, 0)

    -- State flags
    local state        = data.state or "idle"
    local isDeployed   = (state == "anchored") and 1 or 0
    local isDeploying  = (state == "lowering" or state == "deploying_spikes") and 1 or 0
    local isRetracting = (state == "retracting" or state == "raising") and 1 or 0
    local isAnchored   = (state == "anchored") and 1 or 0
    local isIdle       = (state == "idle") and 1 or 0
    local isLofted     = (state == "lofted") and 1 or 0

    -- Spikes & constraints
    local counts       = TIV.Anchor.GetCounts(data)
    local totalSpikes  = TIV.Spikes.GetCount(data)
    local spikeState   = TIV.Spikes.GetState(data)
    local anchorCount  = counts.ballsockets or 0
    local constrCount  = counts.total or 0

    local anchorIntegrity = (isAnchored == 1) and (TIV.Anchor.CheckIntegrity(veh, data) and 1 or 0) or 1

    -- Per-spike statuses
    local activeSpikes = 0
    local spikeStatus = { 0, 0, 0, 0, 0, 0 }
    for _, sd in ipairs(data.spikes or {}) do
        if IsValid(sd.entity) and sd.phase == "deployed" then
            activeSpikes = activeSpikes + 1
            if sd.index and sd.index >= 1 and sd.index <= 6 then
                spikeStatus[sd.index] = 1
            end
        end
    end

    -- Stress & loft risk
    local stress = (isAnchored == 1) and (TIV.Loft and TIV.Loft.CalculateStress and TIV.Loft.CalculateStress(windSpeed, veh) or 0) or 0
    local loftRisk = ((isAnchored == 1) and (stress >= 0.7 or windSpeed >= (TIV.Config.LoftWindThreshold or 160))) and 1 or 0

    -- Failure warnings
    local failData = TIV.Wire.VehicleFailures[entIdx] or {}
    local now = CurTime()
    local anchorFailure  = (failData.anchorFailUntil and now < failData.anchorFailUntil) and 1 or 0
    local spikeFailure   = (failData.spikeFailUntil and now < failData.spikeFailUntil) and 1 or 0
    local systemFailure  = (isLofted == 1 or (isAnchored == 1 and anchorIntegrity == 0)) and 1 or 0
    local emergencyState = (isLofted == 1 or (TIV.Loft.FailingGroups and TIV.Loft.FailingGroups[entIdx])) and 1 or 0

    -- Dispatch to all targets
    for _, target in ipairs(targets) do
        local trigger = TIV.Wire.TriggerCachedOutput
        trigger(target, "State", state)
        trigger(target, "IsDeployed", isDeployed)
        trigger(target, "IsDeploying", isDeploying)
        trigger(target, "IsRetracting", isRetracting)
        trigger(target, "IsAnchored", isAnchored)
        trigger(target, "IsIdle", isIdle)

        trigger(target, "Speed", speed)
        trigger(target, "Altitude", altitude)
        trigger(target, "VerticalVelocity", velZ)
        trigger(target, "Health", health)
        trigger(target, "Vehicle", veh)

        trigger(target, "WindSpeed", windSpeed)
        trigger(target, "WindDirection", windDir)
        trigger(target, "WindX", windDir.x)
        trigger(target, "WindY", windDir.y)
        trigger(target, "WindZ", windDir.z)

        trigger(target, "SpikeCount", totalSpikes)
        trigger(target, "ActiveSpikes", activeSpikes)
        trigger(target, "SpikeState", spikeState)
        trigger(target, "AnchorCount", anchorCount)
        trigger(target, "ConstraintCount", constrCount)
        trigger(target, "AnchorIntegrity", anchorIntegrity)

        trigger(target, "Spike1", spikeStatus[1])
        trigger(target, "Spike2", spikeStatus[2])
        trigger(target, "Spike3", spikeStatus[3])
        trigger(target, "Spike4", spikeStatus[4])
        trigger(target, "Spike5", spikeStatus[5])
        trigger(target, "Spike6", spikeStatus[6])

        trigger(target, "Stress", stress)
        trigger(target, "LoftRisk", loftRisk)
        trigger(target, "IsLofted", isLofted)

        trigger(target, "AnchorFailure", anchorFailure)
        trigger(target, "SpikeFailure", spikeFailure)
        trigger(target, "SystemFailure", systemFailure)
        trigger(target, "EmergencyState", emergencyState)

        -- Progression & upgrades
        local driver = veh.GetDriver and veh:GetDriver() or nil
        if not IsValid(driver) then
            for _, p in ipairs(player.GetAll()) do
                if IsValid(p) then
                    local pVeh = p:GetVehicle()
                    if IsValid(pVeh) and (pVeh == veh or (IsValid(pVeh:GetParent()) and pVeh:GetParent() == veh)) then
                        driver = p
                        break
                    end
                end
            end
        end

        local points            = 0
        local totalPoints       = 0
        local intercepts        = 0
        local upgradeCount      = 0
        local unlockedStr       = ""
        local hasAngled         = 0
        local hasSideArmor      = 0
        local hasFrontArmor     = 0
        local hasPathScreen     = 0

        if IsValid(driver) and TIV.Progression and TIV.Progression.GetPlayerProfile then
            local prof = TIV.Progression.GetPlayerProfile(driver)
            if prof then
                points        = prof.points or prof.current_intercepts or 0
                totalPoints   = prof.total_points or prof.points or 0
                intercepts    = prof.intercepts or prof.total_intercepts or 0
                local unlockedList = {}
                for id, state in pairs(prof.unlocked_upgrades or {}) do
                    if state then
                        table.insert(unlockedList, id)
                        upgradeCount = upgradeCount + 1
                    end
                end
                unlockedStr   = table.concat(unlockedList, ",")
                hasAngled     = (prof.unlocked_upgrades and prof.unlocked_upgrades["angled_spikes"]) and 1 or 0
                hasSideArmor  = (prof.unlocked_upgrades and prof.unlocked_upgrades["side_armor"]) and 1 or 0
                hasFrontArmor = (prof.unlocked_upgrades and prof.unlocked_upgrades["front_armor"]) and 1 or 0
                hasPathScreen = (prof.unlocked_upgrades and prof.unlocked_upgrades["path_screen"]) and 1 or 0
            end
        end

        local stats = veh._TIVEffectiveStats or {}
        local armorCount     = stats.total_armor_count or (veh._TIVArmorProps and #veh._TIVArmorProps) or 0
        local armorProt      = math.Round((stats.impact_reduction or 0) * 100)
        local loftThreshold  = stats.effective_loft_mph or (TIV.Config and TIV.Config.LoftWindThreshold) or 180
        local windResistScale= math.Round((stats.wind_force_mult or 1.0), 2)

        trigger(target, "Points",              points)
        trigger(target, "TotalPoints",         totalPoints)
        trigger(target, "Intercepts",          intercepts)
        trigger(target, "CurrentIntercepts",   points)
        trigger(target, "TotalIntercepts",     intercepts)
        trigger(target, "UpgradeCount",        upgradeCount)
        trigger(target, "UnlockedUpgrades",    unlockedStr)
        trigger(target, "HasAngledSpikes",     hasAngled)
        trigger(target, "HasSideArmor",        hasSideArmor)
        trigger(target, "HasFrontArmor",       hasFrontArmor)
        trigger(target, "HasPathScreen",       hasPathScreen)

        trigger(target, "ArmorCount",          armorCount)
        trigger(target, "ArmorProtection",     armorProt)
        trigger(target, "LoftThreshold",       loftThreshold)
        trigger(target, "WindResistanceScale", windResistScale)

        -- Tornado path & radar tracking
        local tInfo = TIV.Wind and TIV.Wind.GetNearestActiveTornado and TIV.Wind.GetNearestActiveTornado(veh:GetPos())
        if tInfo then
            trigger(target, "TornadoDetected", 1)
            trigger(target, "TornadoDistance", tInfo.dist)
            trigger(target, "TornadoDistanceM", math.Round(tInfo.dist * 0.01905, 1))
            trigger(target, "TornadoBearing", math.Round(tInfo.bearing, 1))
            trigger(target, "TornadoSpeed", math.Round(tInfo.speedMPH, 1))
            trigger(target, "TornadoETA", math.Round(tInfo.eta, 1))
            trigger(target, "TornadoCoreRadius", math.Round(tInfo.coreRadius, 1))
            trigger(target, "TornadoOuterRadius", math.Round(tInfo.outerRadius, 1))
            local impactCode = (tInfo.impactType == "core") and 3 or ((tInfo.impactType == "side") and 2 or ((tInfo.impactType == "miss") and 1 or 0))
            trigger(target, "TornadoImpactType", impactCode)
            trigger(target, "TornadoPathX", tInfo.heading.x)
            trigger(target, "TornadoPathY", tInfo.heading.y)
        else
            trigger(target, "TornadoDetected", 0)
            trigger(target, "TornadoDistance", 0)
            trigger(target, "TornadoDistanceM", 0)
            trigger(target, "TornadoBearing", 0)
            trigger(target, "TornadoSpeed", 0)
            trigger(target, "TornadoETA", 0)
            trigger(target, "TornadoCoreRadius", 0)
            trigger(target, "TornadoOuterRadius", 0)
            trigger(target, "TornadoImpactType", 0)
            trigger(target, "TornadoPathX", 0)
            trigger(target, "TornadoPathY", 0)
        end
    end
end

-- ============================================================================
-- RESET OUTPUTS FOR UNLINKED CONTROLLER
-- ============================================================================
function TIV.Wire.ResetOutputsForEnt(ent)
    if not IsValid(ent) or not TIV.Wire.IsAvailable() then return end
    local trigger = TIV.Wire.TriggerCachedOutput
    trigger(ent, "State", "idle")
    trigger(ent, "IsDeployed", 0)
    trigger(ent, "IsDeploying", 0)
    trigger(ent, "IsRetracting", 0)
    trigger(ent, "IsAnchored", 0)
    trigger(ent, "IsIdle", 1)

    trigger(ent, "Speed", 0)
    trigger(ent, "Altitude", 0)
    trigger(ent, "VerticalVelocity", 0)
    trigger(ent, "Health", 0)
    trigger(ent, "Vehicle", NULL)

    trigger(ent, "WindSpeed", 0)
    trigger(ent, "WindDirection", Vector(1, 0, 0))
    trigger(ent, "WindX", 1)
    trigger(ent, "WindY", 0)
    trigger(ent, "WindZ", 0)

    trigger(ent, "SpikeCount", 0)
    trigger(ent, "ActiveSpikes", 0)
    trigger(ent, "SpikeState", "none")
    trigger(ent, "AnchorCount", 0)
    trigger(ent, "ConstraintCount", 0)
    trigger(ent, "AnchorIntegrity", 1)

    for i = 1, 6 do trigger(ent, "Spike" .. i, 0) end

    trigger(ent, "Stress", 0)
    trigger(ent, "LoftRisk", 0)
    trigger(ent, "IsLofted", 0)

    trigger(ent, "AnchorFailure", 0)
    trigger(ent, "SpikeFailure", 0)
    trigger(ent, "SystemFailure", 0)
    trigger(ent, "EmergencyState", 0)

    trigger(ent, "CurrentIntercepts",   0)
    trigger(ent, "TotalIntercepts",     0)
    trigger(ent, "UpgradeCount",        0)
    trigger(ent, "UnlockedUpgrades",    "")
    trigger(ent, "HasAngledSpikes",     0)
    trigger(ent, "HasSideArmor",        0)
    trigger(ent, "HasFrontArmor",       0)

    trigger(ent, "ArmorCount",          0)
    trigger(ent, "ArmorProtection",     0)
    trigger(ent, "LoftThreshold",       180)
    trigger(ent, "WindResistanceScale", 1.0)
end

-- ============================================================================
-- CONTROLLER LIFECYCLE MANAGEMENT
-- Automatically creates and links an internal Wire controller entity.
-- ============================================================================
function TIV.Wire.GetControllerOffset(veh)
    if not IsValid(veh) then return Vector(0, 15, 36), Angle(0, -90, 0) end
    local offsets = (TIV.Config and TIV.Config.WireControllerOffsets) or {}
    local class = string.lower(veh:GetClass() or "")
    local model = string.lower(veh:GetModel() or "")

    if class == "prop_vehicle_apc" or string.find(model, "apc", 1, true) then
        local o = offsets.prop_vehicle_apc
        if o then return o.pos, o.ang end
        return Vector(0, 35, 50), Angle(0, -90, 0)
    end
    if class == "prop_vehicle_jalopy" or string.find(model, "jalopy", 1, true) then
        local o = offsets.jalopy
        if o then return o.pos, o.ang end
        return Vector(0, 15, 36), Angle(0, -90, 0)
    end

    local o = offsets.jeep
    if o then return o.pos, o.ang end
    return Vector(0, 15, 36), Angle(0, -90, 0)
end

function TIV.Wire.EnsureController(veh)
    if not TIV.Wire.IsAvailable() then return nil end
    if not IsValid(veh) or not TIV.IsSupportedVehicle(veh) then return nil end

    local autoCVar = GetConVar("tiv_wire_auto_controller")
    if autoCVar and not autoCVar:GetBool() then return nil end

    local entIdx = veh:EntIndex()

    -- Also setup direct wire ports on the vehicle body for maximum convenience
    if not veh._TIVWired then
        veh._TIVWired = true
        TIV.Wire.SetupPorts(veh)
        veh.TriggerInput = function(self, iname, value)
            TIV.Wire.HandleInput(self, iname, value, self)
        end
        TIV.Wire.DirectVehicles[entIdx] = veh
    end

    -- Return existing valid controller
    if IsValid(veh.TIVWireController) then
        return veh.TIVWireController
    end

    local existing = TIV.Wire.Controllers[entIdx]
    if IsValid(existing) then
        veh.TIVWireController = existing
        return existing
    end

    -- Create dedicated Wire controller entity
    local controller = ents.Create("gmod_wire_tiv_controller")
    if not IsValid(controller) then return nil end

    local sirenModel = "models/jaanus/wiretool/wiretool_siren.mdl"
    local fallbackModel = "models/props_lab/reciever01a.mdl"
    controller:SetModel(util.IsValidModel(sirenModel) and sirenModel or fallbackModel)

    local localPos, localAng = TIV.Wire.GetControllerOffset(veh)
    local worldPos = veh:LocalToWorld(localPos)
    local worldAng = veh:LocalToWorldAngles(localAng)

    controller:SetPos(worldPos)
    controller:SetAngles(worldAng)
    controller:Spawn()
    controller:Activate()

    controller:SetParent(veh)
    controller:SetLocalPos(localPos)
    controller:SetLocalAngles(localAng)

    -- Prevent interference with physics/movement
    local colGroup = COLLISION_GROUP_WORLD or 20
    controller:SetCollisionGroup(colGroup)
    local phys = controller:GetPhysicsObject()
    if IsValid(phys) then
        phys:EnableCollisions(false)
        phys:EnableMotion(false)
    end
    if constraint and constraint.NoCollide then
        constraint.NoCollide(veh, controller, 0, 0)
    end

    -- Apply visibility setting
    local hideCVar = GetConVar("tiv_wire_hide_controller")
    local hidden = hideCVar and hideCVar:GetBool() or false
    controller:SetNoDraw(hidden)
    controller:DrawShadow(not hidden)

    controller.IsAutoAttached = true
    controller.DoNotDuplicate = true
    controller:LinkEnt(veh)

    veh.TIVWireController = controller
    TIV.Wire.Controllers[entIdx] = controller

    return controller
end

function TIV.Wire.UpdateControllerVisibility(hidden)
    for _, ctrl in pairs(TIV.Wire.AllControllers) do
        if IsValid(ctrl) and ctrl.IsAutoAttached then
            ctrl:SetNoDraw(hidden)
            ctrl:DrawShadow(not hidden)
        end
    end
end

function TIV.Wire.RegisterController(ctrl, veh)
    if not IsValid(ctrl) then return end
    local ctrlIdx = ctrl:EntIndex()
    TIV.Wire.AllControllers[ctrlIdx] = ctrl

    if IsValid(veh) then
        local vehIdx = veh:EntIndex()
        if not IsValid(TIV.Wire.Controllers[vehIdx]) then
            TIV.Wire.Controllers[vehIdx] = ctrl
        end
    end
end

function TIV.Wire.UnregisterController(ctrl)
    if not IsValid(ctrl) then return end
    local ctrlIdx = ctrl:EntIndex()
    TIV.Wire.AllControllers[ctrlIdx] = nil

    for vehIdx, c in pairs(TIV.Wire.Controllers) do
        if c == ctrl then
            TIV.Wire.Controllers[vehIdx] = nil
        end
    end
end

-- ============================================================================
-- VEHICLE REMOVAL CLEANUP
-- ============================================================================
function TIV.Wire.OnVehicleRemoved(veh)
    if not IsValid(veh) then return end
    local entIdx = veh:EntIndex()

    -- Remove auto-attached controller
    if IsValid(veh.TIVWireController) then
        SafeRemoveEntity(veh.TIVWireController)
        veh.TIVWireController = nil
    end

    -- Clean up any direct wires to the vehicle
    local wire = rawget(_G, "WireLib")
    if istable(wire) and isfunction(wire.Remove) then
        wire.Remove(veh)
    end

    -- Unlink external controllers
    for ctrlIdx, ctrl in pairs(TIV.Wire.AllControllers) do
        if IsValid(ctrl) and ctrl.Vehicle == veh then
            ctrl:UnlinkEnt()
        end
    end

    TIV.Wire.Controllers[entIdx]     = nil
    TIV.Wire.DirectVehicles[entIdx]  = nil
    TIV.Wire.VehicleFailures[entIdx] = nil

    timer.Remove("TIV_Wire_PulseReset_" .. entIdx)
end

-- ============================================================================
-- EVENT HOOKS
-- ============================================================================

-- State changes
hook.Add("TIV_StateChanged", "TIV_Wire_StateChanged", function(veh, state)
    if not IsValid(veh) then return end
    TIV.Wire.UpdateOutputs(veh)
end)

-- Spike failure pulse
hook.Add("TIV_SpikeFailure", "TIV_Wire_SpikeFailure", function(veh, spikeIdx)
    if not IsValid(veh) then return end
    local entIdx = veh:EntIndex()
    TIV.Wire.VehicleFailures[entIdx] = TIV.Wire.VehicleFailures[entIdx] or {}
    TIV.Wire.VehicleFailures[entIdx].spikeFailUntil  = CurTime() + PULSE_DURATION
    TIV.Wire.VehicleFailures[entIdx].anchorFailUntil = CurTime() + PULSE_DURATION

    TIV.Wire.UpdateOutputs(veh)

    timer.Create("TIV_Wire_PulseReset_" .. entIdx, PULSE_DURATION + 0.1, 1, function()
        local liveVeh = Entity(entIdx)
        if IsValid(liveVeh) then
            TIV.Wire.UpdateOutputs(liveVeh)
        end
    end)
end)

-- Loft event
hook.Add("TIV_LoftEvent", "TIV_Wire_LoftEvent", function(veh)
    if not IsValid(veh) then return end
    TIV.Wire.UpdateOutputs(veh)
end)

-- Entity created
hook.Add("OnEntityCreated", "TIV_Wire_OnEntityCreated", function(ent)
    if not IsValid(ent) then return end
    timer.Simple(0.1, function()
        if IsValid(ent) and TIV.IsSupportedVehicle and TIV.IsSupportedVehicle(ent) then
            TIV.Wire.EnsureController(ent)
        end
    end)
end)

-- Player entered vehicle
hook.Add("PlayerEnteredVehicle", "TIV_Wire_PlayerEnter", function(ply, veh)
    local tivVeh = veh
    if TIV.Deploy and TIV.Deploy.IsJeep and not TIV.Deploy.IsJeep(tivVeh) then
        local parent = IsValid(veh) and veh:GetParent() or nil
        if IsValid(parent) and TIV.Deploy.IsJeep(parent) then
            tivVeh = parent
        else
            tivVeh = TIV.Deploy.ResolveVehicle and TIV.Deploy.ResolveVehicle(ply) or ply:GetVehicle()
        end
    end
    if IsValid(tivVeh) then
        TIV.Wire.EnsureController(tivVeh)
    end
end)

-- 10 Hz telemetry update for active wired TIV vehicles
timer.Create("TIV_WireTelemetryUpdate", 0.1, 0, function()
    if not TIV.Wire.IsAvailable() then return end

    local visited = {}
    for entIdx, ctrl in pairs(TIV.Wire.Controllers) do
        local veh = Entity(entIdx)
        if IsValid(veh) then
            visited[entIdx] = true
            TIV.Wire.UpdateOutputs(veh)
        else
            TIV.Wire.Controllers[entIdx] = nil
        end
    end

    for entIdx, veh in pairs(TIV.Wire.DirectVehicles) do
        if not visited[entIdx] and IsValid(veh) then
            TIV.Wire.UpdateOutputs(veh)
        elseif not IsValid(veh) then
            TIV.Wire.DirectVehicles[entIdx] = nil
        end
    end
end)

-- Expression 2 propcore/sentSpawn registration if available
if istable(rawget(_G, "WireLib")) and istable(WireLib.SentSpawn) and isfunction(WireLib.SentSpawn.Register) then
    WireLib.SentSpawn.Register("gmod_wire_tiv_controller", {
        ["Model"] = { TYPE_STRING, "models/jaanus/wiretool/wiretool_siren.mdl", "Path to model" }
    })
end

print("[TIV] Wiremod server module loaded")
