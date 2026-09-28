-- ============================================================================
-- TIV SPIKE ANIMATION CLIENT
-- ============================================================================

TIV.SpikeAnim = TIV.SpikeAnim or {}
TIV.SpikeAnim.ActiveAnims = TIV.SpikeAnim.ActiveAnims or {}

net.Receive("TIV_SpikeAnimStart", function()
    local veh   = net.ReadEntity()
    local count = net.ReadUInt(8)
    if not IsValid(veh) then return end

    TIV.SpikeAnim.ActiveAnims[veh:EntIndex()] = {
        vehicle       = veh,
        count         = count,
        phases        = {},
        phaseTimes    = {},
        startTime     = CurTime(),
        completedTime = nil,
    }
end)

net.Receive("TIV_SpikeAnimPhase", function()
    local veh   = net.ReadEntity()
    local index = net.ReadUInt(8)
    local phase = net.ReadString()
    if not IsValid(veh) then return end

    local entIdx   = veh:EntIndex()
    local animData = TIV.SpikeAnim.ActiveAnims[entIdx]
    if not animData then
        animData = {
            vehicle       = veh,
            count         = TIV.Config and TIV.Config.SpikeCount or 6,
            phases        = {},
            phaseTimes    = {},
            startTime     = CurTime(),
            completedTime = nil,
        }
        TIV.SpikeAnim.ActiveAnims[entIdx] = animData
    end

    animData.phases[index]     = phase
    animData.phaseTimes[index] = CurTime()
    animData.completedTime     = nil
end)

net.Receive("TIV_SpikeAnimImpact", function()
    local veh    = net.ReadEntity()
    local index  = net.ReadUInt(8)
    local pos    = net.ReadVector()
    local normal = net.ReadVector()
    if not IsValid(veh) then return end

    local ed = EffectData()
    ed:SetOrigin(pos)
    ed:SetNormal(normal)
    ed:SetScale(1.2)
    util.Effect("WheelDust", ed)

    local lp = LocalPlayer()
    if IsValid(lp) and lp:GetPos():DistToSqr(pos) < 350 * 350 then
        util.ScreenShake(pos, 2, 8, 0.25, 250)
    end
end)

net.Receive("TIV_SpikeAnimRetract", function()
    local veh = net.ReadEntity()
    if not IsValid(veh) then return end
    -- Mark active anim as retracting and let it fade out via completedTime.
    local animData = TIV.SpikeAnim.ActiveAnims[veh:EntIndex()]
    if animData then
        animData.retracting   = true
        animData.completedTime = CurTime()
    end
end)

-- Clean up active anims for removed vehicles to prevent slow leaks.
hook.Add("EntityRemoved", "TIV_SpikeAnimCleanup", function(ent)
    if not IsValid(ent) then return end
    local idx = ent:EntIndex()
    if TIV.SpikeAnim.ActiveAnims[idx] then
        TIV.SpikeAnim.ActiveAnims[idx] = nil
    end
end)

print("[TIV] Spike animation client loaded")
