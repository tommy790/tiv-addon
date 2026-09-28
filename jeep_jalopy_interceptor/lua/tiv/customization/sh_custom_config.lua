-- ============================================================================
-- TIV VEHICLE CUSTOM CONFIGURATION - Shared
-- Deterministic, AI-friendly configuration serializer, deserializer,
-- default vehicle presets, and physics integration.
--
-- Coordinate space: Strictly Vehicle Local
--   Forward: +Y (along veh:GetForward())
--   Right:   +X (along veh:GetRight())
--   Up:      +Z (along veh:GetUp())
-- ============================================================================

TIV = TIV or {}
TIV.CustomConfig = TIV.CustomConfig or {}

-- ============================================================================
-- CURATED PROP & MODEL PRESETS FOR 3D EDITOR
-- ============================================================================
TIV.CustomConfig.CuratedModels = {
    spikes = {
        { name = "Heavy Harpoon",            model = "models/props_junk/harpoon002a.mdl" },
        { name = "Combine Ram Lever",        model = "models/props_c17/TrapPropeller_Lever.mdl" },
        { name = "Reinforced Steel Rod",     model = "models/props_c17/trappropbars_klab.mdl" },
        { name = "Industrial Hydraulic Ram", model = "models/props_wasteland/panel_lever001.mdl" },
        { name = "Ladder Rail Penetrators",  model = "models/props_c17/metalladder001.mdl" },
    },
    armor_side = {
        { name = "PHX Metal Plate 1x2",      model = "models/props_phx/construct/metal_plate1x2.mdl" },
        { name = "PHX Metal Plate 2x2",      model = "models/props_phx/construct/metal_plate2x2.mdl" },
        { name = "PHX Metal Plate 1x1",      model = "models/props_phx/construct/metal_plate1x1.mdl" },
        { name = "Corrugated Steel Sheet",   model = "models/props_c17/fence01a.mdl" },
        { name = "Combine Heavy Blast Plate",model = "models/props_combine/combine_fence01b.mdl" },
        { name = "Heavy Steel Ballast Plate",model = "models/props_c17/furnituredrawer001a_chunk01.mdl" },
        { name = "Slag Armor Panel",         model = "models/props_debris/metal_panel01a.mdl" },
        { name = "Ribbed Alloy Plate",       model = "models/props_debris/metal_panel02a.mdl" },
    },
    armor_front = {
        { name = "PHX Metal Plate 1x2",      model = "models/props_phx/construct/metal_plate1x2.mdl" },
        { name = "PHX Metal Plate 2x2",      model = "models/props_phx/construct/metal_plate2x2.mdl" },
        { name = "PHX Metal Plate 1x1",      model = "models/props_phx/construct/metal_plate1x1.mdl" },
        { name = "Combine Front Cowl",       model = "models/props_combine/combine_fence01b.mdl" },
        { name = "Angled Wedge Plate",       model = "models/props_debris/metal_panel01a.mdl" },
        { name = "Heavy Vault Shutter",      model = "models/props_lab/blastdoor001c.mdl" },
        { name = "Grille Cowling Plate",     model = "models/props_trainstation/traincar_rack001.mdl" },
    },
    armor_roof = {
        { name = "PHX Metal Plate 1x2",      model = "models/props_phx/construct/metal_plate1x2.mdl" },
        { name = "PHX Metal Plate 2x2",      model = "models/props_phx/construct/metal_plate2x2.mdl" },
        { name = "Combine Roof Shield",      model = "models/props_combine/combine_fence01b.mdl" },
        { name = "Corrugated Air Deflector", model = "models/props_c17/fence01a.mdl" },
        { name = "Slag Roof Plate",          model = "models/props_debris/metal_panel02a.mdl" },
    },
    hydraulic_ram = {
        { name = "Combine Ram Lever",        model = "models/props_c17/TrapPropeller_Lever.mdl" },
        { name = "Industrial Hydraulic Ram", model = "models/props_wasteland/panel_lever001.mdl" },
        { name = "Reinforced Steel Rod",     model = "models/props_c17/trappropbars_klab.mdl" },
        { name = "Heavy Piston Column",      model = "models/props_c17/utilityconnectors006.mdl" },
    },
    radar_screen = {
        { name = "Wiremod Small Monitor",    model = "models/kobilica/wiremonitorsmall.mdl" },
        { name = "Lab Digital Monitor",      model = "models/props_lab/monitor01b.mdl" },
        { name = "Small TV Display",         model = "models/props_c17/tv_monitor01.mdl" },
        { name = "Lab Desktop Terminal",     model = "models/props_lab/monitor02.mdl" },
    }
}

-- Components are typed "spike" (singular) but this list was originally keyed
-- "spikes", so the editor's CuratedModels[curComp.type] lookup missed and fell
-- back to the spike list by luck. Alias it so the lookup is correct either way.
TIV.CustomConfig.CuratedModels.spike = TIV.CustomConfig.CuratedModels.spikes

-- ============================================================================
-- MODEL CONFIGURATION PERSISTENCE & FILE HELPERS
-- ============================================================================
TIV.CustomConfig.VehicleConfigs = TIV.CustomConfig.VehicleConfigs or {}

function TIV.CustomConfig.GetConfigFileName(model)
    local sanitized = string.lower(model or "models/buggy.mdl")
    sanitized = string.gsub(sanitized, "%.mdl$", "")
    sanitized = string.gsub(sanitized, "[^%w_%-]", "_")
    return "tiv/configs/" .. sanitized .. ".json"
end

function TIV.CustomConfig.GetSavedConfig(model)
    if not model or model == "" then return nil end
    model = string.lower(model)

    -- In-memory cache
    if TIV.CustomConfig.VehicleConfigs and TIV.CustomConfig.VehicleConfigs[model] then
        return table.Copy(TIV.CustomConfig.VehicleConfigs[model])
    end

    -- Check model config file
    local sPath = TIV.CustomConfig.GetConfigFileName(model)
    if file.Exists(sPath, "DATA") then
        local raw = file.Read(sPath, "DATA")
        local decoded, err = TIV.CustomConfig.DeserializeFromLua(raw or "")
        if decoded and istable(decoded.components) then
            decoded.vehicle_model = model
            TIV.CustomConfig.MigrateSpikeMounts(decoded)
            TIV.CustomConfig.VehicleConfigs = TIV.CustomConfig.VehicleConfigs or {}
            TIV.CustomConfig.VehicleConfigs[model] = decoded
            return table.Copy(decoded)
        end
    end

    return nil
end

--- Brings a saved config's spike mounts up to what the factory config for the
--- same model defines.
---
--- Configs saved before the Heavy Anchor Array existed hold only six mounts.
--- TIV.Spikes.ResolveCount takes its *ceiling* from max_spikes but its *value*
--- from how many mounts the config actually defines, so a saved layout keeps
--- six anchors forever and the upgrade stays invisible for exactly the players
--- who had already saved one. Measured against the user's own exported buggy
--- config: max_spikes 8, ResolveCount 6.
---
--- The missing mounts are copied from the factory config for that model rather
--- than derived from the saved layout's geometry. Deriving them was tried first
--- -- "outboard of the widest row, at that row's height" -- and both exports
--- disproved it: the verified buggy mounts are an extra row at (+/-25, 20), not
--- outboard, and the verified jalopy mounts sit far behind the rear axle. Each
--- model's extra mounts are bespoke, so the only defensible source is that
--- model's own verified factory placement.
function TIV.CustomConfig.MigrateSpikeMounts(config)
    if not config or not istable(config.components) then return config end

    local count = 0
    for _, c in ipairs(config.components) do
        if c.type == "spike" then count = count + 1 end
    end
    if count == 0 then return config end

    local factory = TIV.CustomConfig.GetDefaultConfig(config.vehicle_model, true)
    local factorySpikes = {}
    for _, c in ipairs(factory.components or {}) do
        if c.type == "spike" then factorySpikes[#factorySpikes + 1] = c end
    end
    if #factorySpikes <= count then return config end

    local used = {}
    for _, c in ipairs(config.components) do if c.id then used[c.id] = true end end

    -- The factory lists its standard mounts first and the extra ones last, so
    -- the tail is exactly what a config saved before they existed cannot have.
    for i = count + 1, #factorySpikes do
        local src = factorySpikes[i]
        local id = src.id
        if used[id] then id = "spike_added_" .. (#config.components + 1) end
        used[id] = true

        table.insert(config.components, {
            id    = id,
            type  = "spike",
            name  = src.name,
            group = "migrated",
            model = src.model,
            pos   = Vector(src.pos.x, src.pos.y, src.pos.z),
            ang   = Angle(src.ang.p, src.ang.y, src.ang.r),
            scale = Vector(1.00, 1.00, 1.00),
        })
    end

    return config
end

-- ============================================================================
-- DEFAULT FACTORY CONFIGURATIONS PER VEHICLE MODEL
-- ============================================================================
function TIV.CustomConfig.GetDefaultConfig(vehicleModel, hasAngledSpikes)
    vehicleModel = string.lower(vehicleModel or "models/buggy.mdl")

    if hasAngledSpikes == nil then
        if CLIENT and TIV.Progression and TIV.Progression.IsUnlocked then
            hasAngledSpikes = TIV.Progression.IsUnlocked("angled_spikes")
        else
            hasAngledSpikes = false
        end
    end

    local config = {
        vehicle_model = vehicleModel,
        components    = {},
    }

    local rightSpikeAng = (hasAngledSpikes == true) and Angle( 80.00, 0.00, 0.00) or Angle(90.00, 0.00, 0.00)
    local leftSpikeAng  = (hasAngledSpikes == true) and Angle(100.00, 0.00, 0.00) or Angle(90.00, 0.00, 0.00)

    -- Only the jalopy mirrors its two extra mounts by yaw -- Angle(80, 180, 0) on
    -- the left rather than Angle(100, 0, 0). The verified buggy mounts use the
    -- ordinary pitch convention above, so these apply to the jalopy branch alone.
    -- Both still go vertical when angled_spikes is locked, which the upgrade
    -- check depends on.
    local rightOuterAng = (hasAngledSpikes == true) and Angle( 80.00,   0.00, 0.00) or Angle(90.00, 0.00, 0.00)
    local leftOuterAng  = (hasAngledSpikes == true) and Angle( 80.00, 180.00, 0.00) or Angle(90.00, 0.00, 0.00)

    if string.find(vehicleModel, "jalopy", 1, true) or string.find(vehicleModel, "vehicle.mdl", 1, true) then
        config.components = {
            -- 6 Standard Spikes
            { id = "spike_fr", type = "spike", name = "Front Right Spike", group = "front", model = "models/props_junk/harpoon002a.mdl", pos = Vector( 25.00,  45.00, 0.00), ang = rightSpikeAng, scale = Vector(1.00, 1.00, 1.00) },
            { id = "spike_fl", type = "spike", name = "Front Left Spike",  group = "front", model = "models/props_junk/harpoon002a.mdl", pos = Vector(-25.00,  45.00, 0.00), ang = leftSpikeAng,  scale = Vector(1.00, 1.00, 1.00) },
            { id = "spike_mr", type = "spike", name = "Mid Right Spike",    group = "mid",   model = "models/props_junk/harpoon002a.mdl", pos = Vector( 25.00,   0.00, 0.00), ang = rightSpikeAng, scale = Vector(1.00, 1.00, 1.00) },
            { id = "spike_ml", type = "spike", name = "Mid Left Spike",     group = "mid",   model = "models/props_junk/harpoon002a.mdl", pos = Vector(-25.00,   0.00, 0.00), ang = leftSpikeAng,  scale = Vector(1.00, 1.00, 1.00) },
            { id = "spike_rr", type = "spike", name = "Rear Right Spike",   group = "rear",  model = "models/props_junk/harpoon002a.mdl", pos = Vector( 25.00,-100.00, 0.00), ang = rightSpikeAng, scale = Vector(1.00, 1.00, 1.00) },
            { id = "spike_rl", type = "spike", name = "Rear Left Spike",    group = "rear",  model = "models/props_junk/harpoon002a.mdl", pos = Vector(-25.00,-100.00, 0.00), ang = leftSpikeAng,  scale = Vector(1.00, 1.00, 1.00) },

            -- Heavy Anchor Array: two extra mounts, only used once
            -- heavy_cluster_spikes is unlocked (the count is capped without it).
            { id = "spike_or", type = "spike", name = "Outer Right Spike", group = "mid", model = "models/props_junk/harpoon002a.mdl", pos = Vector(  44.90, -135.00,   10.00), ang = rightOuterAng, scale = Vector(1.00, 1.00, 1.00) },  -- user-verified in game
            { id = "spike_ol", type = "spike", name = "Outer Left Spike", group = "mid", model = "models/props_junk/harpoon002a.mdl", pos = Vector( -44.90, -135.00,   10.00), ang = leftOuterAng, scale = Vector(1.00, 1.00, 1.00) },

            -- Armor Panels (Metal Plates 1x2)
            { id = "armor_sl", type = "armor_side",  name = "Left Metal Plate",  group = "side",  model = "models/props_phx/construct/metal_plate1x2.mdl", pos = Vector(-48.00, -39.00, 40.80), ang = Angle(-90.00, 90.00, 90.00), scale = Vector(1.00, 1.00, 1.00) },
            { id = "armor_sr", type = "armor_side",  name = "Right Metal Plate", group = "side",  model = "models/props_phx/construct/metal_plate1x2.mdl", pos = Vector( 44.00, -39.00, 40.80), ang = Angle(-90.00, 90.00, 90.00), scale = Vector(1.00, 1.00, 1.00) },
            { id = "armor_fa", type = "armor_front", name = "Front Metal Plate", group = "front", model = "models/props_phx/construct/metal_plate1x2.mdl", pos = Vector(  0.00,  57.40, 45.00), ang = Angle(-165.00, 90.00, 0.00), scale = Vector(1.00, 1.00, 1.00) },

            -- Roof cowl (roof_spoiler) and hydraulic rams (reinforced_hydraulics).
            -- These three branches are NOT user-verified. An earlier version derived
            -- them from offsets fitted to the buggy alone, and the jalopy export
            -- disproved every one of them, so they are back to plain guesses. The
            -- ram height is the exception: it is z = 30.0 on both verified vehicles
            -- even though their side armour sits at 31.8 and 40.8, so 30 is used
            -- here too.
            { id = "armor_roof", type = "armor_roof", name = "Roof Cowl", group = "roof", model = "models/props_phx/construct/metal_plate1x2.mdl", pos = Vector(   0.00,  -17.80,   67.50), ang = Angle(  6.90,  90.00,   0.00), scale = Vector(1.00, 1.00, 1.00) },  -- user-verified in game
            { id = "hyd_rl", type = "hydraulic_ram", name = "Right Hydraulic Ram", group = "hydraulics", model = "models/props_c17/TrapPropeller_Lever.mdl", pos = Vector(  35.00,    0.00,   30.00), ang = Angle( 90.00,   0.00,   0.00), scale = Vector(1.00, 1.00, 1.00) },  -- user-verified in game
            { id = "hyd_ll", type = "hydraulic_ram", name = "Left Hydraulic Ram",  group = "hydraulics", model = "models/props_c17/TrapPropeller_Lever.mdl", pos = Vector( -35.00,    0.00,   30.00), ang = Angle( 90.00,   0.00,   0.00), scale = Vector(1.00, 1.00, 1.00) },

            -- Tactical Path Prediction Screen
            { id = "screen_radar", type = "radar_screen", name = "Path Prediction Screen", group = "interior", model = "models/kobilica/wiremonitorsmall.mdl", pos = Vector( 14.00,  14.00, 42.00), ang = Angle(10.00, -125.00, 0.00), scale = Vector(1.00, 1.00, 1.00) },
        }
    elseif string.find(vehicleModel, "apc", 1, true) then
        config.components = {
            { id = "spike_fr", type = "spike", name = "Front Right Spike", group = "front", model = "models/props_junk/harpoon002a.mdl", pos = Vector( 35.00,  90.00, 0.00), ang = rightSpikeAng, scale = Vector(1.00, 1.00, 1.00) },
            { id = "spike_fl", type = "spike", name = "Front Left Spike",  group = "front", model = "models/props_junk/harpoon002a.mdl", pos = Vector(-35.00,  90.00, 0.00), ang = leftSpikeAng,  scale = Vector(1.00, 1.00, 1.00) },
            { id = "spike_mr", type = "spike", name = "Mid Right Spike",    group = "mid",   model = "models/props_junk/harpoon002a.mdl", pos = Vector( 35.00,  10.00, 0.00), ang = rightSpikeAng, scale = Vector(1.00, 1.00, 1.00) },
            { id = "spike_ml", type = "spike", name = "Mid Left Spike",     group = "mid",   model = "models/props_junk/harpoon002a.mdl", pos = Vector(-35.00,  10.00, 0.00), ang = leftSpikeAng,  scale = Vector(1.00, 1.00, 1.00) },
            { id = "spike_rr", type = "spike", name = "Rear Right Spike",   group = "rear",  model = "models/props_junk/harpoon002a.mdl", pos = Vector( 35.00,-110.00, 0.00), ang = rightSpikeAng, scale = Vector(1.00, 1.00, 1.00) },
            { id = "spike_rl", type = "spike", name = "Rear Left Spike",    group = "rear",  model = "models/props_junk/harpoon002a.mdl", pos = Vector(-35.00,-110.00, 0.00), ang = leftSpikeAng,  scale = Vector(1.00, 1.00, 1.00) },

            -- Heavy Anchor Array: two extra mounts, only used once
            -- heavy_cluster_spikes is unlocked (the count is capped without it).
            { id = "spike_or", type = "spike", name = "Outer Right Spike", group = "mid", model = "models/props_junk/harpoon002a.mdl", pos = Vector(  25.00,  -20.00,    0.00), ang = rightSpikeAng, scale = Vector(1.00, 1.00, 1.00) },  -- user-verified in game
            { id = "spike_ol", type = "spike", name = "Outer Left Spike", group = "mid", model = "models/props_junk/harpoon002a.mdl", pos = Vector( -25.00,  -20.00,    0.00), ang = leftSpikeAng, scale = Vector(1.00, 1.00, 1.00) },

            { id = "armor_sl", type = "armor_side",  name = "Left Metal Plate",  group = "side",  model = "models/props_phx/construct/metal_plate1x2.mdl", pos = Vector(-56.40,  -6.20, 49.20), ang = Angle(-90.00, 90.00, 90.00), scale = Vector(1.00, 1.00, 1.00) },
            { id = "armor_sr", type = "armor_side",  name = "Right Metal Plate", group = "side",  model = "models/props_phx/construct/metal_plate1x2.mdl", pos = Vector( 56.40,  -6.20, 49.20), ang = Angle(-90.00, 90.00, 90.00), scale = Vector(1.00, 1.00, 1.00) },
            { id = "armor_fa", type = "armor_front", name = "Front Metal Plate", group = "front", model = "models/props_phx/construct/metal_plate1x2.mdl", pos = Vector(  0.00, 106.70, 61.70), ang = Angle(-120.00, 90.00, 0.00), scale = Vector(1.00, 1.00, 1.00) },

            -- Roof cowl (roof_spoiler) and hydraulic rams (reinforced_hydraulics).
            -- These three branches are NOT user-verified. An earlier version derived
            -- them from offsets fitted to the buggy alone, and the jalopy export
            -- disproved every one of them, so they are back to plain guesses. The
            -- ram height is the exception: it is z = 30.0 on both verified vehicles
            -- even though their side armour sits at 31.8 and 40.8, so 30 is used
            -- here too.
            { id = "armor_roof", type = "armor_roof", name = "Roof Cowl", group = "roof", model = "models/props_phx/construct/metal_plate1x2.mdl", pos = Vector(   0.00,   75.90,   80.00), ang = Angle(166.20, -90.00,   0.00), scale = Vector(1.00, 1.00, 1.00) },  -- user-verified in game
            { id = "hyd_rl", type = "hydraulic_ram", name = "Right Hydraulic Ram", group = "hydraulics", model = "models/props_c17/TrapPropeller_Lever.mdl", pos = Vector(  35.00,    0.00,   30.00), ang = Angle( 90.00,   0.00,   0.00), scale = Vector(1.00, 1.00, 1.00) },  -- user-verified in game
            { id = "hyd_ll", type = "hydraulic_ram", name = "Left Hydraulic Ram",  group = "hydraulics", model = "models/props_c17/TrapPropeller_Lever.mdl", pos = Vector( -35.00,    0.00,   30.00), ang = Angle( 90.00,   0.00,   0.00), scale = Vector(1.00, 1.00, 1.00) },

            -- Tactical Path Prediction Screen
            { id = "screen_radar", type = "radar_screen", name = "Path Prediction Screen", group = "interior", model = "models/kobilica/wiremonitorsmall.mdl", pos = Vector(  -8.00,   -0.10,   80.00), ang = Angle(-10.00, -75.00,   0.00), scale = Vector(1.00, 1.00, 1.00) },  -- user-verified in game
        }
    elseif string.find(vehicleModel, "airboat", 1, true) then
        config.components = {
            { id = "spike_fr", type = "spike", name = "Front Right Spike", group = "front", model = "models/props_junk/harpoon002a.mdl", pos = Vector( 26.00,  60.00, 0.00), ang = rightSpikeAng, scale = Vector(1.00, 1.00, 1.00) },
            { id = "spike_fl", type = "spike", name = "Front Left Spike",  group = "front", model = "models/props_junk/harpoon002a.mdl", pos = Vector(-26.00,  60.00, 0.00), ang = leftSpikeAng,  scale = Vector(1.00, 1.00, 1.00) },
            { id = "spike_mr", type = "spike", name = "Mid Right Spike",    group = "mid",   model = "models/props_junk/harpoon002a.mdl", pos = Vector( 28.00,   0.00, 0.00), ang = rightSpikeAng, scale = Vector(1.00, 1.00, 1.00) },
            { id = "spike_ml", type = "spike", name = "Mid Left Spike",     group = "mid",   model = "models/props_junk/harpoon002a.mdl", pos = Vector(-28.00,   0.00, 0.00), ang = leftSpikeAng,  scale = Vector(1.00, 1.00, 1.00) },
            { id = "spike_rr", type = "spike", name = "Rear Right Spike",   group = "rear",  model = "models/props_junk/harpoon002a.mdl", pos = Vector( 26.00, -60.00, 0.00), ang = rightSpikeAng, scale = Vector(1.00, 1.00, 1.00) },
            { id = "spike_rl", type = "spike", name = "Rear Left Spike",    group = "rear",  model = "models/props_junk/harpoon002a.mdl", pos = Vector(-26.00, -60.00, 0.00), ang = leftSpikeAng,  scale = Vector(1.00, 1.00, 1.00) },

            -- Heavy Anchor Array: two extra mounts, only used once
            -- heavy_cluster_spikes is unlocked (the count is capped without it).
            { id = "spike_or", type = "spike", name = "Outer Right Spike", group = "mid", model = "models/props_junk/harpoon002a.mdl", pos = Vector(  25.00,   30.00,    0.00), ang = rightSpikeAng, scale = Vector(1.00, 1.00, 1.00) },  -- NOT user-verified
            { id = "spike_ol", type = "spike", name = "Outer Left Spike", group = "mid", model = "models/props_junk/harpoon002a.mdl", pos = Vector( -25.00,   30.00,    0.00), ang = leftSpikeAng, scale = Vector(1.00, 1.00, 1.00) },

            { id = "armor_sl", type = "armor_side",  name = "Left Metal Plate",  group = "side",  model = "models/props_phx/construct/metal_plate1x2.mdl", pos = Vector(-36.00, -10.00, 16.00), ang = Angle(-90.00, 90.00, 90.00), scale = Vector(1.00, 1.00, 1.00) },
            { id = "armor_sr", type = "armor_side",  name = "Right Metal Plate", group = "side",  model = "models/props_phx/construct/metal_plate1x2.mdl", pos = Vector( 36.00, -10.00, 16.00), ang = Angle(-90.00, 90.00, 90.00), scale = Vector(1.00, 1.00, 1.00) },
            { id = "armor_fa", type = "armor_front", name = "Front Metal Plate", group = "front", model = "models/props_phx/construct/metal_plate1x2.mdl", pos = Vector(  0.00,  70.00, 18.00), ang = Angle(-85.00, 90.00,  0.00), scale = Vector(1.00, 1.00, 1.00) },

            -- Roof cowl (roof_spoiler) and hydraulic rams (reinforced_hydraulics).
            -- These three branches are NOT user-verified. An earlier version derived
            -- them from offsets fitted to the buggy alone, and the jalopy export
            -- disproved every one of them, so they are back to plain guesses. The
            -- ram height is the exception: it is z = 30.0 on both verified vehicles
            -- even though their side armour sits at 31.8 and 40.8, so 30 is used
            -- here too.
            { id = "armor_roof", type = "armor_roof", name = "Roof Cowl", group = "roof", model = "models/props_phx/construct/metal_plate1.mdl", pos = Vector(   0.00,  -29.20,   63.20), ang = Angle(  0.00,   0.00, 168.50), scale = Vector(1.00, 1.00, 1.00) },  -- NOT user-verified
            { id = "hyd_rl", type = "hydraulic_ram", name = "Right Hydraulic Ram", group = "hydraulics", model = "models/props_c17/TrapPropeller_Lever.mdl", pos = Vector(  35.00,    0.00,   30.00), ang = Angle( 90.00,   0.00,   0.00), scale = Vector(1.00, 1.00, 1.00) },  -- NOT user-verified
            { id = "hyd_ll", type = "hydraulic_ram", name = "Left Hydraulic Ram",  group = "hydraulics", model = "models/props_c17/TrapPropeller_Lever.mdl", pos = Vector( -35.00,    0.00,   30.00), ang = Angle( 90.00,   0.00,   0.00), scale = Vector(1.00, 1.00, 1.00) },

            -- Tactical Path Prediction Screen
            { id = "screen_radar", type = "radar_screen", name = "Path Prediction Screen", group = "interior", model = "models/kobilica/wiremonitorsmall.mdl", pos = Vector( 10.00,  20.00, 22.00), ang = Angle(10.00, -125.00, 0.00), scale = Vector(1.00, 1.00, 1.00) },
        }
    elseif string.find(vehicleModel, "van", 1, true) or string.find(vehicleModel, "truck", 1, true) or string.find(vehicleModel, "pickup", 1, true) then
        config.components = {
            { id = "spike_fr", type = "spike", name = "Front Right Spike", group = "front", model = "models/props_junk/harpoon002a.mdl", pos = Vector( 38.00,  80.00, 0.00), ang = rightSpikeAng, scale = Vector(1.00, 1.00, 1.00) },
            { id = "spike_fl", type = "spike", name = "Front Left Spike",  group = "front", model = "models/props_junk/harpoon002a.mdl", pos = Vector(-38.00,  80.00, 0.00), ang = leftSpikeAng,  scale = Vector(1.00, 1.00, 1.00) },
            { id = "spike_mr", type = "spike", name = "Mid Right Spike",    group = "mid",   model = "models/props_junk/harpoon002a.mdl", pos = Vector( 40.00,   0.00, 0.00), ang = rightSpikeAng, scale = Vector(1.00, 1.00, 1.00) },
            { id = "spike_ml", type = "spike", name = "Mid Left Spike",     group = "mid",   model = "models/props_junk/harpoon002a.mdl", pos = Vector(-40.00,   0.00, 0.00), ang = leftSpikeAng,  scale = Vector(1.00, 1.00, 1.00) },
            { id = "spike_rr", type = "spike", name = "Rear Right Spike",   group = "rear",  model = "models/props_junk/harpoon002a.mdl", pos = Vector( 38.00,-100.00, 0.00), ang = rightSpikeAng, scale = Vector(1.00, 1.00, 1.00) },
            { id = "spike_rl", type = "spike", name = "Rear Left Spike",    group = "rear",  model = "models/props_junk/harpoon002a.mdl", pos = Vector(-38.00,-100.00, 0.00), ang = leftSpikeAng,  scale = Vector(1.00, 1.00, 1.00) },

            -- Heavy Anchor Array: two extra mounts, only used once
            -- heavy_cluster_spikes is unlocked (the count is capped without it).
            { id = "spike_or", type = "spike", name = "Outer Right Spike", group = "mid", model = "models/props_junk/harpoon002a.mdl", pos = Vector(  25.00,   40.00,    0.00), ang = rightSpikeAng, scale = Vector(1.00, 1.00, 1.00) },  -- NOT user-verified
            { id = "spike_ol", type = "spike", name = "Outer Left Spike", group = "mid", model = "models/props_junk/harpoon002a.mdl", pos = Vector( -25.00,   40.00,    0.00), ang = leftSpikeAng, scale = Vector(1.00, 1.00, 1.00) },

            { id = "armor_sl", type = "armor_side",  name = "Left Metal Plate",  group = "side",  model = "models/props_phx/construct/metal_plate1x2.mdl", pos = Vector(-48.00, -20.00, 35.00), ang = Angle(-90.00, 90.00, 90.00), scale = Vector(1.00, 1.00, 1.00) },
            { id = "armor_sr", type = "armor_side",  name = "Right Metal Plate", group = "side",  model = "models/props_phx/construct/metal_plate1x2.mdl", pos = Vector( 48.00, -20.00, 35.00), ang = Angle(-90.00, 90.00, 90.00), scale = Vector(1.00, 1.00, 1.00) },
            { id = "armor_fa", type = "armor_front", name = "Front Metal Plate", group = "front", model = "models/props_phx/construct/metal_plate1x2.mdl", pos = Vector(  0.00, 105.00, 35.00), ang = Angle(-90.00, 90.00,  0.00), scale = Vector(1.00, 1.00, 1.00) },

            -- Roof cowl (roof_spoiler) and hydraulic rams (reinforced_hydraulics).
            -- These three branches are NOT user-verified. An earlier version derived
            -- them from offsets fitted to the buggy alone, and the jalopy export
            -- disproved every one of them, so they are back to plain guesses. The
            -- ram height is the exception: it is z = 30.0 on both verified vehicles
            -- even though their side armour sits at 31.8 and 40.8, so 30 is used
            -- here too.
            { id = "armor_roof", type = "armor_roof", name = "Roof Cowl", group = "roof", model = "models/props_phx/construct/metal_plate1.mdl", pos = Vector(   0.00,  -29.20,   82.20), ang = Angle(  0.00,   0.00, 168.50), scale = Vector(1.00, 1.00, 1.00) },  -- NOT user-verified
            { id = "hyd_rl", type = "hydraulic_ram", name = "Right Hydraulic Ram", group = "hydraulics", model = "models/props_c17/TrapPropeller_Lever.mdl", pos = Vector(  35.00,    0.00,   30.00), ang = Angle( 90.00,   0.00,   0.00), scale = Vector(1.00, 1.00, 1.00) },  -- NOT user-verified
            { id = "hyd_ll", type = "hydraulic_ram", name = "Left Hydraulic Ram",  group = "hydraulics", model = "models/props_c17/TrapPropeller_Lever.mdl", pos = Vector( -35.00,    0.00,   30.00), ang = Angle( 90.00,   0.00,   0.00), scale = Vector(1.00, 1.00, 1.00) },

            -- Tactical Path Prediction Screen
            { id = "screen_radar", type = "radar_screen", name = "Path Prediction Screen", group = "interior", model = "models/kobilica/wiremonitorsmall.mdl", pos = Vector( 15.00,  25.00, 38.00), ang = Angle(10.00, -125.00, 0.00), scale = Vector(1.00, 1.00, 1.00) },
        }
    else
        -- Standard Buggy (jeep) and universal default baseline
        config.components = {
            { id = "spike_fr", type = "spike", name = "Front Right Spike", group = "front", model = "models/props_junk/harpoon002a.mdl", pos = Vector( 25.00,  50.00, 0.00), ang = rightSpikeAng, scale = Vector(1.00, 1.00, 1.00) },
            { id = "spike_fl", type = "spike", name = "Front Left Spike",  group = "front", model = "models/props_junk/harpoon002a.mdl", pos = Vector(-25.00,  50.00, 0.00), ang = leftSpikeAng,  scale = Vector(1.00, 1.00, 1.00) },
            { id = "spike_mr", type = "spike", name = "Mid Right Spike",    group = "mid",   model = "models/props_junk/harpoon002a.mdl", pos = Vector( 30.00, -20.00, 0.00), ang = rightSpikeAng, scale = Vector(1.00, 1.00, 1.00) },
            { id = "spike_ml", type = "spike", name = "Mid Left Spike",     group = "mid",   model = "models/props_junk/harpoon002a.mdl", pos = Vector(-30.00, -20.00, 0.00), ang = leftSpikeAng,  scale = Vector(1.00, 1.00, 1.00) },
            { id = "spike_rr", type = "spike", name = "Rear Right Spike",   group = "rear",  model = "models/props_junk/harpoon002a.mdl", pos = Vector( 20.00,-100.00, 0.00), ang = rightSpikeAng, scale = Vector(1.00, 1.00, 1.00) },
            { id = "spike_rl", type = "spike", name = "Rear Left Spike",    group = "rear",  model = "models/props_junk/harpoon002a.mdl", pos = Vector(-20.00,-100.00, 0.00), ang = leftSpikeAng,  scale = Vector(1.00, 1.00, 1.00) },

            -- Heavy Anchor Array: two extra mounts, only used once
            -- heavy_cluster_spikes is unlocked (the count is capped without it).
            { id = "spike_or", type = "spike", name = "Outer Right Spike", group = "mid", model = "models/props_junk/harpoon002a.mdl", pos = Vector(  25.00,   20.00,    0.00), ang = rightSpikeAng, scale = Vector(1.00, 1.00, 1.00) },  -- user-verified in game
            { id = "spike_ol", type = "spike", name = "Outer Left Spike", group = "mid", model = "models/props_junk/harpoon002a.mdl", pos = Vector( -25.00,   20.00,    0.00), ang = leftSpikeAng, scale = Vector(1.00, 1.00, 1.00) },

            { id = "armor_sl", type = "armor_side",  name = "Left Metal Plate",  group = "side",  model = "models/props_phx/construct/metal_plate1x2.mdl", pos = Vector(-43.50, -24.50, 31.80), ang = Angle(-90.00, 90.00, 90.00), scale = Vector(1.00, 1.00, 1.00) },
            { id = "armor_sr", type = "armor_side",  name = "Right Metal Plate", group = "side",  model = "models/props_phx/construct/metal_plate1x2.mdl", pos = Vector( 43.50, -24.50, 31.80), ang = Angle(-90.00, 90.00, 90.00), scale = Vector(1.00, 1.00, 1.00) },
            { id = "armor_fa", type = "armor_front", name = "Front Metal Plate", group = "front", model = "models/props_phx/construct/metal_plate1x2.mdl", pos = Vector(  0.00,  64.00, 31.80), ang = Angle(-95.30, 90.00,  0.00), scale = Vector(1.00, 1.00, 1.00) },

            -- Roof cowl (roof_spoiler) and hydraulic rams (reinforced_hydraulics).
            -- These three branches are NOT user-verified. An earlier version derived
            -- them from offsets fitted to the buggy alone, and the jalopy export
            -- disproved every one of them, so they are back to plain guesses. The
            -- ram height is the exception: it is z = 30.0 on both verified vehicles
            -- even though their side armour sits at 31.8 and 40.8, so 30 is used
            -- here too.
            { id = "armor_roof", type = "armor_roof", name = "Roof Cowl", group = "roof", model = "models/props_phx/construct/metal_plate1.mdl", pos = Vector(   0.00,  -49.20,   79.00), ang = Angle(  0.00,   0.00, 168.50), scale = Vector(1.00, 1.00, 1.00) },  -- user-verified in game
            { id = "hyd_rl", type = "hydraulic_ram", name = "Right Hydraulic Ram", group = "hydraulics", model = "models/props_c17/TrapPropeller_Lever.mdl", pos = Vector(  35.90,  -24.60,   30.00), ang = Angle( 90.00,   0.00,   0.00), scale = Vector(1.00, 1.00, 1.00) },  -- user-verified in game
            { id = "hyd_ll", type = "hydraulic_ram", name = "Left Hydraulic Ram",  group = "hydraulics", model = "models/props_c17/TrapPropeller_Lever.mdl", pos = Vector( -35.90,  -24.60,   30.00), ang = Angle( 90.00,   0.00,   0.00), scale = Vector(1.00, 1.00, 1.00) },

            -- Tactical Path Prediction Screen
            { id = "screen_radar", type = "radar_screen", name = "Path Prediction Screen", group = "interior", model = "models/kobilica/wiremonitorsmall.mdl", pos = Vector( 19.20,  -9.20, 37.30), ang = Angle(-6.90, -125.00, 0.00), scale = Vector(1.00, 1.00, 1.00) },
        }
    end

    return config
end

-- ============================================================================
-- DETERMINISTIC CONFIGURATION SERIALIZER (AI & Human Friendly)
-- Generates clean, reproducible Lua table code.
-- ============================================================================
function TIV.CustomConfig.SerializeToLua(config)
    if not istable(config) then return "-- Error: Invalid configuration table" end

    local vehModel = config.vehicle_model or "models/buggy.mdl"
    local lines = {}

    table.insert(lines, "-- ============================================================================")
    table.insert(lines, "-- TIV INTERCEPTOR VEHICLE CONFIGURATION")
    table.insert(lines, "-- Generated: " .. os.date("%Y-%m-%d %H:%M:%S"))
    table.insert(lines, "-- Base Vehicle Model: " .. vehModel)
    table.insert(lines, "-- Coordinate Space: Vehicle Local")
    table.insert(lines, "--   Forward = +Y, Right = +X, Up = +Z")
    table.insert(lines, "-- ============================================================================")
    table.insert(lines, "return {")
    table.insert(lines, string.format('    vehicle_model = %q,', vehModel))
    table.insert(lines, "    components = {")

    for i, c in ipairs(config.components or {}) do
        local pos = c.pos or Vector(0, 0, 0)
        local ang = c.ang or Angle(0, 0, 0)
        local scl = c.scale or Vector(1, 1, 1)

        table.insert(lines, "        {")
        table.insert(lines, string.format('            id    = %q,', tostring(c.id or ("comp_" .. i))))
        table.insert(lines, string.format('            type  = %q,', tostring(c.type or "custom_prop")))
        table.insert(lines, string.format('            name  = %q,', tostring(c.name or ("Component " .. i))))
        table.insert(lines, string.format('            group = %q,', tostring(c.group or "misc")))
        table.insert(lines, string.format('            model = %q,', tostring(c.model or "models/props_junk/harpoon002a.mdl")))
        table.insert(lines, string.format('            pos   = Vector(%.2f, %.2f, %.2f),', pos.x, pos.y, pos.z))
        table.insert(lines, string.format('            ang   = Angle(%.2f, %.2f, %.2f),', ang.p, ang.y, ang.r))
        table.insert(lines, string.format('            scale = Vector(%.2f, %.2f, %.2f),', scl.x, scl.y, scl.z))
        table.insert(lines, "        },")
    end

    table.insert(lines, "    }")
    table.insert(lines, "}")

    return table.concat(lines, "\n")
end

-- ============================================================================
-- DETERMINISTIC CONFIGURATION DESERIALIZER
-- Safely parses Lua table format or JSON format.
-- ============================================================================
function TIV.CustomConfig.DeserializeFromLua(str)
    if not isstring(str) or string.Trim(str) == "" then
        return nil, "Empty configuration input"
    end

    -- First try JSON decoding if input starts with { or [
    local trimmed = string.Trim(str)
    if string.sub(trimmed, 1, 1) == "{" and string.find(trimmed, '"components"', 1, true) then
        local jsonResult = util.JSONToTable(trimmed)
        if istable(jsonResult) and istable(jsonResult.components) then
            -- Convert JSON arrays/tables into Vector and Angle types
            for _, c in ipairs(jsonResult.components) do
                if istable(c.pos) then c.pos = Vector(c.pos.x or 0, c.pos.y or 0, c.pos.z or 0) end
                if istable(c.ang) then c.ang = Angle(c.ang.p or c.ang.pitch or 0, c.ang.y or c.ang.yaw or 0, c.ang.r or c.ang.roll or 0) end
                if istable(c.scale) then c.scale = Vector(c.scale.x or 1, c.scale.y or 1, c.scale.z or 1) end
            end
            return jsonResult, nil
        end
    end

    -- Ensure input begins with return statement for CompileString
    local luaCode = trimmed
    if not string.find(luaCode, "^%s*return") then
        luaCode = "return " .. luaCode
    end

    -- Safe execution via CompileString with protected environment
    local chunk = CompileString(luaCode, "TIV_ConfigImport", false)
    if isstring(chunk) then
        -- Syntax error in compilation: fall back to robust regex token parser
        return TIV.CustomConfig.ParseTokensFallback(str)
    end

    -- Sandboxed environment
    local env = {
        Vector = Vector,
        Angle  = Angle,
        Color  = Color,
    }
    setfenv(chunk, env)

    local ok, res = pcall(chunk)
    if ok and istable(res) and istable(res.components) then
        -- Validate components
        for i, c in ipairs(res.components) do
            c.id    = tostring(c.id or ("comp_" .. i))
            c.type  = tostring(c.type or "custom_prop")
            c.name  = tostring(c.name or ("Component " .. i))
            c.group = tostring(c.group or "misc")
            c.model = tostring(c.model or "models/props_junk/harpoon002a.mdl")
            c.pos   = isvector(c.pos) and c.pos or Vector(0, 0, 0)
            c.ang   = isangle(c.ang) and c.ang or Angle(0, 0, 0)
            c.scale = isvector(c.scale) and c.scale or Vector(1, 1, 1)
        end
        return res, nil
    end

    return TIV.CustomConfig.ParseTokensFallback(str)
end

-- Fallback regex token parser for hand-typed or slightly malformed inputs
function TIV.CustomConfig.ParseTokensFallback(str)
    local components = {}
    local pattern = "type%s*=%s*[\"'](.-)[\"'].-model%s*=%s*[\"'](.-)[\"'].-pos%s*=%s*Vector%s*%((.-)%).-ang%s*=%s*Angle%s*%((.-)%)[%s,}]"

    for ctype, model, posStr, angStr in string.gmatch(str, pattern) do
        local px, py, pz = string.match(posStr, "([%-%d%.]+)%s*,%s*([%-%d%.]+)%s*,%s*([%-%d%.]+)")
        local ap, ay, ar = string.match(angStr, "([%-%d%.]+)%s*,%s*([%-%d%.]+)%s*,%s*([%-%d%.]+)")

        table.insert(components, {
            id    = "comp_" .. (#components + 1),
            type  = ctype,
            name  = string.upper(string.sub(ctype, 1, 1)) .. string.sub(ctype, 2),
            group = "imported",
            model = model,
            pos   = Vector(tonumber(px) or 0, tonumber(py) or 0, tonumber(pz) or 0),
            ang   = Angle(tonumber(ap) or 0, tonumber(ay) or 0, tonumber(ar) or 0),
            scale = Vector(1, 1, 1),
        })
    end

    local modelMatch = string.match(str, 'vehicle_model%s*=%s*["\'](.-)["\']')
    if #components > 0 then
        return {
            vehicle_model = modelMatch or "models/buggy.mdl",
            components    = components,
        }, nil
    end

    return nil, "Failed to parse vehicle configuration"
end

-- ============================================================================
-- VEHICLE STATS & PHYSICS EVALUATOR
-- Calculates cumulative physical parameters for a configuration and upgrades.
-- ============================================================================
-- ----------------------------------------------------------------------------
-- Resolve the component config for a vehicle, caching it the same way
-- sv_spike_anim.lua does, and count how many spike mounts it defines.
--
-- Both of the places that decide "how many spikes should this vehicle have" go
-- through here. They used to resolve it independently -- one from the config's
-- spike components, one from a convar -- which agreed only while every config
-- happened to define exactly six. With eight mounts in the defaults they would
-- disagree, and EnsureSpikes would rebuild the spikes every call.
-- ----------------------------------------------------------------------------
function TIV.CustomConfig.ResolveConfigFor(veh, hasAngled)
    if not IsValid(veh) then return nil end
    if not veh._TIVConfig and TIV.CustomConfig.GetSavedConfig then
        veh._TIVConfig = TIV.CustomConfig.GetSavedConfig(veh:GetModel())
    end
    return veh._TIVConfig
        or (TIV.CustomConfig.GetDefaultConfig and TIV.CustomConfig.GetDefaultConfig(veh:GetModel(), hasAngled))
end

function TIV.CustomConfig.CountSpikeComponents(veh, hasAngled)
    local config = TIV.CustomConfig.ResolveConfigFor(veh, hasAngled)
    local n = 0
    for _, c in ipairs(config and config.components or {}) do
        if c.type == "spike" then n = n + 1 end
    end
    return n
end

function TIV.CustomConfig.CalculateVehicleStats(config, unlockedUpgrades)
    unlockedUpgrades = unlockedUpgrades or {}
    local upgBonuses = TIV.Progression.CalculateBonuses(unlockedUpgrades)

    local stats = {
        total_spikes         = 0,
        angled_spikes_count  = 0,
        side_armor_count     = 0,
        front_armor_count    = 0,
        total_armor_count    = 0,
        effective_loft_mph   = (TIV.Config and TIV.Config.LoftWindThreshold or 180) + upgBonuses.loft_threshold,
        rock_torque_mult     = upgBonuses.rock_torque_mult,
        wind_force_mult      = upgBonuses.wind_force_mult,
        anchor_hold_mult     = upgBonuses.anchor_hold_mult,
        total_ballast_mass   = upgBonuses.added_mass,
        impact_reduction     = upgBonuses.impact_reduction,
        drive_depth_bonus    = upgBonuses.drive_depth_bonus,
        -- Carried through so the spike system can honour the Heavy Anchor Array.
        -- CalculateBonuses already worked this out; nothing used to read it.
        max_spikes           = upgBonuses.max_spikes,
        hydraulic_ram_count  = 0,
    }

    if not config or not config.components then
        return stats
    end

    for _, c in ipairs(config.components) do
        local ctype = c.type or ""
        if ctype == "spike" then
            stats.total_spikes = stats.total_spikes + 1
            if c.ang and (math.abs(c.ang.p - 90) > 2 or math.abs(c.ang.y) > 2 or math.abs(c.ang.r) > 2) then
                stats.angled_spikes_count = stats.angled_spikes_count + 1
            end
        elseif ctype == "armor_side" then
            stats.side_armor_count  = stats.side_armor_count + 1
            stats.total_armor_count = stats.total_armor_count + 1
            -- Side armor shields underbody and adds ballast
            stats.effective_loft_mph = stats.effective_loft_mph + 12
            stats.rock_torque_mult   = stats.rock_torque_mult * 0.90
            stats.total_ballast_mass = stats.total_ballast_mass + 120
            stats.impact_reduction   = math.Clamp(stats.impact_reduction + 0.08, 0, 0.70)
        elseif ctype == "armor_front" then
            stats.front_armor_count = stats.front_armor_count + 1
            stats.total_armor_count = stats.total_armor_count + 1
            -- Front cowl deflects wind over vehicle
            stats.effective_loft_mph = stats.effective_loft_mph + 15
            stats.wind_force_mult    = stats.wind_force_mult * 0.92
            stats.total_ballast_mass = stats.total_ballast_mass + 140
            stats.impact_reduction   = math.Clamp(stats.impact_reduction + 0.12, 0, 0.70)
        elseif ctype == "hydraulic_ram" then
            stats.hydraulic_ram_count = stats.hydraulic_ram_count + 1
            stats.total_armor_count   = stats.total_armor_count + 1
            -- Rams are the visible half of reinforced_hydraulics; the deeper drive
            -- comes from drive_depth_bonus, which sv_spike_anim already applies.
            if unlockedUpgrades["reinforced_hydraulics"] then
                stats.anchor_hold_mult     = stats.anchor_hold_mult * 1.05
                stats.total_ballast_mass   = stats.total_ballast_mass + 60
            end
        elseif ctype == "armor_roof" then
            stats.total_armor_count  = stats.total_armor_count + 1
            stats.effective_loft_mph = stats.effective_loft_mph + 10
            stats.wind_force_mult    = stats.wind_force_mult * 0.95
            stats.total_ballast_mass = stats.total_ballast_mass + 100
        end
    end

    -- Angled spikes bonus
    if stats.angled_spikes_count >= 2 and unlockedUpgrades["angled_spikes"] then
        stats.effective_loft_mph = stats.effective_loft_mph + 15
        stats.rock_torque_mult   = stats.rock_torque_mult * 0.85
        stats.anchor_hold_mult   = stats.anchor_hold_mult * 1.25
    end

    return stats
end

print("[TIV] Vehicle custom configuration module loaded")
