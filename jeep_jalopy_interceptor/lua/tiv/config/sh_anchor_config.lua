-- ============================================================================
-- TIV ANCHOR / LOFT TUNING
-- ============================================================================
-- Every number that decides how the interceptor fights the ground lives here.
-- Nothing in sv_anchor / sv_wire_anchor / sv_loft hardcodes a force, a
-- distance or a stiffness any more: they all read this table, so the whole
-- feel of the anchoring can be tuned from one place (and from the matching
-- convars in sv_runtime_cvars.lua) without touching the mechanics.
--
-- The model these numbers describe:
--
--   * a planted spike is a LIVE physics body, never a frozen one. It stays
--     attached to the chassis through one gimbaled hold per spike.
--   * the ground holds each spike with two soft "soil" elastics of its own, so
--     every spike is an independent anchor that can stretch, slip and let go
--     on its own -- there is no single invisible constraint holding the whole
--     vehicle flat.
--   * when the storm gets past the loft threshold the holds are NOT deleted.
--     They are re-cut at StressedForceLimit, i.e. they keep resisting but now
--     have a number they can lose at. Physics decides which one goes first.
-- ============================================================================

TIV = TIV or {}
TIV.Config = TIV.Config or {}

TIV.Config.Anchor = {
    -- ========================================================================
    -- HOLD FORCE
    -- ========================================================================
    -- Force limit the spike holds are cut at while the vehicle is simply
    -- parked on its anchors. 0 means "unbreakable by force": the hold cannot
    -- be torn out by the storm, only released by the retract sequence. This is
    -- what keeps a deployed interceptor from being dragged around by wind that
    -- is nowhere near strong enough to loft it.
    HoldForceLimit = 0,

    -- The number the brief asks for. When the loft system enters its "failing"
    -- state the holds stay in place but are re-cut at this limit, so they keep
    -- resisting the tornado while being physically able to lose to it. Raise
    -- it and the interceptor holds on longer; lower it and it lets go sooner.
    StressedForceLimit = 50000,

    -- Torque limit paired with StressedForceLimit for the gimbaled holds. A
    -- ballsocket has two independent break numbers; leaving torque at 0 would
    -- let a spike spin out freely the instant the storm applies rotation.
    StressedTorqueLimit = 50000,

    -- How far a gimbaled hold may swing, in degrees. The spike is a piston in
    -- a gimbal, not a weld: it must be able to lean as the chassis tilts, but
    -- a wide cone reads as a spike flapping on the end of a stick.
    SpikePivotLimit = 10,

    -- Rotational friction in the gimbal, per axis. Without this the spike is a
    -- free pendulum inside its cone and oscillates for a long time after
    -- anything disturbs it -- this is what makes a planted spike hold still.
    SpikePivotFriction = 40,

    -- Mass given to a planted spike. Heavier spikes are less twitchy under the
    -- solver and take a real pull to move, which is what an anchor driven into
    -- the ground should feel like.
    SpikeMass = 40,

    -- Keep the airbag springs inflated for the whole anchored state instead of
    -- dropping the ones a planted spike now covers. The airbags are what hold
    -- the chassis down on its suspension; the spikes resist being dragged off.
    -- Turning this off returns to the old behaviour of removing the covered
    -- springs once the spikes are in.
    KeepAirbagsWhileAnchored = true,

    -- ========================================================================
    -- GROUND EMBED (per-spike soil grip)
    -- ========================================================================
    -- Soil stiffness, in N per unit the spike has been dragged out of its hole.
    -- Paired with PullOutDistance below this puts a spike's grip at roughly
    -- 6000 * 11 = 66 kN -- deliberately a little above StressedForceLimit, so
    -- the hold and the soil give up at about the same load instead of one of
    -- them being decorative.
    EmbedConstant = 6000,

    -- Soil damping, in N per unit/s. At the default stiffness and a ~800 kg
    -- chassis on six spikes, critical damping is about 1800 per spike; this
    -- sits just under it so the vehicle settles onto its anchors in one pass
    -- instead of ringing at roughly 1 Hz for several seconds. Lower it and the
    -- whole vehicle bobs on its spikes.
    EmbedDamping = 1500,

    -- How far below the spike's own origin the soil anchor points sit. Also the
    -- rest length of the two springs, so this is how much slack the spike has
    -- before the ground starts pushing back.
    SoilAnchorDepth = 5,

    -- A spike that is pulled this far out of its hole has lost the ground and
    -- its soil elastics let go. Everything below that is "still holding, and
    -- you can feel it".
    PullOutDistance = 11,

    -- A spike pushed this far sideways out of its hole has also lost it.
    SlipOutDistance = 15,

    -- Load fraction (0..1) at which a spike starts to complain: strain sounds,
    -- and the audit prints it as overloaded.
    OverloadFraction = 0.7,

    -- Lateral offset of the second soil elastic, so a pair of springs per
    -- spike resists sideways drag as well as lift.
    LateralEmbedOffset = 9,

    -- A spike cannot be declared torn out until it has been in the ground this
    -- long, so the impact of driving it in is never read as a failure.
    SettleTime = 0.75,

    -- While nothing is stressing the anchors the pull-out and slip distances
    -- are multiplied by this. A parked vehicle must not lose its spikes because
    -- the solver nudged one a couple of units.
    CalmSlack = 2.5,

    -- ========================================================================
    -- WIRE GRABBER ANCHORS
    -- ========================================================================
    -- 1 = use Wire Grabbers for the spike holds when Wiremod is installed,
    -- 0 = always use the ballsocket holds. Auto-detected either way: without
    -- Wiremod the addon falls back to ballsockets and never errors.
    UseGrabbers = 1,

    -- Where the grabber sits between the chassis floor and the spike, in
    -- units below the vehicle's own hull. It has to be outside the vehicle's
    -- collision bounds or the grab trace hits the chassis instead of the spike.
    GrabberHullClearance = 5,

    -- Grabber trace length. Generous on purpose: the trace only has to reach
    -- the spike it is aimed at.
    GrabberRange = 160,

    -- Mass given to the grabber bodies. They are welded to the chassis, so
    -- this is cosmetic, but a heavier grabber reads better in the physics hud.
    GrabberMass = 120,

    -- ========================================================================
    -- LOFT SEQUENCE
    -- ========================================================================
    -- Once the vehicle's chassis has risen this far above where it planted,
    -- the anchors are considered gone and the loft completes. This is a
    -- failsafe for a storm mod teleporting the body; the normal path is the
    -- anchors losing on their own. 0 disables the check entirely.
    MaxLiftBeforeLoft = 130,

    -- Vertical rise (not total drift) that is reported as a full loft even if
    -- an anchor somehow survives, e.g. the vehicle hanging from one spike
    -- while a storm mod carries it bodily away.
    MaxRiseBeforeLoft = 90,

    -- How long after a loft the vehicle resets itself to idle.
    ResetDelay = 15,
}

-- ============================================================================
-- ACCESSORS
-- Reading through these means a missing field can never turn into `nil`
-- arithmetic deep inside a physics tick.
-- ============================================================================
local AnchorDefaults = TIV.Config.Anchor

function TIV.AnchorSetting(key, fallback)
    local v = TIV.Config.Anchor and TIV.Config.Anchor[key]
    if v == nil then v = AnchorDefaults[key] end
    if v == nil then v = fallback end
    return v
end

-- The hold force currently in force for a given stress state.
function TIV.AnchorHoldForce(stressed)
    if stressed then
        return math.max(0, tonumber(TIV.AnchorSetting("StressedForceLimit", 50000)) or 0)
    end
    return math.max(0, tonumber(TIV.AnchorSetting("HoldForceLimit", 0)) or 0)
end

function TIV.AnchorHoldTorque(stressed)
    if stressed then
        return math.max(0, tonumber(TIV.AnchorSetting("StressedTorqueLimit", 50000)) or 0)
    end
    return 0
end
