-- ============================================================================
-- TIV PROGRESSION & UPGRADE SYSTEM - Shared
-- Data-driven upgrade progression definitions, costs, and physics bonuses.
-- Upgrades remain permanently unlocked once purchased with earned Points.
-- ============================================================================

TIV = TIV or {}
TIV.Progression = TIV.Progression or {}

-- ============================================================================
-- UPGRADE DEFINITIONS
-- Extensible registry of all unlockable interceptor upgrades.
-- ============================================================================
TIV.Progression.Upgrades = {
    {
        id       = "angled_spikes",
        name     = "Angled Spikes",
        category = "Spikes",
        cost     = 2,
        desc     = "Allows ground anchor spikes to be mounted and driven at custom outward or pitched angles in the 3D editor. Angled penetration distributes lateral shear loads, drastically increasing anchor hold against intense tornado crosswinds.",
        bonuses  = {
            loft_threshold   = 25,    -- +25 MPH to loft threshold
            rock_torque_mult = 0.80,  -- 20% reduction in lateral rocking torque
            anchor_hold_mult = 1.30,  -- 30% higher anchor holding capacity
        },
    },
    {
        id       = "side_armor",
        name     = "Side Armor Panels",
        category = "Armor",
        cost     = 3,
        desc     = "Enables mounting custom side blast plates and skirts along the vehicle flanks. Shields underbody airflow from violent suction vortices and adds low-center ballast mass.",
        bonuses  = {
            loft_threshold   = 25,    -- +25 MPH to loft threshold
            rock_torque_mult = 0.75,  -- 25% reduction in rocking torque
            added_mass       = 250,   -- +250 kg chassis ballast
            impact_reduction = 0.20,  -- 20% damage reduction from debris collisions
        },
    },
    {
        id       = "front_armor",
        name     = "Front Armor Panels",
        category = "Armor",
        cost     = 3,
        desc     = "Enables mounting heavy front wedge plates and deflector cowls. Directs oncoming storm inflow over the vehicle roof instead of under the front axle, generating downward aerodynamic pressure.",
        bonuses  = {
            loft_threshold   = 25,    -- +25 MPH to loft threshold
            wind_force_mult  = 0.85,  -- 15% reduction in wind drag
            impact_reduction = 0.25,  -- 25% damage reduction to front collisions
            added_mass       = 200,   -- +200 kg front axle ballast
        },
    },
    {
        id       = "reinforced_hydraulics",
        name     = "Reinforced Hydraulic Rams",
        category = "Hydraulics",
        cost     = 4,
        desc     = "High-pressure dual-stage hydraulic cylinders that increase ground spike penetration depth and elevate anchor breaking force tolerance.",
        bonuses  = {
            loft_threshold    = 20,   -- +20 MPH to loft threshold
            drive_depth_bonus = 6,    -- +6 units ground penetration
            anchor_force_mult = 1.50, -- 50% higher anchor break limit
        },
    },
    {
        id       = "roof_spoiler",
        name     = "Aerodynamic Roof Cowl",
        category = "Aerodynamics",
        cost     = 5,
        desc     = "Streamlined roof deflector cowling designed to reduce aerodynamic turbulence in multi-vortex tornado cores and minimize chassis lift.",
        bonuses  = {
            loft_threshold   = 25,    -- +25 MPH to loft threshold
            wind_force_mult  = 0.80,  -- 20% reduction in wind drag
            added_mass       = 150,   -- +150 kg roof frame mass
        },
    },
    {
        id       = "heavy_cluster_spikes",
        name     = "Heavy Anchor Array",
        category = "Spikes",
        cost     = 6,
        desc     = "Reinforced chassis mounting framework allowing up to 8 independent hydraulic ground anchors for extreme EF5 tornado intercepts.",
        bonuses  = {
            loft_threshold   = 30,    -- +30 MPH to loft threshold
            max_spikes       = 8,     -- supports up to 8 spikes
            anchor_hold_mult = 1.40,  -- 40% higher anchor capacity
        },
    },
    {
        id       = "path_screen",
        name     = "Tactical Path Prediction Screen",
        category = "Electronics",
        cost     = 3,
        desc     = "Mounts an in-cabin tactical digital screen (using Wiremod screen display) that tracks the nearest active tornado and renders its real-time position, core radius, and predicted forward path directly in your vehicle.",
        bonuses  = {
            radar_screen = true,
        },
    },
}

-- Lookup index by ID
TIV.Progression.UpgradesByID = {}
for _, upg in ipairs(TIV.Progression.Upgrades) do
    TIV.Progression.UpgradesByID[upg.id] = upg
end

-- ============================================================================
-- GETTERS & HELPERS
-- ============================================================================
function TIV.Progression.GetUpgrade(id)
    return TIV.Progression.UpgradesByID[id]
end

function TIV.Progression.GetAllUpgrades()
    return TIV.Progression.Upgrades
end

-- Calculates cumulative physics and aerodynamic bonuses for a table of unlocked upgrade IDs
function TIV.Progression.CalculateBonuses(unlockedTable)
    unlockedTable = unlockedTable or {}

    local result = {
        loft_threshold   = 0,
        rock_torque_mult = 1.0,
        anchor_hold_mult = 1.0,
        wind_force_mult  = 1.0,
        added_mass       = 0,
        impact_reduction = 0.0,
        drive_depth_bonus= 0,
        max_spikes       = 6,
    }

    for id, unlocked in pairs(unlockedTable) do
        if unlocked then
            local def = TIV.Progression.GetUpgrade(id)
            if def and def.bonuses then
                local b = def.bonuses
                if b.loft_threshold then
                    result.loft_threshold = result.loft_threshold + b.loft_threshold
                end
                if b.rock_torque_mult then
                    result.rock_torque_mult = result.rock_torque_mult * b.rock_torque_mult
                end
                if b.anchor_hold_mult then
                    result.anchor_hold_mult = result.anchor_hold_mult * b.anchor_hold_mult
                end
                if b.wind_force_mult then
                    result.wind_force_mult = result.wind_force_mult * b.wind_force_mult
                end
                if b.added_mass then
                    result.added_mass = result.added_mass + b.added_mass
                end
                if b.impact_reduction then
                    result.impact_reduction = math.Clamp(result.impact_reduction + b.impact_reduction, 0, 0.70)
                end
                if b.drive_depth_bonus then
                    result.drive_depth_bonus = result.drive_depth_bonus + b.drive_depth_bonus
                end
                if b.max_spikes and b.max_spikes > result.max_spikes then
                    result.max_spikes = b.max_spikes
                end
            end
        end
    end

    return result
end

print("[TIV] Shared progression system loaded (" .. #TIV.Progression.Upgrades .. " upgrades registered)")
