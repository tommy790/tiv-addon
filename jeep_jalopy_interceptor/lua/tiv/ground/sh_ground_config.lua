-- ============================================================================
-- TIV GROUND PIERCE -- TUNING
-- ============================================================================
-- Shared by sv_ground_pierce.lua and by anything that just wants to read the
-- numbers. This table is the ONLY place the pierce system's forces, depths and
-- stiffnesses live; the mechanics read it through TIV.GroundSetting().
--
-- The model these numbers describe:
--
--   * A pierced prop is a LIVE physics body. It is never frozen, never welded
--     to the world, and never repositioned again after the initial drive.
--   * The ground holds it with a set of soft "grip" springs attached along the
--     BURIED LENGTH of the prop, not at one point. That spread is what gives
--     the grip a lever arm: a spring attached at the same point a hold pins
--     has no lever arm about it and can never resist rotation.
--   * Each grip can let go on its own, shallowest first, the way soil actually
--     fails. A prop pulled hard comes out progressively; nothing snaps.
-- ============================================================================

TIV = TIV or {}
TIV.Config = TIV.Config or {}

TIV.Config.Ground = {
    -- Master switch. 0 leaves the module loaded but inert: Pierce() refuses
    -- and any existing grips are released.
    Enabled = 1,

    -- Let the TIV interceptor's own spikes take their soil grip from this
    -- system instead of the copy that used to live inside sv_anchor.lua. The
    -- spikes keep every existing behaviour -- TIV.Anchor still owns their load
    -- measurement and tear-out -- they simply get their grip geometry from
    -- here, so both paths can never drift apart again.
    UseForSpikes = 1,

    -- ========================================================================
    -- GRIP GEOMETRY
    -- ========================================================================
    -- How many grip springs hold one pierced prop. Two is the minimum that
    -- can resist rotation at all, because rotation needs two forces at
    -- different radii from the pivot. More grips spread the load and fail more
    -- gradually, at the cost of one constraint each.
    Grips = 3,

    -- Distance between successive grips, measured along the shaft.
    GripSpacing = 7,

    -- How far below the SURFACE the shallowest grip sits. Keeps the top grip
    -- in real soil rather than in the air just above the hole.
    FirstGripDepth = 4,

    -- Each grip's world anchor sits this far to one side of the shaft, with
    -- successive grips alternating sides. This is the spring's rest length, so
    -- it is also the small amount of slack before the ground pushes back, and
    -- the sideways bite that stops a prop sliding out of its hole.
    LateralOffset = 7,

    -- ========================================================================
    -- DRIVE
    -- ========================================================================
    -- How far past the surface the prop's own origin is driven. The prop is
    -- moved exactly once, here, at pierce time -- the equivalent of hammering
    -- a stake in. After this the system never repositions it again.
    DriveDepth = 15,

    -- How far to look for the surface along the drive axis.
    TraceDistance = 350,

    -- Used when the trace hits nothing (a prop pierced in mid-air, or over a
    -- gap): the grips are placed this far along the axis anyway, so the call
    -- still does something sane instead of silently failing.
    MissFallbackDepth = 60,

    -- ========================================================================
    -- SOIL STIFFNESS
    -- ========================================================================
    -- Spring constant of each grip, in N per unit of stretch.
    Constant = 6000,

    -- Damping of each grip, in N per unit/s. Around critical for a ~40 kg prop
    -- at the default constant; far below it and the prop rings on its grips.
    Damping = 1500,

    -- ========================================================================
    -- FAILURE
    -- ========================================================================
    -- Pull (along the axis) and slip (across it) that a fully gripped prop has
    -- to reach before the last, deepest grip lets go.
    PullOutDistance = 11,
    SlipOutDistance = 15,

    -- Load fraction at which the SHALLOWEST grip starts letting go. Grips
    -- between this and 1.0 fail in order from the top down, so a heavily
    -- loaded prop loses its grip progressively instead of all at once.
    GripFailureStart = 0.6,

    -- A prop cannot be declared torn out until it has been in the ground this
    -- long. A prop that has just been driven in is still absorbing the impact
    -- and would otherwise read as an instant failure.
    SettleTime = 0.75,

    -- Multiplier on the pull-out and slip-out distances while nothing is
    -- stressing the prop. A calm prop does not lose its grips just because the
    -- solver nudged it a couple of units.
    CalmSlack = 2.5,

    -- Load at which the strain is reported (sound + debug), before anything
    -- actually lets go.
    OverloadFraction = 0.7,

    -- ========================================================================
    -- COLLISION
    -- ========================================================================
    -- A prop embedded in terrain intersects the world brush, and the solver
    -- will shove it straight back out unless it is told not to collide. With
    -- this on, the module refuses world collisions for props IT has pierced
    -- and nothing else; it never touches any other entity pair.
    NoWorldCollide = 1,

    -- ========================================================================
    -- BUDGET
    -- ========================================================================
    -- Source caps a single physics system at 100 constraints. A pierced prop
    -- spends Grips of them, so refuse to start rather than silently breaking
    -- every other constraint on the entity.
    MaxConstraintsPerEntity = 64,

    -- ========================================================================
    -- DEBUG
    -- ========================================================================
    -- 1 prints grip creation, grip loss and tear-out. Off by default: this is
    -- far too chatty for normal play.
    Debug = 0,
}

-- ============================================================================
-- ACCESSOR
-- Reading through this means a missing field can never turn into `nil`
-- arithmetic deep inside a physics tick.
-- ============================================================================
local GroundDefaults = TIV.Config.Ground

function TIV.GroundSetting(key, fallback)
    local v = TIV.Config.Ground and TIV.Config.Ground[key]
    if v == nil then v = GroundDefaults[key] end
    if v == nil then v = fallback end
    return v
end

-- Convar-aware numeric setting. Falls back to the config table when the convar
-- does not exist, so the module works standalone in another addon.
function TIV.GroundSettingCvar(key, fallback)
    local cv = GetConVar and GetConVar("tiv_ground_" .. key:lower())
    if cv then
        local n = tonumber(cv:GetString())
        if n ~= nil then return n end
    end
    return tonumber(TIV.GroundSetting(key, fallback)) or fallback
end
