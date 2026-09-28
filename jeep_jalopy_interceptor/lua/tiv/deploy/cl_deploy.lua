-- ============================================================================
-- TIV DEPLOY CLIENT
-- Per-vehicle state tracking for multiplayer.
-- ============================================================================

TIV.Deploy = TIV.Deploy or {}

-- Per-vehicle state keyed by EntIndex. In multiplayer, multiple TIVs can be
-- active simultaneously; the HUD looks up the local player's TIV's state.
TIV.Deploy.States       = TIV.Deploy.States       or {} -- [entIdx] = state string
TIV.Deploy.StateFlashes = TIV.Deploy.StateFlashes or {} -- [entIdx] = CurTime() when changed

-- Convenience helpers for the HUD (returns the local player's TIV state).
function TIV.Deploy.GetStateFor(veh)
    if not IsValid(veh) then return "idle" end
    return TIV.Deploy.States[veh:EntIndex()] or "idle"
end

function TIV.Deploy.GetFlashFor(veh)
    if not IsValid(veh) then return 0 end
    return TIV.Deploy.StateFlashes[veh:EntIndex()] or 0
end

-- Legacy single-value globals kept so existing HUD code keeps working.
-- They reflect "whatever the most recent state update was" -- best-effort.
TIV.Deploy.CurrentState   = "idle"
TIV.Deploy.CurrentVehicle = nil
TIV.Deploy.LastStateFlash = 0

function TIV.Deploy.ResolveVehicle(ply)
    if TIV.ResolveVehicle then return TIV.ResolveVehicle(ply) end
    if not IsValid(ply) then return nil end
    local seat = ply:GetVehicle()
    if not IsValid(seat) then return nil end
    local function isTIV(ent)
        if TIV.IsSupportedVehicle then return TIV.IsSupportedVehicle(ent) end
        if not IsValid(ent) then return false end
        local model = string.lower(ent:GetModel() or "")
        local class = string.lower(ent:GetClass() or "")
        return string.find(model, "jeep", 1, true)
            or string.find(model, "jalopy", 1, true)
            or string.find(model, "apc", 1, true)
            or class == "prop_vehicle_jeep"
            or class == "prop_vehicle_jalopy"
            or class == "prop_vehicle_apc"
    end
    if isTIV(seat) then return seat end
    local parent = seat:GetParent()
    if IsValid(parent) and isTIV(parent) then return parent end
    return nil
end

-- Is this state update relevant to the local player (i.e. their TIV)?
local function IsLocalPlayerInVehicle(veh)
    if not IsValid(veh) then return false end
    local lp = LocalPlayer()
    if not IsValid(lp) then return false end
    local lpVeh = TIV.Deploy.ResolveVehicle(lp)
    return IsValid(lpVeh) and lpVeh == veh
end

net.Receive("TIV_DeployStatus", function()
    local veh   = net.ReadEntity()
    local state = net.ReadString()
    if not IsValid(veh) then return end

    local entIdx = veh:EntIndex()
    local prev   = TIV.Deploy.States[entIdx]
    TIV.Deploy.States[entIdx] = state
    if state ~= prev then
        TIV.Deploy.StateFlashes[entIdx] = CurTime()
    end

    -- Mirror to legacy single-value globals only for the local player's TIV.
    -- This is what stops Alice's deploy from updating Bob's HUD state.
    local isLocal = IsLocalPlayerInVehicle(veh)
    if isLocal then
        local prevLocal = TIV.Deploy.CurrentState
        TIV.Deploy.CurrentVehicle = veh
        TIV.Deploy.CurrentState   = state
        if state ~= prevLocal then
            TIV.Deploy.LastStateFlash = CurTime()
        end
        if state == "idle" then
            TIV.Deploy.CurrentVehicle = nil
        end
    end

    -- Sounds: gate on locality AND distance. State-transition sounds were
    -- previously played for every receiver of the broadcast -- so a remote
    -- TIV deploying triggered drop/spike sounds on everyone's client.
    if not isLocal then
        -- Allow distant chase players to hear nearby deploys positionally
        -- (light coupling), but skip the 2D cockpit sound entirely.
        local lp = LocalPlayer()
        if IsValid(lp) and lp:GetPos():DistToSqr(veh:GetPos()) < 1500 * 1500 then
            -- Positional via EmitSound on the entity
            if state == "lowering" or state == "raising" then
                veh:EmitSound("tiv2sounds/tiv2drop-wav.wav", 70, 100, 0.6)
            elseif state == "deploying_spikes" or state == "retracting" then
                local spikeCount = TIV.Instruments and TIV.Instruments.Data
                    and TIV.Instruments.Data.totalSpikes or 0
                if spikeCount > 0 then
                    veh:EmitSound("tiv2sounds/tiv2frontspikes.wav", 70, 100, 0.6)
                end
            end
        end
        return
    end

    -- Local player: full-volume 2D cockpit sounds.
    if state == "lowering" then
        surface.PlaySound("tiv2sounds/tiv2drop-wav.wav")
    elseif state == "deploying_spikes" then
        local spikeCount = TIV.Instruments and TIV.Instruments.Data
            and TIV.Instruments.Data.totalSpikes or 0
        if spikeCount > 0 then
            surface.PlaySound("tiv2sounds/tiv2frontspikes.wav")
        end
    elseif state == "retracting" then
        local spikeCount = TIV.Instruments and TIV.Instruments.Data
            and TIV.Instruments.Data.totalSpikes or 0
        if spikeCount > 0 then
            surface.PlaySound("tiv2sounds/tiv2frontspikes.wav")
        end
    elseif state == "raising" then
        surface.PlaySound("tiv2sounds/tiv2drop-wav.wav")
    end
end)

-- Cleanup on entity removal.
hook.Add("EntityRemoved", "TIV_DeployStateCleanup", function(ent)
    if not IsValid(ent) then return end
    local idx = ent:EntIndex()
    TIV.Deploy.States[idx]       = nil
    TIV.Deploy.StateFlashes[idx] = nil
    if TIV.Deploy.CurrentVehicle == ent then
        TIV.Deploy.CurrentVehicle = nil
        TIV.Deploy.CurrentState   = "idle"
    end
end)

-- ============================================================================
-- KEY BIND
-- ============================================================================
hook.Add("PlayerButtonDown", "TIV_ClientDeployKey", function(ply, button)
    if ply ~= LocalPlayer() then return end
    if not TIV.Config then return end
    if button ~= TIV.Config.DeployKey then return end
    if not IsValid(TIV.Deploy.ResolveVehicle(ply)) then return end

    net.Start("TIV_DeployRequest")
    net.SendToServer()
end)

print("[TIV] Deploy client loaded")