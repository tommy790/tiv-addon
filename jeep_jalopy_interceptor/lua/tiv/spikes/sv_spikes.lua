-- ============================================================================
-- TIV SPIKE SYSTEM
-- Thin façade over sv_spike_anim. Offsets live in TIV.Config.SpikeOffsets.
-- ============================================================================

TIV.Spikes = TIV.Spikes or {}

-- ============================================================================
-- HOW MANY SPIKES THIS VEHICLE SHOULD HAVE
--
-- One answer, used by both the creator (sv_spike_anim.CreateSpikes) and the
-- reconciler (sv_deploy.EnsureSpikes). They used to work it out separately --
-- one from the config's spike mounts, one from a convar -- which agreed only
-- while every default config happened to define exactly six. The Heavy Anchor
-- Array adds two more mounts, so without a single source of truth the two would
-- disagree and EnsureSpikes would tear the anchors down and rebuild them on
-- every call.
--
-- The config's mounts decide the LAYOUT; the ceiling is the stock convar max,
-- raised by heavy_cluster_spikes when the owner has unlocked it. Without that
-- upgrade the two extra mounts simply stay unused.
-- ============================================================================
function TIV.Spikes.ResolveCount(veh)
    local lo      = TIV.Config.SpikeCountConvarMin or 0
    local ceiling = TIV.Config.SpikeCountConvarMax or 6

    -- tiv_spike_count is the baseline the server asks for. It stays meaningful:
    -- an early version of this took the count straight from the config's mounts,
    -- which left the convar read by nothing at all.
    local base = math.Clamp(TIV.Config.SpikeCount or ceiling, lo, ceiling)

    -- The Heavy Anchor Array adds mounts on top of that baseline, and because it
    -- is the only thing that can raise the ceiling, a server cannot configure its
    -- way past the upgrade.
    local extra = 0
    if IsValid(veh) then
        local stats = veh._TIVEffectiveStats
        if stats and stats.max_spikes then
            extra = math.max(0, stats.max_spikes - ceiling)
        end
    end

    local hasAngled = false
    local ply = TIV.ResolveOwner and TIV.ResolveOwner(veh)
    if IsValid(ply) and TIV.Progression and TIV.Progression.GetPlayerProfile then
        local prof = TIV.Progression.GetPlayerProfile(ply)
        hasAngled = not not (prof and prof.unlocked_upgrades and prof.unlocked_upgrades["angled_spikes"])
    end

    local defined = 0
    if TIV.CustomConfig and TIV.CustomConfig.CountSpikeComponents then
        defined = TIV.CustomConfig.CountSpikeComponents(veh, hasAngled) or 0
    end
    if defined <= 0 then defined = base + extra end

    -- The config's mounts are a hard limit: there is nowhere to bolt an anchor
    -- that the layout does not define.
    return math.Clamp(math.min(base + extra, defined), lo, defined)
end

-- ============================================================================
-- CREATE
-- ============================================================================
function TIV.Spikes.Create(veh, data)
    if not IsValid(veh) then return end
    if TIV.SpikeAnim and TIV.SpikeAnim.CreateSpikes then
        TIV.SpikeAnim.CreateSpikes(veh, data)
    end
end

-- ============================================================================
-- DEPLOY
-- ============================================================================
function TIV.Spikes.Deploy(veh, data, callback)
    if not IsValid(veh) then
        if callback then callback() end
        return
    end
    if TIV.SpikeAnim and TIV.SpikeAnim.DeployToGround then
        TIV.SpikeAnim.DeployToGround(veh, data, callback)
        return
    end

    -- Instant fallback (anim module missing). Filters all spikes, not just veh.
    local function spikeFilter(ent)
        if not IsValid(ent) then return true end
        if ent == veh or (IsValid(ent:GetParent()) and ent:GetParent() == veh) or ent.TIV_OwnerVehicle == veh or ent.IsTIVArmor or ent.IsTIVSpike then
            return false
        end
        if data and data.spikes then
            for _, sd in ipairs(data.spikes) do
                if sd.entity == ent then return false end
            end
        end
        return true
    end

    for _, spikeData in ipairs(data.spikes or {}) do
        if IsValid(spikeData.entity) then
            spikeData.entity:SetParent(nil)
            local localAng = spikeData.storedLocalAng or spikeData.ang or (TIV.SpikeAnim and TIV.SpikeAnim.GetParentedLocalAngle and TIV.SpikeAnim.GetParentedLocalAngle()) or Angle(90, 0, 0)
            local localPos = spikeData.storedLocalPos or spikeData.localPos or spikeData.offset or Vector(0, 0, 0)
            local worldPos = veh:LocalToWorld(localPos)
            local worldAng = (TIV.SpikeAnim and TIV.SpikeAnim.GetSpikeDownAngle) and TIV.SpikeAnim.GetSpikeDownAngle(veh, localAng) or veh:LocalToWorldAngles(localAng)
            local worldDir = worldAng:Forward()

            local tr = util.TraceLine({
                start  = worldPos,
                endpos = worldPos + (worldDir * 350),
                filter = spikeFilter,
                mask   = MASK_SOLID,
            })
            local gp = tr.Hit and tr.HitPos or (worldPos + (worldDir * 60))
            local driveDepth = TIV.Config.SpikeDriveDepth or 18
            spikeData.entity:SetPos(gp + (worldDir * driveDepth))
            spikeData.entity:SetAngles(worldAng)
            spikeData.groundPos   = gp
            spikeData.deployAngle = worldAng
            spikeData.phase       = "deployed"
            data.spikeAnims[spikeData.index] = "deployed"
        end
    end

    TIV.Anchor.AttachAll(veh, data)
    if callback then callback() end
end

-- ============================================================================
-- RETRACT
-- ============================================================================
function TIV.Spikes.Retract(veh, data, callback)
    if not IsValid(veh) then
        if callback then callback() end
        return
    end
    if TIV.SpikeAnim and TIV.SpikeAnim.RetractFromGround then
        TIV.SpikeAnim.RetractFromGround(veh, data, callback)
        return
    end

    for _, spikeData in ipairs(data.spikes or {}) do
        if IsValid(spikeData.entity) and TIV.SpikeAnim.ReparentSpike then
            TIV.SpikeAnim.ReparentSpike(veh, spikeData.entity, spikeData)
            data.spikeAnims[spikeData.index] = "idle"
        end
    end
    if callback then callback() end
end

-- ============================================================================
-- INTERRUPT DEPLOY / RETRACT (MID-STROKE REVERSAL)
-- ============================================================================
function TIV.Spikes.InterruptAndRetract(veh, data, callback)
    if not IsValid(veh) then
        if callback then callback() end
        return
    end
    if TIV.SpikeAnim and TIV.SpikeAnim.InterruptAndRetract then
        TIV.SpikeAnim.InterruptAndRetract(veh, data, callback)
        return
    end
    TIV.Spikes.Retract(veh, data, callback)
end

function TIV.Spikes.InterruptAndDeploy(veh, data, callback)
    if not IsValid(veh) then
        if callback then callback() end
        return
    end
    if TIV.SpikeAnim and TIV.SpikeAnim.InterruptAndDeploy then
        TIV.SpikeAnim.InterruptAndDeploy(veh, data, callback)
        return
    end
    TIV.Spikes.Deploy(veh, data, callback)
end

-- ============================================================================
-- REMOVE ALL
-- Kills the actual jobs (was removing nonexistent timer names).
-- ============================================================================
function TIV.Spikes.RemoveAll(data, entIndex)
    if not data then return end

    -- Cancel pending animation jobs for this session.
    if data.sessionID and TIV.SpikeAnim and TIV.SpikeAnim.ActiveJobs then
        local prefix = data.sessionID .. "_"
        for jobKey in pairs(TIV.SpikeAnim.ActiveJobs) do
            if string.sub(jobKey, 1, #prefix) == prefix then
                TIV.SpikeAnim.ActiveJobs[jobKey] = nil
            end
        end
    end

    for _, spikeData in ipairs(data.spikes or {}) do
        if spikeData.grabber and TIV.WireAnchor then
            TIV.WireAnchor.Remove(spikeData.grabber)
            spikeData.grabber = nil
        end
        if IsValid(spikeData.entity) then
            spikeData.entity:SetParent(nil)
            SafeRemoveEntity(spikeData.entity)
        end
    end

    data.spikes     = {}
    data.spikeAnims = {}
end

-- ============================================================================
-- RELEASE ALL (loft -- physics take over)
-- Now actually used; the loft TriggerLoft path can opt into this via
-- tiv_loft_release_spikes convar (see sv_loft.lua).
-- ============================================================================
function TIV.Spikes.ReleaseAll(data)
    if not data or not data.spikes then return end
    for _, spikeData in ipairs(data.spikes) do
        if spikeData.grabber and TIV.WireAnchor then
            TIV.WireAnchor.Remove(spikeData.grabber)
            spikeData.grabber = nil
        end
        if IsValid(spikeData.entity) then
            constraint.RemoveAll(spikeData.entity)
            spikeData.entity:SetParent(nil)
            spikeData.entity:SetMoveType(MOVETYPE_VPHYSICS)
            local phys = spikeData.entity:GetPhysicsObject()
            if IsValid(phys) then
                phys:EnableMotion(true)
                phys:EnableGravity(true)
                phys:Wake()
                phys:ApplyForceCenter(VectorRand() * 3000 + Vector(0, 0, 2000))
                phys:ApplyTorqueCenter(VectorRand() * 500)
            end
            spikeData.entity:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
            spikeData.phase = "released"
            SafeRemoveEntityDelayed(spikeData.entity, 15)
            spikeData.entity = nil
        end
    end
end

-- ============================================================================
-- UTILITIES
-- ============================================================================
function TIV.Spikes.GetCount(data)
    if not data or not data.spikes then return 0 end
    local count = 0
    for _, sd in ipairs(data.spikes) do
        if IsValid(sd.entity) then count = count + 1 end
    end
    return count
end

-- Real bug fix: motion phases now take priority over rest phases so the
-- HUD doesn't report "IN GROUND" mid-deploy when one spike has finished.
function TIV.Spikes.GetState(data)
    if not data or not data.spikeAnims then return "none" end
    local phases = {}
    for _, phase in pairs(data.spikeAnims) do
        phases[phase] = (phases[phase] or 0) + 1
    end

    if phases["deploying"]  and phases["deploying"]  > 0 then return "deploying"  end
    if phases["retracting"] and phases["retracting"] > 0 then return "retracting" end
    -- "slipping" is a spike being dragged towards the limit of its grip and
    -- "slipped" one that has lost the ground. Both still mean the set is down,
    -- so they rank above "deployed" rather than falling through to "none".
    if phases["slipping"]   and phases["slipping"]   > 0 then return "slipping"   end
    if phases["slipped"]    and phases["slipped"]    > 0 then return "slipped"    end
    if phases["deployed"]   and phases["deployed"]   > 0 then return "deployed"   end
    if phases["idle"]       and phases["idle"]       > 0 then return "idle"       end
    return "none"
end

-- Real bug fix: was reading TIV.Config.SpikeCount and TIV.Spikes.Offsets
-- (which are stale/dead). Reads actual data.spikes instead.
function TIV.Spikes.AllInPhase(data, phase)
    if not data or not data.spikes or #data.spikes == 0 then return false end
    for _, sd in ipairs(data.spikes) do
        if sd.phase ~= phase then return false end
    end
    return true
end

function TIV.Spikes.ValidateIntegrity(data)
    if not data or not data.spikes then return 0 end
    local removed = 0
    for i = #data.spikes, 1, -1 do
        if not IsValid(data.spikes[i].entity) then
            local idx = data.spikes[i].index
            table.remove(data.spikes, i)
            if data.spikeAnims and idx then
                data.spikeAnims[idx] = nil
            end
            removed = removed + 1
        end
    end
    return removed
end

-- ============================================================================
-- DEBUG COMMAND
-- ============================================================================
concommand.Add("tiv_spike_debug", function(ply, cmd, args)
    if IsValid(ply) and not ply:IsAdmin() then return end

    local veh
    if args[1] then
        veh = Entity(tonumber(args[1]) or 0)
    end
    if not IsValid(veh) and IsValid(ply) then
        veh = ply:GetVehicle()
    end
    if not IsValid(veh) then
        print("[TIV] Get in a vehicle or pass an entity index!")
        return
    end

    local data = TIV.Deploy.GetState(veh)
    if not data then
        print("[TIV] No data")
        return
    end

    local lines = {
        "[TIV] === SPIKE DEBUG ===",
        "Vehicle state : " .. (data.state or "nil"),
        "Spike overall : " .. TIV.Spikes.GetState(data),
        "Spike count   : " .. TIV.Spikes.GetCount(data),
        "Created flag  : " .. tostring(data.spikesCreated),
        "Session ID    : " .. tostring(data.sessionID),
        "Constraints   : " .. #(data.constraints or {}),
    }

    -- Iterate by spike index in deterministic order.
    for _, sd in ipairs(data.spikes or {}) do
        local i = sd.index
        local phase = (data.spikeAnims or {})[i] or "unknown"
        local valid    = IsValid(sd.entity) and "valid" or "INVALID"
        local parented = (IsValid(sd.entity) and IsValid(sd.entity:GetParent()))
                         and "parented" or "world"
        table.insert(lines, string.format("  Spike #%d (%-12s): %-12s [%s] [%s]",
            i, tostring(sd.name or "?"), phase, valid, parented))
    end

    -- Anchor detail: which spikes are still holding the ground, what each is
    -- carrying, and which hold method the server picked.
    if TIV.Anchor and TIV.Anchor.ReportLines then
        for _, line in ipairs(TIV.Anchor.ReportLines(veh, data)) do
            table.insert(lines, line)
        end
    end

    for _, line in ipairs(lines) do print(line) end
end)

-- ============================================================================
-- ANCHOR DEBUG
-- ============================================================================
-- One-shot readout of the anchoring system for a vehicle: hold method,
-- stressed state, per-spike grip, and the constraint inventory. Deliberately
-- on-demand rather than periodic so normal gameplay stays quiet; the
-- continuous version is `tiv_debug_freeze 1`.
concommand.Add("tiv_anchor_debug", function(ply, cmd, args)
    if IsValid(ply) and not ply:IsAdmin() then return end

    local veh
    if args[1] then veh = Entity(tonumber(args[1]) or 0) end
    if not IsValid(veh) and IsValid(ply) then veh = ply:GetVehicle() end
    if not IsValid(veh) then
        print("[TIV] Get in a vehicle or pass an entity index!")
        return
    end

    local data = TIV.Deploy.GetState(veh)
    if not data then
        print("[TIV] No data")
        return
    end

    local counts = TIV.Anchor.GetCounts(data)
    print("[TIV] === ANCHOR DEBUG ===")
    print(string.format("Vehicle       : #%d (%s)", veh:EntIndex(), veh:GetClass()))
    print(string.format("State         : %s   stressed: %s   gravityReleased: %s",
        tostring(data.state), tostring(data.anchorStressed == true), tostring(data.gravityReleased == true)))
    print(string.format("Hold method   : %s   (Wiremod %s)",
        TIV.WireAnchor and TIV.WireAnchor.Describe() or "ballsocket",
        (TIV.WireAnchor and TIV.WireAnchor.IsAvailable()) and "available" or "not available"))
    print(string.format("Hold force    : %.0f N   torque %.0f N",
        TIV.AnchorHoldForce(data.anchorStressed == true),
        TIV.AnchorHoldTorque(data.anchorStressed == true)))

    -- The load side of the same equation. "Hold force" alone cannot tell you
    -- whether a vehicle is actually in trouble; the ratio can.
    local total, holds = TIV.Anchor.TotalHoldForce(data)
    local load = tonumber(data.stormLoad) or 0
    local ref  = tonumber(data.stormLoadRef) or 0
    print(string.format("Storm load    : %.0f N applied (%.0f N at threshold x %.2f from %.0f N rated over %d hold(s))",
        load,
        ref * math.max(0, tonumber(TIV.AnchorSetting("WindLoadAtThreshold", 0.7)) or 0.7),
        ref > 0 and (load / math.max(1, ref)) or 0,
        total, holds))
    print(string.format("Constraints   : holds=%d (ballsocket %d, grabber %d, world %d) soil=%d airbag=%d nocollide=%d total=%d",
        counts.holds, counts.ballsockets, counts.grabbers, counts.anchors,
        counts.embeds, counts.elastics, counts.nocollide, counts.total))
    if data.plantedPos then
        print(string.format("Chassis       : risen %.1f u, drifted %.1f u from plant",
            math.max(0, veh:GetPos().z - data.plantedPos.z),
            veh:GetPos():Distance(data.plantedPos)))
    end
    for _, line in ipairs(TIV.Anchor.ReportLines(veh, data)) do print(line) end
end)

print("[TIV] Spike system loaded")
