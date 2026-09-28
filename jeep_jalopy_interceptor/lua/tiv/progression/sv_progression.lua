-- ============================================================================
-- TIV PROGRESSION & UPGRADE SYSTEM - Server
-- Persistent player progression, Intercept rewards for surviving tornadoes,
-- upgrade transactions, and real-time physics integration.
-- ============================================================================

TIV = TIV or {}
TIV.Progression = TIV.Progression or {}

util.AddNetworkString("TIV_SyncProgression")
util.AddNetworkString("TIV_InterceptAwarded")
util.AddNetworkString("TIV_PointsAwarded")
util.AddNetworkString("TIV_PurchaseUpgrade")
util.AddNetworkString("TIV_RequestProgression")
util.AddNetworkString("TIV_CheatAction")

TIV.Progression.PlayerData = TIV.Progression.PlayerData or {}
TIV.Progression.ActiveTracking = TIV.Progression.ActiveTracking or {}

-- ============================================================================
-- FILE PERSISTENCE HELPERS
-- ============================================================================
local DATA_DIR = "tiv/progression"

local function EnsureDataDir()
    if not file.IsDir("tiv", "DATA") then
        file.CreateDir("tiv")
    end
    if not file.IsDir(DATA_DIR, "DATA") then
        file.CreateDir(DATA_DIR)
    end
end

local function GetPlayerStorageKey(ply)
    if not IsValid(ply) then return "server_local" end
    if game.SinglePlayer() then return "singleplayer" end
    local sid = ply:SteamID64()
    if sid and sid ~= "" and sid ~= "0" then
        return sid
    end
    return string.gsub(ply:SteamID() or "unknown", ":", "_")
end

function TIV.Progression.GetPlayerProfile(ply)
    if not IsValid(ply) then return nil end
    local key = GetPlayerStorageKey(ply)
    if not TIV.Progression.PlayerData[key] then
        TIV.Progression.LoadPlayerProfile(ply)
    end
    return TIV.Progression.PlayerData[key]
end

function TIV.Progression.LoadPlayerProfile(ply)
    if not IsValid(ply) then return end
    EnsureDataDir()

    local key  = GetPlayerStorageKey(ply)
    local path = DATA_DIR .. "/" .. key .. ".json"

    local data = {
        points            = 0,
        total_points      = 0,
        intercepts        = 0,
        unlocked_upgrades = {},
    }

    if file.Exists(path, "DATA") then
        local raw = file.Read(path, "DATA")
        if raw and raw ~= "" then
            local decoded = util.JSONToTable(raw)
            if istable(decoded) then
                data.points            = tonumber(decoded.points or decoded.current_intercepts) or 0
                data.total_points      = tonumber(decoded.total_points or decoded.points or decoded.current_intercepts) or 0
                data.intercepts        = tonumber(decoded.intercepts or decoded.total_intercepts) or 0
                data.unlocked_upgrades = decoded.unlocked_upgrades or {}
            end
        end
    end

    -- Backwards-compatibility aliases
    data.current_intercepts = data.points
    data.total_intercepts   = data.intercepts

    TIV.Progression.PlayerData[key] = data
    TIV.Progression.SyncToPlayer(ply)
    return data
end

function TIV.Progression.SavePlayerProfile(ply)
    if not IsValid(ply) then return end
    EnsureDataDir()

    local key  = GetPlayerStorageKey(ply)
    local data = TIV.Progression.PlayerData[key]
    if not data then return end

    data.current_intercepts = data.points
    data.total_intercepts   = data.intercepts

    local path = DATA_DIR .. "/" .. key .. ".json"
    file.Write(path, util.TableToJSON(data, true))
end

-- ============================================================================
-- NETWORKING
-- ============================================================================
function TIV.Progression.SyncToPlayer(ply)
    if not IsValid(ply) then return end
    local profile = TIV.Progression.GetPlayerProfile(ply)
    if not profile then return end

    net.Start("TIV_SyncProgression")
        net.WriteUInt(profile.points or 0, 16)
        net.WriteUInt(profile.total_points or 0, 16)
        net.WriteUInt(profile.intercepts or 0, 16)

        local count = 0
        for id, state in pairs(profile.unlocked_upgrades or {}) do
            if state then count = count + 1 end
        end
        net.WriteUInt(count, 8)

        for id, state in pairs(profile.unlocked_upgrades or {}) do
            if state then
                net.WriteString(id)
            end
        end
    net.Send(ply)
end

-- ============================================================================
-- AWARD INTERCEPTS (Count of storms intercepted)
-- ============================================================================
function TIV.Progression.AwardIntercept(ply, reason)
    if not IsValid(ply) then return end
    local profile = TIV.Progression.GetPlayerProfile(ply)
    if not profile then return end

    profile.intercepts = (profile.intercepts or 0) + 1
    profile.total_intercepts = profile.intercepts

    TIV.Progression.SavePlayerProfile(ply)
    TIV.Progression.SyncToPlayer(ply)

    net.Start("TIV_InterceptAwarded")
        net.WriteUInt(profile.intercepts, 16)
        net.WriteString(reason or "Tornado Intercept Confirmed")
    net.Send(ply)

    print(string.format("[TIV] Intercept confirmed for %s: %s (Career Total Intercepts: %d)",
        ply:Nick(), reason or "Tornado Intercept", profile.intercepts))

    local veh = (TIV.ResolveVehicle and TIV.ResolveVehicle(ply)) or ply:GetVehicle()
    if IsValid(veh) and TIV.Wire and TIV.Wire.UpdateOutputs then
        TIV.Wire.UpdateOutputs(veh)
    end
end

-- ============================================================================
-- AWARD POINTS (Spendable upgrade currency that piles up over time)
-- ============================================================================
function TIV.Progression.AwardPoints(ply, amount, reason)
    if not IsValid(ply) or amount <= 0 then return end
    local profile = TIV.Progression.GetPlayerProfile(ply)
    if not profile then return end

    profile.points       = (profile.points or 0) + amount
    profile.total_points = (profile.total_points or 0) + amount
    profile.current_intercepts = profile.points

    TIV.Progression.SavePlayerProfile(ply)
    TIV.Progression.SyncToPlayer(ply)

    net.Start("TIV_PointsAwarded")
        net.WriteUInt(amount, 8)
        net.WriteUInt(profile.points, 16)
        net.WriteUInt(profile.total_points, 16)
        net.WriteUInt(profile.intercepts or 0, 16)
        net.WriteString(reason or "Severe Storm Intercept Hold")
    net.Send(ply)

    print(string.format("[TIV] Awarded %d points to %s: %s (Balance: %d pts, Career Intercepts: %d)",
        amount, ply:Nick(), reason or "Storm Intercept Hold", profile.points, profile.intercepts or 0))

    local veh = (TIV.ResolveVehicle and TIV.ResolveVehicle(ply)) or ply:GetVehicle()
    if IsValid(veh) and TIV.Wire and TIV.Wire.UpdateOutputs then
        TIV.Wire.UpdateOutputs(veh)
    end
end

-- Backwards compatibility alias
TIV.Progression.AwardIntercepts = function(ply, amount, reason)
    TIV.Progression.AwardPoints(ply, amount, reason)
end

-- ============================================================================
-- PURCHASE UPGRADE
-- ============================================================================
function TIV.Progression.PurchaseUpgrade(ply, upgradeID)
    if not IsValid(ply) or not upgradeID then return false, "Invalid request" end

    local upgrade = TIV.Progression.GetUpgrade(upgradeID)
    if not upgrade then
        return false, "Upgrade does not exist"
    end

    local profile = TIV.Progression.GetPlayerProfile(ply)
    if not profile then
        return false, "Player profile unavailable"
    end

    if profile.unlocked_upgrades[upgradeID] then
        return false, "Upgrade is already unlocked"
    end

    if (profile.points or 0) < upgrade.cost then
        return false, string.format("Insufficient Points (Requires %d, have %d)", upgrade.cost, profile.points or 0)
    end

    -- Process transaction
    profile.points = (profile.points or 0) - upgrade.cost
    profile.current_intercepts = profile.points
    profile.unlocked_upgrades[upgradeID] = true

    TIV.Progression.SavePlayerProfile(ply)
    TIV.Progression.SyncToPlayer(ply)

    print(string.format("[TIV] %s unlocked upgrade: %s (Spent %d Points, Balance: %d)",
        ply:Nick(), upgrade.name, upgrade.cost, profile.points))

    -- Re-evaluate vehicle bonuses, armor panels, and angled spikes
    TIV.Progression.UpdatePlayerVehicles(ply, upgradeID)

    return true, "Upgrade unlocked successfully!"
end

function TIV.Progression.UpdatePlayerVehicles(ply, upgradeID)
    if not IsValid(ply) then return end
    for _, veh in ipairs(ents.FindByClass("prop_vehicle_*")) do
        if TIV.IsSupportedVehicle(veh) then
            local isOwner = (veh._TIVOwner == ply) or (veh:GetDriver() == ply)
                or (veh.CPPIGetOwner and veh:CPPIGetOwner() == ply)
                or game.SinglePlayer()
            if isOwner then
                veh._TIVOwner = ply
                veh._TIVArmorNeedsRebuild = true
                if TIV.CustomComponents and TIV.CustomComponents.EnsureArmor then
                    TIV.CustomComponents.EnsureArmor(veh, ply)
                end
                if TIV.CustomComponents and TIV.CustomComponents.ApplyVehicleBonuses then
                    TIV.CustomComponents.ApplyVehicleBonuses(veh)
                end
                if TIV.Wire and TIV.Wire.UpdateOutputs then
                    TIV.Wire.UpdateOutputs(veh)
                end

                -- If angled spikes or all upgrades unlocked, rebuild spikes if vehicle is idle
                if upgradeID == "angled_spikes" or upgradeID == nil then
                    local data = TIV.Deploy and TIV.Deploy.GetState and TIV.Deploy.GetState(veh)
                    if data and data.state == "idle" then
                        TIV.Anchor.DetachAll(veh, data)
                        TIV.Spikes.RemoveAll(data, veh:EntIndex())
                        data.spikesCreated = false
                        TIV.Deploy.EnsureSpikes(veh, data)
                    end
                end
            end
        end
    end
end

net.Receive("TIV_PurchaseUpgrade", function(len, ply)
    if not IsValid(ply) then return end
    local upgID = net.ReadString()
    TIV.Progression.PurchaseUpgrade(ply, upgID)
end)

net.Receive("TIV_RequestProgression", function(len, ply)
    if not IsValid(ply) then return end
    TIV.Progression.SyncToPlayer(ply)
end)

net.Receive("TIV_CheatAction", function(len, ply)
    if not IsValid(ply) then return end

    local cheatsAllowed = game.SinglePlayer() or ply:IsAdmin()
        or (GetConVar("tiv_cheats_enabled") and GetConVar("tiv_cheats_enabled"):GetBool())
    if not cheatsAllowed then
        ply:ChatPrint("[TIV] Cheats are restricted to administrators.")
        return
    end

    local action = net.ReadString()
    local arg = net.ReadInt(32)
    local profile = TIV.Progression.GetPlayerProfile(ply)
    if not profile then return end

    if action == "unlock_all" then
        for _, u in ipairs(TIV.Progression.GetAllUpgrades()) do
            profile.unlocked_upgrades[u.id] = true
        end
        TIV.Progression.SavePlayerProfile(ply)
        TIV.Progression.SyncToPlayer(ply)
        ply:ChatPrint("[TIV Cheat] All upgrades have been unlocked!")

        TIV.Progression.UpdatePlayerVehicles(ply, nil)
    elseif action == "add_points" or action == "add_points_10" or action == "add_points_50" then
        local amt = (arg and arg > 0) and arg or (action == "add_points_50" and 50 or 10)
        TIV.Progression.AwardPoints(ply, amt, "Cheat Sandbox Grant (+" .. amt .. " Pts)")
    elseif action == "add_intercept" or action == "add_intercepts" then
        local amt = (arg and arg > 0) and arg or 1
        for i = 1, amt do
            TIV.Progression.AwardIntercept(ply, "Cheat Sandbox Intercept Grant")
        end
    elseif action == "reset" or action == "reset_progression" then
        profile.points             = 0
        profile.total_points       = 0
        profile.intercepts         = 0
        profile.current_intercepts = 0
        profile.total_intercepts   = 0
        profile.unlocked_upgrades  = {}
        TIV.Progression.SavePlayerProfile(ply)
        TIV.Progression.SyncToPlayer(ply)
        ply:ChatPrint("[TIV Cheat] Progression, points, and intercepts reset.")

        TIV.Progression.UpdatePlayerVehicles(ply, nil)
    end
end)

concommand.Add("tiv_unlock_all", function(ply)
    if IsValid(ply) then
        local cheatsAllowed = game.SinglePlayer() or ply:IsAdmin()
            or (GetConVar("tiv_cheats_enabled") and GetConVar("tiv_cheats_enabled"):GetBool())
        if not cheatsAllowed then return end
        local profile = TIV.Progression.GetPlayerProfile(ply)
        if profile then
            for _, u in ipairs(TIV.Progression.GetAllUpgrades()) do
                profile.unlocked_upgrades[u.id] = true
            end
            TIV.Progression.SavePlayerProfile(ply)
            TIV.Progression.SyncToPlayer(ply)
            ply:ChatPrint("[TIV] All upgrades unlocked via console command.")

            TIV.Progression.UpdatePlayerVehicles(ply, nil)
        end
    end
end)

-- ============================================================================
-- STORM INTERCEPT EVALUATION LOOP
-- Uses GStorms, XT2, and XT3 to detect when a tornado is over an anchored vehicle.
-- Immediately awards 1 intercept upon entry, then points pile up over time
-- for both side and core intercepts while holding ground.
-- ============================================================================
timer.Create("TIV_StormInterceptTracker", 1.0, 0, function()
    local activeVehicles = TIV.Deploy and TIV.Deploy.Vehicles
    if not activeVehicles then return end

    local now = CurTime()

    for entIdx, data in pairs(activeVehicles) do
        local veh = Entity(entIdx)
        if IsValid(veh) then
            local tracker = TIV.Progression.ActiveTracking[entIdx]
            if not tracker then
                tracker = {
                    timeInIntercept = 0,
                    lastPointAward  = now,
                    interceptActive = false,
                    interceptType   = nil,
                }
                TIV.Progression.ActiveTracking[entIdx] = tracker
            end

            local state   = data.state or "idle"
            local windMPH = TIV.Wind and TIV.Wind.GetSpeed and TIV.Wind.GetSpeed(veh) or 0

            -- Gather vehicle occupants (driver and passengers)
            local occupants = {}
            local driver  = veh.GetDriver and veh:GetDriver() or nil
            if IsValid(driver) then table.insert(occupants, driver) end

            for _, p in ipairs(player.GetAll()) do
                if IsValid(p) and p ~= driver then
                    local pVeh = p:GetVehicle()
                    if IsValid(pVeh) and (pVeh == veh or (IsValid(pVeh:GetParent()) and pVeh:GetParent() == veh)) then
                        table.insert(occupants, p)
                    end
                end
            end

            if #occupants == 0 and IsValid(veh._TIVOwner) and veh._TIVOwner:GetPos():DistToSqr(veh:GetPos()) < 1500 * 1500 then
                table.insert(occupants, veh._TIVOwner)
            end

            -- Evaluate active tornado presence from GStorms, XT2, & XT3
            local tInfo = TIV.Wind and TIV.Wind.GetNearestActiveTornado and TIV.Wind.GetNearestActiveTornado(veh:GetPos())
            local inCore = false
            local inSide = false

            if tInfo then
                local dist = tInfo.dist
                if dist <= tInfo.coreRadius then
                    inCore = true
                    inSide = true
                elseif dist <= tInfo.outerRadius then
                    inSide = true
                end
            end

            -- Ambient wind fallback check (supports custom weather storms or manual test overrides)
            if windMPH >= 130 then
                inCore = true
                inSide = true
            elseif windMPH >= 70 then
                inSide = true
            end

            local isOverVehicle = inCore or inSide
            local currentType   = inCore and "core" or (inSide and "side" or nil)

            -- Interception scoring only applies while vehicle is solidly anchored with occupants
            if state == "anchored" and isOverVehicle and #occupants > 0 then
                if not tracker.interceptActive then
                    -- Tornado reached anchored vehicle or vehicle latched under tornado:
                    -- 1. Award 1 Intercept count
                    -- 2. Award initial entry hold point
                    tracker.interceptActive = true
                    tracker.interceptType   = currentType
                    tracker.timeInIntercept = 0
                    tracker.lastPointAward  = now

                    local interceptLabel = (currentType == "core")
                        and "Tornado Core Intercept Confirmed"
                        or "Tornado Side Intercept Confirmed"

                    local pointReason = (currentType == "core")
                        and "Core Intercept Entry (+1 Pt)"
                        or "Side Intercept Entry (+1 Pt)"

                    for _, ply in ipairs(occupants) do
                        TIV.Progression.AwardIntercept(ply, interceptLabel)
                        TIV.Progression.AwardPoints(ply, 1, pointReason)
                    end
                else
                    -- Escalate from side to core if vehicle enters inner eye/core
                    if tracker.interceptType == "side" and currentType == "core" then
                        tracker.interceptType = "core"
                    end

                    tracker.timeInIntercept = tracker.timeInIntercept + 1.0

                    -- Points pile up over time: 5s for Core, 8s for Side
                    local awardInterval = (tracker.interceptType == "core") and 5.0 or 8.0
                    if (now - tracker.lastPointAward) >= awardInterval then
                        tracker.lastPointAward = now

                        local holdLabel = (tracker.interceptType == "core")
                            and string.format("Core Intercept Hold [%.0fs]", tracker.timeInIntercept)
                            or string.format("Side Intercept Hold [%.0fs]", tracker.timeInIntercept)

                        for _, ply in ipairs(occupants) do
                            TIV.Progression.AwardPoints(ply, 1, holdLabel)
                        end
                    end
                end
            else
                -- Vehicle left tornado or unanchored/lofted
                if tracker.interceptActive then
                    tracker.interceptActive = false
                    tracker.timeInIntercept = 0
                    tracker.interceptType   = nil
                end
            end
        else
            TIV.Progression.ActiveTracking[entIdx] = nil
        end
    end
end)

-- ============================================================================
-- EVENT HOOKS
-- ============================================================================
hook.Add("PlayerInitialSpawn", "TIV_ProgressionInit", function(ply)
    timer.Simple(1.5, function()
        if IsValid(ply) then
            TIV.Progression.LoadPlayerProfile(ply)
        end
    end)
end)

hook.Add("PlayerEnteredVehicle", "TIV_ProgressionEnter", function(ply, veh)
    local tivVeh = TIV.Deploy and TIV.Deploy.ResolveVehicle and TIV.Deploy.ResolveVehicle(ply)
    if IsValid(tivVeh) then
        TIV.Progression.SyncToPlayer(ply)
        tivVeh._TIVOwner = ply
        if TIV.CustomComponents and TIV.CustomComponents.EnsureArmor then
            TIV.CustomComponents.EnsureArmor(tivVeh, ply)
        end
        if TIV.CustomComponents and TIV.CustomComponents.ApplyVehicleBonuses then
            TIV.CustomComponents.ApplyVehicleBonuses(tivVeh)
        end
    end
end)

-- ============================================================================
-- CONSOLE COMMANDS
-- ============================================================================
local function CanAdmin(ply)
    if not IsValid(ply) then return true end
    if game.SinglePlayer() then return true end
    return ply:IsAdmin()
end

concommand.Add("tiv_award_points", function(ply, cmd, args)
    if not CanAdmin(ply) then return end
    local amount = tonumber(args[1]) or 1
    local target = ply

    if args[2] then
        for _, p in ipairs(player.GetAll()) do
            if string.find(string.lower(p:Nick()), string.lower(args[2]), 1, true) then
                target = p
                break
            end
        end
    end

    if IsValid(target) then
        TIV.Progression.AwardPoints(target, amount, "Manual Administrative Award")
    end
end)

concommand.Add("tiv_award_intercept", function(ply, cmd, args)
    if not CanAdmin(ply) then return end
    local target = ply

    if args[1] then
        for _, p in ipairs(player.GetAll()) do
            if string.find(string.lower(p:Nick()), string.lower(args[1]), 1, true) then
                target = p
                break
            end
        end
    end

    if IsValid(target) then
        TIV.Progression.AwardIntercept(target, "Manual Administrative Award")
    end
end)

concommand.Add("tiv_reset_progression", function(ply, cmd, args)
    if not CanAdmin(ply) then return end
    local target = ply
    if args[1] then
        for _, p in ipairs(player.GetAll()) do
            if string.find(string.lower(p:Nick()), string.lower(args[1]), 1, true) then
                target = p
                break
            end
        end
    end

    if IsValid(target) then
        local key = GetPlayerStorageKey(target)
        TIV.Progression.PlayerData[key] = {
            points             = 0,
            total_points       = 0,
            intercepts         = 0,
            current_intercepts = 0,
            total_intercepts   = 0,
            unlocked_upgrades  = {},
        }
        TIV.Progression.SavePlayerProfile(target)
        TIV.Progression.SyncToPlayer(target)
        print("[TIV] Progression reset for " .. target:Nick())
    end
end)

print("[TIV] Server progression system loaded")
