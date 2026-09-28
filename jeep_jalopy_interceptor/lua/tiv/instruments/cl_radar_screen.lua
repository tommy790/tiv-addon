-- ============================================================================
-- TIV TACTICAL DOPPLER RADAR & PATH PREDICTION SCREEN - CLIENT
-- Renders real-time tornado tracking, vortex bounds, and forward path prediction
-- directly onto in-cabin Wiremod screens / dashboard monitor props.
-- ============================================================================

TIV = TIV or {}
TIV.Instruments = TIV.Instruments or {}

-- ============================================================================
-- PER-VEHICLE RADAR STATE
--
-- The server sends one TIV_RadarPathData per player, tagged with that player's
-- vehicle (sv_instruments.lua), because TIV.Wind.GetNearestActiveTornado is
-- resolved from each vehicle's own position. Every player in any TIV jeep
-- therefore receives a packet for every TIV jeep in the server.
--
-- This used to be a single global table, so the packet that arrived last won.
-- A screen then rendered its own vehicle's heading against another vehicle's
-- tornado position, which made REL BRG disagree with the blip -- and, when the
-- two jeeps faced different ways, read ASTERN for a vortex that was ahead.
--
-- Packets are now stored per vehicle and a screen reads only its own.
-- TIV.Instruments.RadarData is kept as the local player's vehicle entry so the
-- HUD and any external reader keep working.
-- ============================================================================
local radarByVehicle = {}
-- Per-vehicle fade for the Doppler velocity signature, so touchdown and lift-off
-- ease in and out instead of popping on a 0.35 s packet boundary. Declared up
-- here because PruneRadarData below clears it alongside the packets.
local signatureFade = {}
local EMPTY_RADAR = { active = false }

-- Heading basis correction, shared with the HUD and the Expression 2 functions
-- so all three can never disagree. TIV.HeadingOffsetDeg resolves the offline
-- probe override, then the tiv_radar_heading_offset convar, then the config.

--- Radar telemetry for one vehicle.
-- @param veh  Entity   the vehicle whose radar is being drawn
-- @param ply  Player   whose view this is (defaults to LocalPlayer). Passing the
--                      screen's owner rather than the local player is what lets a
--                      spectator or passenger see the correct vehicle's data.
function TIV.Instruments.GetRadarData(veh, ply)
    ply = ply or LocalPlayer()
    if IsValid(veh) then
        return radarByVehicle[veh] or EMPTY_RADAR
    end
    -- No owning vehicle recorded: resolve the viewer's own. Deliberately no
    -- fallback to the last packet received -- in multiplayer that packet can
    -- belong to another player's jeep, which is the bug this function exists to
    -- prevent. No vehicle means no data.
    if not IsValid(ply) then return EMPTY_RADAR end
    local own = (TIV.ResolveVehicle and TIV.ResolveVehicle(ply)) or ply:GetVehicle()
    if IsValid(own) then return radarByVehicle[own] or EMPTY_RADAR end
    return EMPTY_RADAR
end

-- Drop packets for vehicles that no longer exist. GMod nils out dead entities in
-- table values, but the key would linger, so prune on a slow timer instead of
-- every frame.
local nextRadarPrune = 0
local function PruneRadarData()
    for veh in pairs(radarByVehicle) do
        if not IsValid(veh) then radarByVehicle[veh] = nil end
    end
    -- The signature fade is keyed the same way; drop it with the radar entry so a
    -- removed vehicle cannot leave a fade behind.
    for veh in pairs(signatureFade) do
        if not IsValid(veh) then signatureFade[veh] = nil end
    end
end

-- ============================================================================
-- NETWORKING: RECEIVE TELEMETRY FROM SERVER
-- ============================================================================
net.Receive("TIV_RadarPathData", function()
    local veh = net.ReadEntity()
    local hasTornado = net.ReadBool()

    if not IsValid(veh) then return end

    if hasTornado then
        local pos         = net.ReadVector()
        local heading     = net.ReadVector()
        local speedMPH    = net.ReadFloat()
        local coreRadius  = net.ReadFloat()
        local outerRadius = net.ReadFloat()
        local dist        = net.ReadFloat()
        local bearing     = net.ReadFloat()
        local eta         = net.ReadFloat()
        local impactType  = net.ReadString()
        local wpCount     = net.ReadUInt(5)

        local waypoints = {}
        for i = 1, wpCount do
            local wpPos  = net.ReadVector()
            local wpTime = net.ReadUInt(8)
            table.insert(waypoints, { pos = wpPos, time = wpTime })
        end

        -- Read last because the server appends them last. Keeping the order
        -- identical on both sides is what stops every field above from shifting.
        local touchingGround = net.ReadBool()
        local rotationDir    = net.ReadInt(8)
        local rotationSpeed  = net.ReadFloat()

        local data = {
            active      = true,
            veh         = veh,
            pos         = pos,
            heading     = heading,
            speedMPH    = speedMPH,
            coreRadius  = coreRadius,
            outerRadius = outerRadius,
            dist        = dist,
            bearing     = bearing,
            eta         = eta,
            impactType  = impactType,
            waypoints   = waypoints,
            -- Ground contact, as measured by sv_wind's compatibility layer. The
            -- server collapses "could not be determined" to false before sending,
            -- so an unknown state never reaches the renderer as a signature.
            touchingGround    = touchingGround,
            rotationDirection = rotationDir,
            rotationSpeed     = rotationSpeed,
            receivedAt  = CurTime(),
        }
        radarByVehicle[veh] = data
        TIV.Instruments.RadarData = data
    else
        local data = {
            active     = false,
            veh        = veh,
            receivedAt = CurTime(),
        }
        radarByVehicle[veh] = data
        TIV.Instruments.RadarData = data
    end

    local now = CurTime()
    if now >= nextRadarPrune then
        nextRadarPrune = now + 5
        PruneRadarData()
    end
end)

-- ============================================================================
-- 3D2D SCREEN RENDERING ENGINE
-- ============================================================================

-- Boundary coordinates of the central radar display area inside the 512x512 canvas
local CLIP_MIN_X = 10
local CLIP_MAX_X = 502
local CLIP_MIN_Y = 42
local CLIP_MAX_Y = 454

-- Cohen-Sutherland 2D line clipping algorithm
local function ComputeOutCode(x, y, xmin, ymin, xmax, ymax)
    local code = 0
    if x < xmin then
        code = bit.bor(code, 1)
    elseif x > xmax then
        code = bit.bor(code, 2)
    end
    if y < ymin then
        code = bit.bor(code, 8)
    elseif y > ymax then
        code = bit.bor(code, 4)
    end
    return code
end

local function ClipLine(x0, y0, x1, y1, xmin, ymin, xmax, ymax)
    xmin = xmin or CLIP_MIN_X
    ymin = ymin or CLIP_MIN_Y
    xmax = xmax or CLIP_MAX_X
    ymax = ymax or CLIP_MAX_Y

    local outcode0 = ComputeOutCode(x0, y0, xmin, ymin, xmax, ymax)
    local outcode1 = ComputeOutCode(x1, y1, xmin, ymin, xmax, ymax)

    while true do
        if bit.bor(outcode0, outcode1) == 0 then
            return x0, y0, x1, y1
        end
        if bit.band(outcode0, outcode1) ~= 0 then
            return nil
        end

        local outcodeOut = (outcode0 ~= 0) and outcode0 or outcode1
        local x, y

        if bit.band(outcodeOut, 8) ~= 0 then -- Top
            x = x0 + (x1 - x0) * (ymin - y0) / (y1 - y0)
            y = ymin
        elseif bit.band(outcodeOut, 4) ~= 0 then -- Bottom
            x = x0 + (x1 - x0) * (ymax - y0) / (y1 - y0)
            y = ymax
        elseif bit.band(outcodeOut, 2) ~= 0 then -- Right
            y = y0 + (y1 - y0) * (xmax - x0) / (x1 - x0)
            x = xmax
        elseif bit.band(outcodeOut, 1) ~= 0 then -- Left
            y = y0 + (y1 - y0) * (xmin - x0) / (x1 - x0)
            x = xmin
        end

        if outcodeOut == outcode0 then
            x0, y0 = x, y
            outcode0 = ComputeOutCode(x0, y0, xmin, ymin, xmax, ymax)
        else
            x1, y1 = x, y
            outcode1 = ComputeOutCode(x1, y1, xmin, ymin, xmax, ymax)
        end
    end
end

local function DrawClippedLine(x0, y0, x1, y1, r, g, b, a)
    local c0x, c0y, c1x, c1y = ClipLine(x0, y0, x1, y1, CLIP_MIN_X, CLIP_MIN_Y, CLIP_MAX_X, CLIP_MAX_Y)
    if c0x then
        surface.SetDrawColor(r, g, b, a)
        surface.DrawLine(c0x, c0y, c1x, c1y)
    end
end

-- ============================================================================
-- DOPPLER VELOCITY SIGNATURE
--
-- A pair of opposing curved lobes marking the air moving toward the radar on one
-- flank of the vortex and away from it on the other -- the velocity couplet a
-- real Doppler shows on a tornado. It is drawn only while the server reports the
-- vortex is actually on the ground, and it is deliberately not a spinning disc:
-- nothing here rotates, so it cannot read as an animation of the vortex turning.
--
-- All tornado detection stays in sv_wind.lua's compatibility layer. This layer
-- only consumes the three values it is handed.
-- ============================================================================

-- Fade per vehicle, so touchdown and lift-off ease in and out instead of popping
-- on a 0.35 s packet boundary. The table itself lives up with radarByVehicle.
-- Eased in over roughly a third of a second. There is deliberately no matching
-- fade-out rate: when the server stops reporting ground contact the signature is
-- dropped immediately, because easing out a reading we no longer have would mean
-- drawing something the tornado system is not currently saying.
local SIGNATURE_FADE_IN = 3.5   -- per second
local SIGNATURE_ARC_SPAN = math.rad(120)
local SIGNATURE_ARC_STEP = math.rad(6)

-- One stroked curved band: two concentric arcs joined at both ends. Stroked
-- rather than filled so the windfield circles underneath stay readable.
local function DrawDopplerArcBand(cx, cy, rInner, rOuter, centerAngle, span, r, g, b, a)
    if a <= 1 or rInner <= 0 or rOuter <= rInner then return end

    local half = span * 0.5
    local segments = math.max(4, math.floor(span / SIGNATURE_ARC_STEP))

    for band = 0, 1 do
        local radius = (band == 0) and rInner or rOuter
        local px, py
        for i = 0, segments do
            local ang = centerAngle - half + (span * i / segments)
            local nx = cx + math.cos(ang) * radius
            local ny = cy + math.sin(ang) * radius
            if px then DrawClippedLine(px, py, nx, ny, r, g, b, a) end
            px, py = nx, ny
        end
    end

    -- Cap both ends so the band reads as a sector instead of two loose arcs.
    for _, off in ipairs({ -half, half }) do
        local ang = centerAngle + off
        local cosA, sinA = math.cos(ang), math.sin(ang)
        DrawClippedLine(
            cx + cosA * rInner, cy + sinA * rInner,
            cx + cosA * rOuter, cy + sinA * rOuter,
            r, g, b, a
        )
    end
end

-- Advances one vehicle's signature fade. Returns the fade to draw with, or nil
-- when the signature should not be drawn at all.
local function SignatureFadeFor(veh, rData, dt)
    if not IsValid(veh) then return nil end

    -- No tornado, or a packet too old to trust: the signature is gone rather
    -- than eased out, because fading a reading we no longer have would be
    -- drawing something the server is not currently reporting.
    if not rData or not rData.active or not rData.pos or rData.touchingGround ~= true then
        signatureFade[veh] = nil
        return nil
    end

    local st = signatureFade[veh]
    if not st then
        st = { cur = 0 }
        signatureFade[veh] = st
    end

    st.cur = math.Clamp(st.cur + SIGNATURE_FADE_IN * dt, 0, 1)
    return st.cur
end

-- Draws the couplet centred on the vortex's radar position. `ux, uy` is the
-- canvas unit vector from the radar (canvas centre) toward the vortex.
local SIGNATURE_MIN_THICKNESS = 6 -- px; below this a couplet stops reading as one

local function DrawDopplerSignature(scrX, scrY, cx, cy, ux, uy, corePx, outerPx, rotSign, rotMPH, fade, now)
    -- The signature has to live in the annulus between the two circles the radar
    -- already draws, without crossing either stroke. Both radii are taken from
    -- what was actually drawn, and the band is then sized to fit what is left --
    -- which matters because the core circle has an 8 px floor while the outer
    -- windfield does not, so a distant vortex leaves barely any gap and a close
    -- one leaves a lot. Deriving the band from the real radii is the only way it
    -- cannot end up painted over the core.
    local lo = corePx + 2
    local hi = outerPx - 2
    if hi - lo < SIGNATURE_MIN_THICKNESS then return end

    -- Scale with the detected circulation where there is room for it.
    local want = math.Clamp(corePx * 1.5, 8, 46)
    local bandInner = math.Clamp(want, lo, hi - SIGNATURE_MIN_THICKNESS)
    local bandOuter = math.Clamp(want * 1.45, bandInner + SIGNATURE_MIN_THICKNESS, hi)
    if bandOuter - bandInner < 2 then return end

    -- Which flank is inbound is set by the circulation and the radar geometry
    -- together, never by the screen's orientation. For a counter-clockwise vortex
    -- (rotSign +1, the Northern-hemisphere default) the tangential wind at the
    -- point nearest the radar runs along +n x +z, which in the game's
    -- left-handed basis is (n.y, -n.x) -- toward the radar. Reversing the
    -- circulation reverses that, which is exactly what the sign does here.
    local lobeDir = (rotSign < 0) and -1 or 1
    local inX, inY = -uy * lobeDir, ux * lobeDir

    local inboundR, inboundG, inboundB
    local outboundR, outboundG, outboundB

    if rotSign == 0 then
        -- Direction genuinely unavailable: both lobes share one neutral colour,
        -- so the signature shows that air is circulating without claiming which
        -- way round.
        inboundR, inboundG, inboundB = 150, 200, 225
        outboundR, outboundG, outboundB = 150, 200, 225
    else
        inboundR, inboundG, inboundB = 90, 235, 255    -- toward the radar
        outboundR, outboundG, outboundB = 255, 120, 45 -- away from it
    end

    -- Pulse paced by the measured circulation rather than by a fixed rate, so a
    -- faster vortex reads as more energetic. Falls back to the translation speed
    -- when the addon publishes no wind value.
    local paceMPH = (rotMPH and rotMPH > 0) and rotMPH or 0
    local pulse = 0.72 + 0.28 * math.sin(now * (2.0 + math.Clamp(paceMPH, 0, 320) / 110))
    local baseA = math.floor(170 * fade * pulse)

    local inboundAngle = math.atan2(inY, inX)
    DrawDopplerArcBand(scrX, scrY, bandInner, bandOuter, inboundAngle, SIGNATURE_ARC_SPAN,
        inboundR, inboundG, inboundB, baseA)
    DrawDopplerArcBand(scrX, scrY, bandInner, bandOuter, inboundAngle + math.pi, SIGNATURE_ARC_SPAN,
        outboundR, outboundG, outboundB, baseA)
end

local function DrawRadarScreen(screenEnt, veh, rData)
    local cx, cy = 256, 260
    local radarRadius = 180
    local now = CurTime()

    -- CRT Glass background
    surface.SetDrawColor(6, 12, 18, 255)
    surface.DrawRect(0, 0, 512, 512)

    -- Subtle CRT scanlines
    surface.SetDrawColor(0, 25, 20, 35)
    for y = 0, 512, 4 do
        surface.DrawLine(0, y, 512, y)
    end

    -- Tactical frame borders
    surface.SetDrawColor(0, 200, 255, 180)
    surface.DrawOutlinedRect(6, 6, 500, 500)
    surface.DrawOutlinedRect(8, 8, 496, 496)

    -- Header bar
    surface.SetDrawColor(0, 45, 60, 220)
    surface.DrawRect(10, 10, 492, 28)

    draw.SimpleText("TIV TACTICAL DOPPLER RADAR", "Trebuchet18", 18, 15, Color(0, 240, 255, 255), TEXT_ALIGN_LEFT)
    draw.SimpleText("GSTORMS // XT2 // XT3 VECTOR MAP", "Trebuchet18", 494, 15, Color(160, 200, 220, 220), TEXT_ALIGN_RIGHT)

    -- Concentric Range Rings (Track-Up view)
    local rings = {
        { r = 60,  lbl = "500m" },
        { r = 120, lbl = "1km" },
        { r = 180, lbl = "2km" },
    }

    surface.SetDrawColor(0, 140, 110, 80)
    for _, ring in ipairs(rings) do
        local r = ring.r
        local segments = 36
        for i = 0, segments - 1 do
            local a1 = math.rad((i / segments) * 360)
            local a2 = math.rad(((i + 1) / segments) * 360)
            surface.DrawLine(
                cx + math.cos(a1) * r, cy + math.sin(a1) * r,
                cx + math.cos(a2) * r, cy + math.sin(a2) * r
            )
        end
        draw.SimpleText(ring.lbl, "DefaultFixed", cx + r - 12, cy + 2, Color(0, 180, 130, 140), TEXT_ALIGN_LEFT)
    end

    -- Crosshair axis lines
    surface.SetDrawColor(0, 180, 130, 50)
    surface.DrawLine(cx - radarRadius, cy, cx + radarRadius, cy)
    surface.DrawLine(cx, cy - radarRadius, cx, cy + radarRadius)

    -- Rotating radar sweep phosphor beam
    local sweepAng = (now * 120) % 360
    local sRad = math.rad(sweepAng)
    surface.SetDrawColor(0, 255, 170, 200)
    surface.DrawLine(cx, cy, cx + math.cos(sRad) * radarRadius, cy + math.sin(sRad) * radarRadius)

    -- Vehicle marker at center: Tactical Chevron (Facing UP = Forward)
    local vehColor = Color(50, 255, 120, 255)
    surface.SetDrawColor(vehColor.r, vehColor.g, vehColor.b, vehColor.a)
    surface.DrawLine(cx, cy - 10, cx - 7, cy + 8)
    surface.DrawLine(cx, cy - 10, cx + 7, cy + 8)
    surface.DrawLine(cx - 7, cy + 8, cx, cy + 4)
    surface.DrawLine(cx + 7, cy + 8, cx, cy + 4)

    -- Storm rendering if active
    if rData and rData.active and rData.pos then
        local tPos   = rData.pos
        local vehPos = IsValid(veh) and veh:GetPos() or (IsValid(LocalPlayer()) and LocalPlayer():GetPos() or EyePos())
        local fwdVec = IsValid(veh) and veh:GetForward() or (IsValid(LocalPlayer()) and LocalPlayer():GetForward() or Vector(1, 0, 0))
        local rgtVec = IsValid(veh) and veh:GetRight() or (IsValid(LocalPlayer()) and LocalPlayer():GetRight() or Vector(0, -1, 0))

        -- 2D planar projection along vehicle heading
        local fwd2D = Vector(fwdVec.x, fwdVec.y, 0):GetNormalized()
        local rgt2D = Vector(rgtVec.x, rgtVec.y, 0):GetNormalized()

        local rel = tPos - vehPos
        local relFwd = rel:Dot(fwd2D)
        local relRgt = rel:Dot(rgt2D)

        -- ----------------------------------------------------------------
        -- HEADING BASIS CORRECTION
        --
        -- sh_custom_config.lua documents this addon's vehicle-local space as
        -- "Forward: +Y (along veh:GetForward())". In GMod that is not possible:
        -- Angle:Forward() is local +X and Angle:Right() is local -Y, so the two
        -- halves of that line disagree by 90 degrees. Everything the radar draws
        -- takes its reference frame from veh:GetForward()/GetRight() below, so with
        -- the nose on the config's +Y the whole display read 90 degrees out -- a
        -- vortex dead ahead reported as 090 RIGHT.
        --
        -- This rotates the vehicle-relative components so that relFwd measures
        -- along the nose. The bearing text, the blip and the movement arrow all
        -- consume the corrected pair, so they cannot drift apart.
        -- ----------------------------------------------------------------
        local headingOff = TIV.HeadingOffsetDeg()
        if headingOff ~= 0 then
            local hr = math.rad(headingOff)
            local c, s = math.cos(hr), math.sin(hr)
            -- With +90 this is (newFwd, newRgt) = (-relRgt, relFwd), i.e. relFwd now
            -- measures along local +Y and relRgt along local +X.
            relFwd, relRgt = c * relFwd - s * relRgt, s * relFwd + c * relRgt
        end

        -- Auto-scaling radar range
        local maxRangeUnits = math.max((rData.dist or 0) * 1.35, 3000)
        local scalePx = radarRadius / maxRangeUnits

        -- Place the blip by its track-up bearing and radius rather than by the raw
        -- components. The heading correction and the canvas orientation are two
        -- unrelated 90-degree questions -- one is about which way the vehicle's
        -- nose points, the other about which way cam.Start3D2D maps canvas +x --
        -- and folding them together is why the display kept being fixed on one
        -- axis and broken on the other. Bearing first, then one canvas rotation.
        local blipDist = math.sqrt(relFwd * relFwd + relRgt * relRgt)
        local blipRadius = blipDist * scalePx

        -- Unit vector toward the vortex on a track-up disc: canvas +x is the
        -- vehicle's right and canvas +y grows downward, so forward is -y. This is
        -- the identity mapping -- the blip's horizontal axis was never wrong. The
        -- "tornado is right but the blip is on the left" report was about the REL
        -- BRG readout, which is a heading-basis problem, not a canvas one, and is
        -- handled by TIV.HeadingOffsetDeg. BlipOffsetDeg below only exists so the
        -- canvas orientation can still be corrected in game if it ever disagrees.
        --
        -- Rotating the unit vector directly rather than going through atan2 and
        -- back keeps this exact at 0 and avoids relying on sin(pi) being zero.
        local ux, uy = 0, -1
        if blipDist > 0.0001 then
            ux, uy = relRgt / blipDist, -relFwd / blipDist
        end
        local bOff = math.rad(TIV.BlipOffsetDeg())
        if bOff ~= 0 then
            local bc, bs = math.cos(bOff), math.sin(bOff)
            ux, uy = bc * ux - bs * uy, bs * ux + bc * uy
        end
        local scrX = cx + ux * blipRadius
        local scrY = cy + uy * blipRadius

        -- Outer Vortex Windfield Circle (clipped per segment)
        local outerPx = math.Clamp((rData.outerRadius or 3500) * scalePx, 15, radarRadius * 1.5)
        local segs = 32
        for i = 0, segs - 1 do
            local a1 = math.rad((i / segs) * 360)
            local a2 = math.rad(((i + 1) / segs) * 360)
            local p1x = scrX + math.cos(a1) * outerPx
            local p1y = scrY + math.sin(a1) * outerPx
            local p2x = scrX + math.cos(a2) * outerPx
            local p2y = scrY + math.sin(a2) * outerPx
            DrawClippedLine(p1x, p1y, p2x, p2y, 255, 190, 0, 75)
        end

        -- Inner Core / Maximum Wind Zone (clipped per segment)
        local corePx = math.max((rData.coreRadius or 600) * scalePx, 8)
        local corePulse = math.sin(now * 10) * 0.2 + 0.8
        for i = 0, segs - 1 do
            local a1 = math.rad((i / segs) * 360)
            local a2 = math.rad(((i + 1) / segs) * 360)
            local p1x = scrX + math.cos(a1) * corePx
            local p1y = scrY + math.sin(a1) * corePx
            local p2x = scrX + math.cos(a2) * corePx
            local p2y = scrY + math.sin(a2) * corePx
            DrawClippedLine(p1x, p1y, p2x, p2y, 255, 45, 45, 120 * corePulse)
        end

        -- ----------------------------------------------------------------
        -- DOPPLER VELOCITY SIGNATURE (additional layer)
        --
        -- Inserted between the two windfield circles and the centre icon, so it
        -- reads as an overlay on the vortex without painting over the core, the
        -- outer windfield, the centre marker, the sweep or the vehicle chevron.
        -- Only drawn while the server reports real ground contact.
        -- ----------------------------------------------------------------
        local sigFade = SignatureFadeFor(veh, rData, FrameTime())
        if sigFade then
            local sigUX, sigUY = ux, uy
            local sigDist = math.sqrt((scrX - cx) * (scrX - cx) + (scrY - cy) * (scrY - cy))
            if sigDist > 0.5 then
                -- Re-derive the radar-to-vortex direction on the canvas rather than
                -- reusing the blip unit vector: the blip can carry BlipOffsetDeg,
                -- and a canvas correction must not swing the velocity lobes.
                sigUX, sigUY = (scrX - cx) / sigDist, (scrY - cy) / sigDist
            end

            DrawDopplerSignature(
                scrX, scrY, cx, cy, sigUX, sigUY,
                corePx, outerPx,
                rData.rotationDirection or 0,
                (rData.rotationSpeed and rData.rotationSpeed > 0) and rData.rotationSpeed or (rData.speedMPH or 0),
                sigFade, now
            )
        end

        -- Vortex Center Icon (on-screen icon or clamped off-screen edge pip)
        if scrX >= CLIP_MIN_X and scrX <= CLIP_MAX_X and scrY >= CLIP_MIN_Y and scrY <= CLIP_MAX_Y then
            surface.SetDrawColor(255, 255, 255, 255)
            surface.DrawRect(scrX - 3, scrY - 3, 6, 6)
        else
            -- Off-screen indicator chevron / pip along perimeter
            local dx = scrX - cx
            local dy = scrY - cy
            local ang = math.atan2(dy, dx)
            local pipX = math.Clamp(cx + math.cos(ang) * (radarRadius + 12), CLIP_MIN_X + 8, CLIP_MAX_X - 8)
            local pipY = math.Clamp(cy + math.sin(ang) * (radarRadius + 12), CLIP_MIN_Y + 8, CLIP_MAX_Y - 8)
            local flash = (math.floor(now * 5) % 2 == 0)
            surface.SetDrawColor(255, 60, 60, flash and 255 or 100)
            surface.DrawRect(pipX - 4, pipY - 4, 8, 8)
        end

        -- ====================================================================
        -- RELATIVE BEARING
        -- rData.bearing is an absolute MAP angle (atan2 of the world offset),
        -- which does not change when the vehicle turns and says nothing about
        -- which end of the truck the vortex is at. Derive the track-up bearing
        -- from the same relFwd/relRgt that place the blip, so this readout can
        -- never disagree with where the blip is actually drawn.
        -- Convention matches the screen: 000 = dead ahead, clockwise positive,
        -- 090 = vehicle right, 180 = dead astern, 270 = vehicle left.
        -- ====================================================================
        local relBearing = math.deg(math.atan2(relRgt, relFwd))
        -- Normalise into [0, 360). atan2 can return exactly -0.0, and -0.0 < 0 is
        -- false, so a plain "if negative then add 360" leaves it at -0 -- which
        -- then fails every branch below (not < 45, not >= 315) and lands in the
        -- LEFT else. A vortex dead ahead would read as LEFT.
        relBearing = relBearing % 360
        if relBearing >= 360 then relBearing = 0 end

        local sector, sectorCol
        if relBearing < 45 or relBearing >= 315 then
            sector, sectorCol = "AHEAD",  Color(255, 90, 90, 255)
        elseif relBearing < 135 then
            sector, sectorCol = "RIGHT",  Color(255, 190, 60, 255)
        elseif relBearing < 225 then
            sector, sectorCol = "ASTERN", Color(120, 220, 255, 255)
        else
            sector, sectorCol = "LEFT",   Color(255, 190, 60, 255)
        end

        -- Telemetry data box (Top Left)
        surface.SetDrawColor(0, 20, 25, 200)
        surface.DrawRect(14, 46, 170, 128)
        surface.SetDrawColor(0, 180, 220, 160)
        surface.DrawOutlinedRect(14, 46, 170, 128)

        local distM = math.Round((rData.dist or 0) * 0.01905)
        draw.SimpleText(string.format("DIST:  %d m", distM), "Trebuchet18", 22, 52, Color(0, 240, 255, 255))
        draw.SimpleText(string.format("SPEED: %.0f MPH", rData.speedMPH or 0), "Trebuchet18", 22, 70, Color(255, 220, 60, 255))
        -- REL BRG is clockwise from the vehicle's own nose, so it always agrees
        -- with the blip above. The old "BEAR" line was the map angle, which
        -- reads as a direction but is not one.
        draw.SimpleText(string.format("REL BRG: %03.0f %s", relBearing, sector), "Trebuchet18", 22, 88, sectorCol)
        draw.SimpleText(string.format("CORE:  %d m", math.Round((rData.coreRadius or 600) * 0.01905)), "Trebuchet18", 22, 106, Color(255, 100, 100, 255))
        draw.SimpleText(string.format("MAP BRG: %.0f", rData.bearing or 0), "DefaultFixed", 22, 126, Color(130, 155, 175, 255))
        -- Calibration aid: the heading correction currently applied. Reads 0 when
        -- the radar trusts veh:GetForward() as-is.
        draw.SimpleText(string.format("HDG %+.0f  BLIP %+.0f", headingOff, TIV.BlipOffsetDeg()), "DefaultFixed", 22, 140, Color(110, 135, 155, 255))

        -- Publish for other consumers (Wiremod screens, E2 chips, debug).
        TIV.Instruments.RelativeBearing = relBearing
        TIV.Instruments.RelativeSector  = sector

        -- Threat Assessment Banner (Bottom)
        local bannerY = 458
        local impact = rData.impactType or "receding"

        if impact == "core" then
            local flash = (math.floor(now * 4) % 2 == 0)
            local bCol = flash and Color(220, 30, 30, 230) or Color(120, 15, 15, 230)
            surface.SetDrawColor(bCol.r, bCol.g, bCol.b, bCol.a)
            surface.DrawRect(12, bannerY, 488, 38)
            draw.SimpleText(string.format("WARNING: DIRECT CORE IMPACT // ETA: %.0fs", rData.eta or 0), "Trebuchet24", 256, bannerY + 7, Color(255, 255, 255, 255), TEXT_ALIGN_CENTER)
        elseif impact == "side" then
            surface.SetDrawColor(220, 140, 0, 220)
            surface.DrawRect(12, bannerY, 488, 38)
            draw.SimpleText(string.format("CAUTION: SIDE VORTEX SWEEP // ETA: %.0fs", rData.eta or 0), "Trebuchet24", 256, bannerY + 7, Color(0, 0, 0, 255), TEXT_ALIGN_CENTER)
        elseif impact == "miss" then
            surface.SetDrawColor(0, 140, 80, 220)
            surface.DrawRect(12, bannerY, 488, 38)
            draw.SimpleText(string.format("PASSING FLANK // CLOSEST DIST: %d m", math.Round((rData.dist or 0) * 0.01905)), "Trebuchet24", 256, bannerY + 7, Color(255, 255, 255, 255), TEXT_ALIGN_CENTER)
        else
            surface.SetDrawColor(30, 70, 120, 220)
            surface.DrawRect(12, bannerY, 488, 38)
            draw.SimpleText("VORTEX RECEDING // MOVING AWAY", "Trebuchet24", 256, bannerY + 7, Color(220, 240, 255, 255), TEXT_ALIGN_CENTER)
        end
    else
        -- Standby searching mode
        surface.SetDrawColor(0, 30, 40, 200)
        surface.DrawRect(12, 458, 488, 38)
        draw.SimpleText("DOPPLER RADAR ONLINE // NO VORTEX DETECTED", "Trebuchet24", 256, 465, Color(0, 230, 255, 200), TEXT_ALIGN_CENTER)

        draw.SimpleText("SCANNING MESOCYCLONES...", "Trebuchet18", cx, cy - 25, Color(0, 180, 140, 180), TEXT_ALIGN_CENTER)
        draw.SimpleText("ATMOSPHERIC STATUS: CALM", "Trebuchet18", cx, cy + 10, Color(120, 160, 180, 160), TEXT_ALIGN_CENTER)
    end
end

-- ============================================================================
-- MONITOR GEOMETRY & SCREEN BOUNDS CONFIGURATION
-- Calibrated per monitor model for exact fit on glass textures without bezel clipping.
-- ============================================================================
local MONITOR_CONFIGS = {
    ["models/kobilica/wiremonitorsmall.mdl"] = {
        offset = Vector(0.36, 0.05, 5.05),
        rot    = Angle(0, 90, 90),
        scale  = 0.0171,
        w      = 512,
        h      = 512,
    },
    ["models/props_lab/monitor01b.mdl"] = {
        offset = Vector(6.58, -1.0, 0.45),
        rot    = Angle(0, 90, 90),
        scale  = 0.0175,
        w      = 512,
        h      = 512,
    },
    ["models/props_lab/monitor01a.mdl"] = {
        offset = Vector(6.58, -1.0, 0.45),
        rot    = Angle(0, 90, 90),
        scale  = 0.0175,
        w      = 512,
        h      = 512,
    },
    ["models/props_c17/tv_monitor01.mdl"] = {
        offset = Vector(5.60, 0.6, 1.5),
        rot    = Angle(0, 90, 90),
        scale  = 0.0215,
        w      = 512,
        h      = 512,
    },
    ["models/props_lab/monitor02.mdl"] = {
        offset = Vector(9.10, 13.75, 4.9),
        rot    = Angle(0, 90, 82.5),
        scale  = 0.030,
        w      = 512,
        h      = 512,
    },
}

function TIV.Instruments.GetMonitorConfig(ent)
    if not IsValid(ent) then
        return {
            offset = Vector(0.36, 0.05, 5.05),
            rot    = Angle(0, 90, 90),
            scale  = 0.0171,
            w      = 512,
            h      = 512,
        }
    end

    local mdl = string.lower(ent:GetModel() or "")
    if MONITOR_CONFIGS[mdl] then
        return MONITOR_CONFIGS[mdl]
    end

    -- Wiremod GPU monitor table integration fallback
    if WireGPU_Monitors and WireGPU_Monitors[mdl] then
        local mon = WireGPU_Monitors[mdl]
        local w = math.abs((mon.x2 or 4.5) - (mon.x1 or -4.4))
        local h = math.abs((mon.y2 or 9.5) - (mon.y1 or 0.6))
        local s = (h > 0) and (h / 512) or 0.0171
        local offX = (mon.offset and mon.offset.x or 0.3) + 0.06
        local offY = (mon.offset and mon.offset.y or 0.0)
        local offZ = (mon.offset and mon.offset.z or 5.0)
        return {
            offset = Vector(offX, offY, offZ),
            rot    = mon.rot or Angle(0, 90, 90),
            scale  = s,
            w      = 512,
            h      = 512,
        }
    end

    -- Universal default (matches Wiremod small monitor)
    return {
        offset = Vector(0.36, 0.05, 5.05),
        rot    = Angle(0, 90, 90),
        scale  = 0.0171,
        w      = 512,
        h      = 512,
    }
end

TIV.Instruments.DrawRadarScreen = DrawRadarScreen

-- ============================================================================
-- RADAR SCREEN CACHE
--
-- This used to run ents.FindByClass("prop_physics") inside
-- PostDrawTranslucentRenderables, i.e. a sweep of every prop_physics in the map
-- on every frame, on every client, just to find the zero or one radar screen
-- belonging to this vehicle. On a build-heavy sandbox map that is thousands of
-- entities per frame for nothing.
--
-- The list is now maintained from entity lifecycle events instead. The sweep
-- still happens, but only once per second, because the TIV_RadarScreen /
-- TIV_OwnerVehicle network vars are set server-side *after* the prop spawns and
-- can therefore arrive after OnEntityCreated has already fired.
-- ============================================================================
local screenCache = {}
local screenCachePending = {}   -- props awaiting their network vars
local nextCacheSweep = 0

-- How long an untagged prop may sit in the pending set before we conclude it is
-- just an ordinary prop. This is purely a leak guard for long-lived clutter:
-- correctness does not depend on it, because the 1 Hz sweep re-reads the map
-- and will adopt any radar screen whenever its network var turns up.
local PENDING_TTL = 10

local function IsRadarScreen(ent)
    return IsValid(ent)
        and ent:GetNWBool("TIV_RadarScreen", false)
        and (IsValid(ent:GetNWEntity("TIV_OwnerVehicle")) or IsValid(ent:GetParent()))
end

local function RebuildScreenCache()
    screenCache = {}
    for _, ent in ipairs(ents.FindByClass("prop_physics")) do
        if IsRadarScreen(ent) then
            screenCache[#screenCache + 1] = ent
        end
    end
end

local function CacheScreen(ent)
    for _, existing in ipairs(screenCache) do
        if existing == ent then return end
    end
    screenCache[#screenCache + 1] = ent
end

local function AddScreenCandidate(ent)
    if not IsValid(ent) then return end
    if ent:GetClass() ~= "prop_physics" then return end

    if IsRadarScreen(ent) then
        CacheScreen(ent)
    else
        -- Network vars may not have landed yet; re-check for a short while.
        screenCachePending[ent] = CurTime()
    end
end

hook.Add("OnEntityCreated", "TIV_RadarScreenCreated", AddScreenCandidate)

hook.Add("EntityRemoved", "TIV_RadarScreenRemoved", function(ent)
    screenCachePending[ent] = nil
    for i, cached in ipairs(screenCache) do
        if cached == ent then
            table.remove(screenCache, i)
            return
        end
    end
end)

-- ============================================================================
-- 3D2D RENDER HOOK ON VEHICLE SCREEN PROPS
-- ============================================================================
hook.Add("PostDrawTranslucentRenderables", "TIV_RenderRadarScreens", function(bDrawingDepth, bDrawingSkybox)
    if bDrawingSkybox then return end

    local lp = LocalPlayer()
    if not IsValid(lp) then return end
    local eyePos = EyePos()

    -- Resolve props whose network vars arrived after OnEntityCreated. This is a
    -- pass over the pending set only (normally zero or one props), not a map
    -- sweep. A prop leaves the set once it is tagged, or once it is gone, or
    -- once it has been sitting there untagged for PENDING_TTL.
    if next(screenCachePending) ~= nil then
        for ent, since in pairs(screenCachePending) do
            if IsRadarScreen(ent) then
                screenCachePending[ent] = nil
                CacheScreen(ent)
            elseif not IsValid(ent) or CurTime() - since > PENDING_TTL then
                screenCachePending[ent] = nil
            end
        end
    end

    local now = CurTime()
    if now >= nextCacheSweep then
        nextCacheSweep = now + 1
        RebuildScreenCache()
    end

    for _, ent in ipairs(screenCache) do
        if IsValid(ent) and ent:GetNWBool("TIV_RadarScreen") then
            local distSqr = ent:GetPos():DistToSqr(eyePos)
            if distSqr <= 1000 * 1000 then
                local veh = ent:GetNWEntity("TIV_OwnerVehicle")
                -- This screen belongs to `veh`, so it must show `veh`'s own packet.
                -- Reading the shared table here is what let one jeep's screen draw
                -- another jeep's tornado position in multiplayer.
                local rData = TIV.Instruments.GetRadarData(veh, LocalPlayer())

                local cfg = TIV.Instruments.GetMonitorConfig(ent)
                local pScale = ent:GetModelScale() or 1.0

                local centerPos = ent:LocalToWorld(cfg.offset * pScale)
                local screenAng = ent:LocalToWorldAngles(cfg.rot)

                -- Backface culling: skip rendering when looking from behind the screen casing
                local normal = screenAng:Up()
                if (eyePos - centerPos):Dot(normal) > 0 then
                    local scale = cfg.scale * pScale
                    local halfW = (cfg.w * 0.5) * scale
                    local halfH = (cfg.h * 0.5) * scale

                    -- Shift origin by (-halfW, -halfH) so the 512x512 canvas is centered on the monitor glass
                    local topLeftPos = centerPos - screenAng:Forward() * halfW - screenAng:Right() * halfH

                    cam.Start3D2D(topLeftPos, screenAng, scale)
                        render.ClearStencil()
                        render.SetStencilEnable(true)
                        render.SetStencilTestMask(0xFF)
                        render.SetStencilWriteMask(0xFF)
                        render.SetStencilReferenceValue(1)
                        render.SetStencilCompareFunction(STENCIL_ALWAYS)
                        render.SetStencilPassOperation(STENCIL_REPLACE)
                        render.SetStencilFailOperation(STENCIL_KEEP)
                        render.SetStencilZFailOperation(STENCIL_KEEP)

                        -- Mask out the exact 512x512 physical monitor face
                        surface.SetDrawColor(0, 0, 0, 255)
                        surface.DrawRect(0, 0, 512, 512)

                        render.SetStencilCompareFunction(STENCIL_EQUAL)
                        render.SetStencilPassOperation(STENCIL_KEEP)

                        DrawRadarScreen(ent, veh, rData)

                        render.SetStencilEnable(false)
                    cam.End3D2D()
                end
            end
        end
    end
end)

print("[TIV] Tactical radar screen client loaded")
