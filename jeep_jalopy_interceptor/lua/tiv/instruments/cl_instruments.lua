-- ============================================================================
-- TIV INSTRUMENTS CLIENT
-- TIV_WindUpdate handler removed (server no longer broadcasts it; was
-- redundant with TIV_InstrumentData and caused field-write races).
-- AnchorFail state is keyed per-vehicle now (was global, bled across cars).
-- TIV_LoftEvent now actually does something.
-- ============================================================================

TIV.Instruments = TIV.Instruments or {}

TIV.Instruments.Data = {
    windSpeed         = 0,
    windDir           = Vector(1, 0, 0),
    vehicleSpeed      = 0,
    altitude          = 0,
    deployState       = "idle",
    activeConstraints = 0,
    totalSpikes       = 0,
    stress            = 0,
    spikeState        = "none",
    verticalVelocity  = 0,
}

-- Per-vehicle anchor-fail state: [entIndex] = { until = CurTime() + N, spike = idx }
TIV.Instruments.AnchorFails = TIV.Instruments.AnchorFails or {}

-- Loft events: [entIndex] = { until = CurTime() + N }
TIV.Instruments.LoftFlashes = TIV.Instruments.LoftFlashes or {}

net.Receive("TIV_InstrumentData", function()
    local d = TIV.Instruments.Data
    d.windSpeed         = net.ReadFloat()
    d.windDir           = net.ReadVector()
    d.vehicleSpeed      = net.ReadFloat()
    d.altitude          = net.ReadFloat()
    d.deployState       = net.ReadString()
    d.activeConstraints = net.ReadUInt(8)
    d.totalSpikes       = net.ReadUInt(8)
    d.stress            = net.ReadFloat()
    d.spikeState        = net.ReadString()
    d.verticalVelocity  = net.ReadFloat()
end)

net.Receive("TIV_LoftEvent", function()
    local veh = net.ReadEntity()
    if not IsValid(veh) then return end

    TIV.Instruments.LoftFlashes[veh:EntIndex()] = { ["until"] = CurTime() + 3 }

    -- Only mutate the local Data.deployState if THIS player is in the
    -- lofted vehicle. Otherwise Alice lofting kicks Bob's HUD into "lofted"
    -- even though Bob is parked safely in his own TIV.
    local lp = LocalPlayer()
    if IsValid(lp) then
        local lpVeh = TIV.ResolveVehicle and TIV.ResolveVehicle(lp) or lp:GetVehicle()
        if IsValid(lpVeh) and lpVeh == veh then
            TIV.Instruments.Data.deployState = "lofted"
        end
    end

    -- Distance-gated shake (anyone nearby gets it).
    local pos = veh:GetPos()
    if IsValid(lp) and lp:GetPos():DistToSqr(pos) < 2000 * 2000 then
        util.ScreenShake(pos, 12, 12, 1.5, 2000)
    end
end)

net.Receive("TIV_AnchorWarning", function()
    local veh        = net.ReadEntity()
    local spikeIndex = net.ReadUInt(8)
    if not IsValid(veh) then return end

    -- Distance-gated so a chase 2km away doesn't hear it.
    local pos = veh:GetPos()
    local lp  = LocalPlayer()
    if IsValid(lp) and lp:GetPos():DistToSqr(pos) < 1500 * 1500 then
        surface.PlaySound("physics/metal/metal_box_break1.wav")
    end

    TIV.Instruments.AnchorFails[veh:EntIndex()] = {
        ["until"] = CurTime() + 3,
        spike     = spikeIndex,
    }
end)

-- Helpers for the HUD.
function TIV.Instruments.GetAnchorFail(veh)
    if not IsValid(veh) then return nil end
    local entry = TIV.Instruments.AnchorFails[veh:EntIndex()]
    if entry and CurTime() < entry["until"] then return entry end
    return nil
end

function TIV.Instruments.GetLoftFlash(veh)
    if not IsValid(veh) then return nil end
    local entry = TIV.Instruments.LoftFlashes[veh:EntIndex()]
    if entry and CurTime() < entry["until"] then return entry end
    return nil
end

-- Periodic cleanup of expired entries + entity-removal cleanup.
hook.Add("EntityRemoved", "TIV_InstrumentsCleanup", function(ent)
    if not IsValid(ent) then return end
    local idx = ent:EntIndex()
    TIV.Instruments.AnchorFails[idx] = nil
    TIV.Instruments.LoftFlashes[idx] = nil
end)

print("[TIV] Instruments client loaded")
