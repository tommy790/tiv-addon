-- ============================================================================
-- TIV CUSTOM VEHICLE COMPONENTS - Server
-- Physical armor panel mounting, component lifecycle management,
-- collision protection, and vehicle-relative local positioning.
-- ============================================================================

TIV = TIV or {}
TIV.CustomComponents = TIV.CustomComponents or {}

util.AddNetworkString("TIV_ApplyVehicleConfig")
util.AddNetworkString("TIV_RequestVehicleConfig")
util.AddNetworkString("TIV_SyncVehicleConfig")
util.AddNetworkString("TIV_TagAimedInterceptor")

-- Active components mapped per vehicle entity index
TIV.CustomComponents.VehicleArmor = TIV.CustomComponents.VehicleArmor or {}

-- ============================================================================
-- CLEANUP ARMOR PROPS FOR VEHICLE
-- ============================================================================
function TIV.CustomComponents.RemoveArmorProps(veh)
    if not IsValid(veh) then return end
    local entIdx = veh:EntIndex()
    local props  = TIV.CustomComponents.VehicleArmor[entIdx] or {}

    for _, p in ipairs(props) do
        if IsValid(p) then
            SafeRemoveEntity(p)
        end
    end

    TIV.CustomComponents.VehicleArmor[entIdx] = {}
    veh._TIVArmorProps = {}
end

-- ============================================================================
-- SPAWN & ATTACH ARMOR PANELS
-- Mounts armor panels solidly in the vehicle's local coordinate frame.
-- ============================================================================
function TIV.CustomComponents.SpawnArmorProps(veh, config, unlockedUpgrades)
    if not IsValid(veh) or not config or not config.components then return end
    unlockedUpgrades = unlockedUpgrades or {}

    TIV.CustomComponents.RemoveArmorProps(veh)
    local entIdx = veh:EntIndex()
    local spawnedProps = {}

    local hasSideUpgrade   = unlockedUpgrades["side_armor"] == true
    local hasFrontUpgrade  = unlockedUpgrades["front_armor"] == true
    local hasRoofUpgrade   = unlockedUpgrades["roof_spoiler"] == true
    local hasScreenUpgrade = unlockedUpgrades["path_screen"] == true
    local hasHydraulicUpgrade = unlockedUpgrades["reinforced_hydraulics"] == true

    for i, comp in ipairs(config.components) do
        local ctype = comp.type or ""
        local isArmor = (ctype == "armor_side" or ctype == "armor_front" or ctype == "armor_roof"
            or ctype == "hydraulic_ram")
        local isScreen = (ctype == "radar_screen" or ctype == "screen")

        if isArmor or isScreen then
            local allowed = true
            if ctype == "armor_side" and not hasSideUpgrade then allowed = false end
            if ctype == "armor_front" and not hasFrontUpgrade then allowed = false end
            if ctype == "armor_roof" and not hasRoofUpgrade then allowed = false end
            if ctype == "hydraulic_ram" and not hasHydraulicUpgrade then allowed = false end
            if isScreen and not hasScreenUpgrade then allowed = false end

            if allowed then
                local model = comp.model
                if isScreen then
                    model = model or "models/kobilica/wiremonitorsmall.mdl"
                    if not util.IsValidModel(model) then
                        model = "models/props_lab/monitor01b.mdl"
                    end
                elseif ctype == "hydraulic_ram" then
                    model = model or "models/props_c17/TrapPropeller_Lever.mdl"
                    if not util.IsValidModel(model) then
                        model = "models/props_c17/TrapPropeller_Lever.mdl"
                    end
                else
                    model = model or "models/props_phx/construct/metal_plate1x2.mdl"
                    if not util.IsValidModel(model) then
                        model = "models/props_phx/construct/metal_plate1x2.mdl"
                    end
                end

                local localPos = comp.pos or Vector(0, 0, 0)
                local localAng = comp.ang or Angle(0, 0, 0)
                local worldPos = veh:LocalToWorld(localPos)
                local worldAng = veh:LocalToWorldAngles(localAng)

                local prop = ents.Create("prop_physics")
                if IsValid(prop) then
                    prop:SetModel(model)
                    prop:SetPos(worldPos)
                    prop:SetAngles(worldAng)
                    prop:Spawn()
                    prop:Activate()

                    prop:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
                    prop:SetCustomCollisionCheck(true)
                    if not isScreen then
                        prop:SetColor(Color(180, 185, 195, 255))
                    end
                    prop:SetRenderMode(RENDERMODE_NORMAL)

                    local phys = prop:GetPhysicsObject()
                    if IsValid(phys) then
                        phys:SetMass(1)
                        phys:EnableMotion(false)
                        phys:EnableGravity(false)
                    end

                    if constraint and constraint.NoCollide then
                        constraint.NoCollide(veh, prop, 0, 0)
                        if data and data.spikes then
                            for _, sd in ipairs(data.spikes) do
                                if IsValid(sd.entity) then
                                    constraint.NoCollide(sd.entity, prop, 0, 0)
                                end
                            end
                        end
                    end

                    prop:SetParent(veh)
                    prop:SetLocalPos(localPos)
                    prop:SetLocalAngles(localAng)

                    if ctype == "hydraulic_ram" then
                        -- The ram telescopes along its shaft as the anchors drive, so
                        -- reinforced_hydraulics is visible in motion and not just parked
                        -- on the hull. The base pose is recorded here so the deploy
                        -- animation never has to recompute the mount, and a retract
                        -- always returns to exactly this transform.
                        prop._TIVRamBasePos = Vector(localPos.x, localPos.y, localPos.z)
                        prop._TIVRamDir     = Vector(0, 0, -1)
                        prop._TIVRamTravel  = 10
                    end

                    if isScreen then
                        prop:SetNWBool("TIV_RadarScreen", true)
                        prop.IsTIVRadarScreen = true
                        veh._TIVRadarScreen = prop
                    else
                        prop:SetNWBool("TIV_Armor", true)
                        prop.IsTIVArmor = true
                    end

                    if IsValid(veh) then prop:SetNWEntity("TIV_OwnerVehicle", veh) end
                    prop:SetNWBool("GStormsIgnore", true)
                    prop:SetNWBool("XT3Ignore", true)
                    prop:SetNWBool("XT2Ignore", true)
                    prop:SetNWBool("XTwister2Ignore", true)

                    prop.GStormsIgnore        = true
                    prop.XT3Ignore            = true
                    prop.XT3DoNotApplyPhysics = true
                    prop.XT2Ignore            = true
                    prop.XT2DoNotApplyPhysics = true
                    prop.XTwister2Ignore      = true
                    prop.PhysgunDisabled      = true
                    prop.DoNotDuplicate       = true
                    prop.TIV_OwnerVehicle     = veh

                    table.insert(spawnedProps, prop)
                end
            end
        end
    end

    TIV.CustomComponents.VehicleArmor[entIdx] = spawnedProps
    veh._TIVArmorProps = spawnedProps
end

-- ============================================================================
-- ENSURE ARMOR PANELS ARE MOUNTED FOR VEHICLE & OWNER
-- ============================================================================
function TIV.CustomComponents.EnsureArmor(veh, ply)
    if not IsValid(veh) or not TIV.IsSupportedVehicle(veh) then return end

    if not IsValid(ply) then
        ply = (veh.GetDriver and veh:GetDriver()) or veh._TIVOwner
        if not IsValid(ply) and veh.CPPIGetOwner then
            ply = veh:CPPIGetOwner()
        end
        if not IsValid(ply) and game.SinglePlayer() then
            ply = player.GetHumans()[1] or Entity(1)
        end
    end

    if not IsValid(ply) then return end
    veh._TIVOwner = ply

    local profile = TIV.Progression.GetPlayerProfile(ply)
    local unlocked = profile and profile.unlocked_upgrades or {}

    local hasSideUpgrade      = (unlocked["side_armor"] == true)
    local hasFrontUpgrade     = (unlocked["front_armor"] == true)
    local hasRoofUpgrade      = (unlocked["roof_spoiler"] == true)
    local hasScreenUpgrade    = (unlocked["path_screen"] == true)
    local hasHydraulicUpgrade = (unlocked["reinforced_hydraulics"] == true)

    -- This used to test only the three armor upgrades, so a player who unlocked
    -- the Path Screen -- or the hydraulic rams -- and nothing else fell into the
    -- "no components wanted" branch, which removed any existing props and
    -- returned without spawning anything. The screen upgrade did nothing at all
    -- through the normal spawn/enter lifecycle; it only appeared if you happened
    -- to re-apply the config by hand.
    local hasAnyArmor = hasSideUpgrade or hasFrontUpgrade or hasRoofUpgrade
        or hasScreenUpgrade or hasHydraulicUpgrade

    local existingProps = TIV.CustomComponents.VehicleArmor[veh:EntIndex()] or veh._TIVArmorProps or {}
    local validProps = 0
    for _, p in ipairs(existingProps) do
        if IsValid(p) then validProps = validProps + 1 end
    end

    if not hasAnyArmor then
        if validProps > 0 then
            TIV.CustomComponents.RemoveArmorProps(veh)
            TIV.CustomComponents.ApplyVehicleBonuses(veh)
        end
        return
    end

    if not veh._TIVConfig and TIV.CustomConfig and TIV.CustomConfig.GetSavedConfig then
        veh._TIVConfig = TIV.CustomConfig.GetSavedConfig(veh:GetModel())
    end
    local config = veh._TIVConfig or TIV.CustomConfig.GetDefaultConfig(veh:GetModel(), unlocked["angled_spikes"] == true)
    -- Must count exactly the set SpawnArmorProps will actually build, or this
    -- reconciler disagrees with it and respawns every component on every call.
    local desiredCount = 0
    for _, comp in ipairs(config.components or {}) do
        local ctype = comp.type or ""
        if (ctype == "armor_side" and hasSideUpgrade)
           or (ctype == "armor_front" and hasFrontUpgrade)
           or (ctype == "armor_roof" and hasRoofUpgrade)
           or (ctype == "hydraulic_ram" and hasHydraulicUpgrade)
           or ((ctype == "radar_screen" or ctype == "screen") and hasScreenUpgrade) then
            desiredCount = desiredCount + 1
        end
    end

    if validProps ~= desiredCount or veh._TIVArmorNeedsRebuild then
        veh._TIVArmorNeedsRebuild = nil
        TIV.CustomComponents.SpawnArmorProps(veh, config, unlocked)
        TIV.CustomComponents.ApplyVehicleBonuses(veh)
    end
end

-- ============================================================================
-- APPLY VEHICLE BONUSES & RECALCULATE STATS
-- ============================================================================
function TIV.CustomComponents.ApplyVehicleBonuses(veh)
    if not IsValid(veh) then return end

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

    local unlocked = {}
    if IsValid(driver) and TIV.Progression and TIV.Progression.GetPlayerProfile then
        local prof = TIV.Progression.GetPlayerProfile(driver)
        if prof then unlocked = prof.unlocked_upgrades or {} end
    end

    if not veh._TIVConfig and TIV.CustomConfig and TIV.CustomConfig.GetSavedConfig then
        veh._TIVConfig = TIV.CustomConfig.GetSavedConfig(veh:GetModel())
    end
    local config = veh._TIVConfig or TIV.CustomConfig.GetDefaultConfig(veh:GetModel(), unlocked["angled_spikes"] == true)
    local stats  = TIV.CustomConfig.CalculateVehicleStats(config, unlocked)

    veh._TIVEffectiveStats = stats

    -- Keep vehicle physics mass at stock factory weight so suspension never sags.
    -- All armor weight and upgrade ballast are used for wind resistance, loft calculations,
    -- and telemetry modeling via stats.total_ballast_mass without burdening VPhysics suspension.
    local phys = veh:GetPhysicsObject()
    if IsValid(phys) then
        if not veh._TIVBaseMass then
            veh._TIVBaseMass = phys:GetMass()
        end
        phys:SetMass(veh._TIVBaseMass)
    end

    -- Restore stock suspension springs if previously modified
    if isfunction(veh.GetVehicleParams) and isfunction(veh.SetVehicleParams) then
        local params = veh:GetVehicleParams()
        if params and params.wheels then
            local modified = false
            for i = 0, #params.wheels do
                local w = params.wheels[i]
                if w and w.suspension and w.suspension._TIVBaseSpring then
                    w.suspension.springConstant = w.suspension._TIVBaseSpring
                    w.suspension._TIVBaseSpring = nil
                    modified = true
                end
            end
            if modified then
                veh:SetVehicleParams(params)
            end
        end
    end

    -- Trigger Wire output update
    if TIV.Wire and TIV.Wire.UpdateOutputs then
        TIV.Wire.UpdateOutputs(veh)
    end
end

-- ============================================================================
-- APPLY CONFIGURATION NETWORK RECEIVER
-- ============================================================================
net.Receive("TIV_ApplyVehicleConfig", function(len, ply)
    if not IsValid(ply) then return end

    local rawLua = net.ReadString()
    local config, err = TIV.CustomConfig.DeserializeFromLua(rawLua)
    if not config then
        ply:ChatPrint("[TIV] Configuration import error: " .. (err or "Unknown error"))
        return
    end

    local model = string.lower(config.vehicle_model or "models/buggy.mdl")

    -- Cache config on server
    TIV.CustomConfig.VehicleConfigs = TIV.CustomConfig.VehicleConfigs or {}
    TIV.CustomConfig.VehicleConfigs[model] = config

    -- Persist config file on server
    if not file.IsDir("tiv", "DATA") then file.CreateDir("tiv") end
    if not file.IsDir("tiv/configs", "DATA") then file.CreateDir("tiv/configs") end
    local sPath = TIV.CustomConfig.GetConfigFileName(model)
    file.Write(sPath, util.TableToJSON(config, true))

    -- Target vehicle resolution
    local targetVeh = TIV.Deploy and TIV.Deploy.ResolveVehicle and TIV.Deploy.ResolveVehicle(ply)
    if IsValid(targetVeh) and string.lower(targetVeh:GetModel() or "") ~= model then
        targetVeh = nil
    end

    if not IsValid(targetVeh) then
        local tr = ply:GetEyeTrace()
        if tr.Hit and IsValid(tr.Entity) and (TIV.IsSupportedVehicle(tr.Entity) or string.lower(tr.Entity:GetModel() or "") == model) then
            targetVeh = tr.Entity
        end
    end

    if not IsValid(targetVeh) then
        local plyPos = ply:GetPos()
        local bestDist = 600 * 600
        for _, ent in ipairs(ents.GetAll()) do
            if IsValid(ent) and TIV.IsSupportedVehicle(ent) and string.lower(ent:GetModel() or "") == model then
                local dist = ent:GetPos():DistToSqr(plyPos)
                if dist < bestDist then
                    targetVeh = ent
                    bestDist = dist
                end
            end
        end
    end

    if not IsValid(targetVeh) then
        local plyPos = ply:GetPos()
        local bestDist = 250 * 250
        for entIdx, data in pairs(TIV.Deploy.Vehicles or {}) do
            local candidate = Entity(entIdx)
            if IsValid(candidate) and candidate:GetPos():DistToSqr(plyPos) < bestDist then
                targetVeh = candidate
                bestDist = candidate:GetPos():DistToSqr(plyPos)
            end
        end
    end

    if IsValid(targetVeh) then
        TIV.TagAsInterceptor(targetVeh, true)

        local profile = TIV.Progression.GetPlayerProfile(ply)
        local unlocked = profile and profile.unlocked_upgrades or {}

        -- If player does not have angled_spikes unlocked, enforce 90-degree straight spikes
        if not unlocked["angled_spikes"] and config and istable(config.components) then
            for _, comp in ipairs(config.components) do
                if comp.type == "spike" then
                    comp.ang = Angle(90, 0, 0)
                end
            end
        end

        targetVeh._TIVConfig = config

        -- Spawn physical armor panels
        TIV.CustomComponents.SpawnArmorProps(targetVeh, config, unlocked)

        -- Rebuild vehicle spikes with custom positions and angles
        local deployData = TIV.Deploy and TIV.Deploy.GetState and TIV.Deploy.GetState(targetVeh)
        if deployData and deployData.state == "idle" then
            if TIV.Spikes and TIV.Spikes.RemoveAll then
                TIV.Anchor.DetachAll(targetVeh, deployData)
                TIV.Spikes.RemoveAll(deployData, targetVeh:EntIndex())
                deployData.spikesCreated = false
                TIV.Deploy.EnsureSpikes(targetVeh, deployData)
            end
        end

        -- Reapply physics bonuses
        TIV.CustomComponents.ApplyVehicleBonuses(targetVeh)

        ply:ChatPrint(string.format("[TIV] Configuration for '%s' applied to interceptor [%d]!", string.GetFileFromFilename(model), targetVeh:EntIndex()))
    else
        ply:ChatPrint(string.format("[TIV] Configuration for '%s' saved! It will apply automatically when spawning or entering this interceptor.", string.GetFileFromFilename(model)))
    end
end)

-- Tag Aimed Interceptor Network Receiver
net.Receive("TIV_TagAimedInterceptor", function(len, ply)
    if not IsValid(ply) then return end
    local tr = ply:GetEyeTrace()
    local ent = tr.Entity
    if not IsValid(ent) or ent:IsWorld() then
        ply:ChatPrint("[TIV] No entity in your crosshairs to tag as an interceptor.")
        return
    end

    local isInterceptor = not (ent.IsTIVVehicle or ent:GetNWBool("TIV_Interceptor", false))
    TIV.TagAsInterceptor(ent, isInterceptor)

    if isInterceptor then
        local model = string.lower(ent:GetModel() or "")
        local cfg = TIV.CustomConfig.GetSavedConfig(model) or TIV.CustomConfig.GetDefaultConfig(model)
        ent._TIVConfig = cfg
        local profile = TIV.Progression.GetPlayerProfile(ply)
        local unlocked = profile and profile.unlocked_upgrades or {}
        TIV.CustomComponents.SpawnArmorProps(ent, cfg, unlocked)
        TIV.CustomComponents.ApplyVehicleBonuses(ent)
        ply:ChatPrint(string.format("[TIV] Entity [%d] (%s) is now identified as an Interceptor!", ent:EntIndex(), string.GetFileFromFilename(model)))
    else
        TIV.CustomComponents.RemoveArmorProps(ent)
        local deployData = TIV.Deploy and TIV.Deploy.GetState and TIV.Deploy.GetState(ent)
        if deployData then
            TIV.Anchor.DetachAll(ent, deployData)
            TIV.Spikes.RemoveAll(deployData, ent:EntIndex())
            deployData.spikesCreated = false
        end
        ply:ChatPrint(string.format("[TIV] Entity [%d] is no longer an Interceptor.", ent:EntIndex()))
    end
end)

-- Console Commands for Manual Identification
concommand.Add("tiv_identify_interceptor", function(ply, cmd, args)
    if not IsValid(ply) then return end
    local ent = (TIV.ResolveVehicle and TIV.ResolveVehicle(ply)) or ply:GetEyeTrace().Entity
    if not IsValid(ent) or ent:IsWorld() then
        ply:ChatPrint("[TIV] No vehicle or entity targeted. Look at an entity or sit inside one.")
        return
    end

    TIV.TagAsInterceptor(ent, true)
    local model = string.lower(ent:GetModel() or "")
    local cfg = TIV.CustomConfig.GetSavedConfig(model) or TIV.CustomConfig.GetDefaultConfig(model)
    ent._TIVConfig = cfg

    local profile = TIV.Progression.GetPlayerProfile(ply)
    local unlocked = profile and profile.unlocked_upgrades or {}
    TIV.CustomComponents.SpawnArmorProps(ent, cfg, unlocked)
    TIV.CustomComponents.ApplyVehicleBonuses(ent)

    ply:ChatPrint(string.format("[TIV] Entity [%d] (%s) is now identified as an Interceptor!", ent:EntIndex(), string.GetFileFromFilename(model)))
end)

concommand.Add("tiv_unidentify_interceptor", function(ply, cmd, args)
    if not IsValid(ply) then return end
    local ent = (TIV.ResolveVehicle and TIV.ResolveVehicle(ply)) or ply:GetEyeTrace().Entity
    if not IsValid(ent) or ent:IsWorld() then
        ply:ChatPrint("[TIV] No vehicle or entity targeted.")
        return
    end

    TIV.TagAsInterceptor(ent, false)
    TIV.CustomComponents.RemoveArmorProps(ent)
    local deployData = TIV.Deploy and TIV.Deploy.GetState and TIV.Deploy.GetState(ent)
    if deployData then
        TIV.Anchor.DetachAll(ent, deployData)
        TIV.Spikes.RemoveAll(deployData, ent:EntIndex())
        deployData.spikesCreated = false
    end

    ply:ChatPrint(string.format("[TIV] Entity [%d] is no longer identified as an Interceptor.", ent:EntIndex()))
end)

-- ============================================================================
-- IMPACT & DEBRIS DAMAGE REDUCTION
-- Armor panels absorb kinetic debris impacts from flying tornado wreckage.
-- ============================================================================
hook.Add("EntityTakeDamage", "TIV_ArmorDamageReduction", function(target, dmginfo)
    if not IsValid(target) or not TIV.IsSupportedVehicle(target) then return end

    local stats = target._TIVEffectiveStats
    if stats and stats.impact_reduction and stats.impact_reduction > 0 then
        local reduction = stats.impact_reduction
        dmginfo:ScaleDamage(1.0 - reduction)
    end
end)

-- ============================================================================
-- VEHICLE LIFECYCLE HOOKS
-- ============================================================================
hook.Add("PlayerSpawnedVehicle", "TIV_CustomComponents_Spawn", function(ply, veh)
    if IsValid(veh) and TIV.IsSupportedVehicle(veh) then
        veh._TIVOwner = ply
        timer.Simple(0.1, function()
            if IsValid(veh) and IsValid(ply) then
                local model = string.lower(veh:GetModel() or "")
                if not veh._TIVConfig and TIV.CustomConfig and TIV.CustomConfig.GetSavedConfig then
                    veh._TIVConfig = TIV.CustomConfig.GetSavedConfig(model)
                end
                if TIV.CustomComponents and TIV.CustomComponents.EnsureArmor then
                    TIV.CustomComponents.EnsureArmor(veh, ply)
                end
            end
        end)
    end
end)

hook.Add("PlayerEnteredVehicle", "TIV_CustomComponents_Enter", function(ply, veh)
    local tivVeh = (TIV.Deploy and TIV.Deploy.ResolveVehicle and TIV.Deploy.ResolveVehicle(ply)) or veh
    if IsValid(tivVeh) and TIV.IsSupportedVehicle(tivVeh) then
        tivVeh._TIVOwner = ply
        local model = string.lower(tivVeh:GetModel() or "")
        if not tivVeh._TIVConfig and TIV.CustomConfig and TIV.CustomConfig.GetSavedConfig then
            tivVeh._TIVConfig = TIV.CustomConfig.GetSavedConfig(model)
        end
        if TIV.CustomComponents and TIV.CustomComponents.EnsureArmor then
            TIV.CustomComponents.EnsureArmor(tivVeh, ply)
        end
    end
end)

hook.Add("EntityRemoved", "TIV_CustomComponents_EntityRemoved", function(ent)
    if IsValid(ent) and TIV.IsSupportedVehicle(ent) then
        TIV.CustomComponents.RemoveArmorProps(ent)
    end
end)

hook.Add("TIV_VehicleRemoved", "TIV_CustomComponentsCleanup", function(veh)
    if IsValid(veh) then
        TIV.CustomComponents.RemoveArmorProps(veh)
    end
end)

print("[TIV] Server custom components module loaded")
