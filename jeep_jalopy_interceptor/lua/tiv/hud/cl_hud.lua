-- ============================================================================
-- MODERN TIV COCKPIT INSTRUMENTS HUD
-- Streamlined storm intercept telemetry, high-contrast digital readouts,
-- dynamic EF-scale intensity metering, anchor array micro-diagnostics,
-- and critical loft/shear alerts.
-- ============================================================================

TIV.HUD = TIV.HUD or {}

local cvarHudEnabled = CreateClientConVar("tiv_hud_enabled", "1", true, false, "Enable the TIV cockpit instruments HUD.")
local cvarHudUnit    = CreateClientConVar("tiv_hud_unit", "mph", true, false, "Speed/wind display unit (mph, kmh, knots).")
local cvarHudPos     = CreateClientConVar("tiv_hud_position", "0", true, false, "HUD position: 0=Bottom-Right, 1=Bottom-Left, 2=Top-Right, 3=Top-Left.")
local cvarHudScale   = CreateClientConVar("tiv_hud_scale", "1.0", true, false, "HUD scale multiplier (0.75 to 1.5).")

-- Typography
surface.CreateFont("TIV_HUD_Title", {
    font = "Trebuchet MS",
    size = 14,
    weight = 700,
    antialias = true,
})

surface.CreateFont("TIV_HUD_Hero", {
    font = "Trebuchet MS",
    size = 28,
    weight = 800,
    antialias = true,
})

surface.CreateFont("TIV_HUD_Unit", {
    font = "Trebuchet MS",
    size = 11,
    weight = 700,
    antialias = true,
})

surface.CreateFont("TIV_HUD_Label", {
    font = "Trebuchet MS",
    size = 11,
    weight = 700,
    antialias = true,
})

surface.CreateFont("TIV_HUD_Sub", {
    font = "Trebuchet MS",
    size = 11,
    weight = 600,
    antialias = true,
})

surface.CreateFont("TIV_HUD_Bold", {
    font = "Trebuchet MS",
    size = 12,
    weight = 700,
    antialias = true,
})

surface.CreateFont("TIV_HUD_Alert", {
    font = "Trebuchet MS",
    size = 11,
    weight = 800,
    antialias = true,
})

-- State colors and labels
local STATE_COLORS = {
    idle             = Color(80, 220, 120),
    lowering         = Color(245, 205, 50),
    deploying_spikes = Color(255, 145, 40),
    anchored         = Color(50, 205, 255),
    retracting       = Color(245, 205, 50),
    raising          = Color(245, 205, 50),
    lofted           = Color(255, 55, 55),
}

local APC_STATE_COLORS = {
    idle             = Color(120, 170, 95),
    lowering         = Color(220, 190, 60),
    deploying_spikes = Color(230, 140, 40),
    anchored         = Color(80, 160, 230),
    retracting       = Color(220, 190, 60),
    raising          = Color(220, 190, 60),
    lofted           = Color(225, 60, 60),
}

local STATE_LABELS = {
    idle             = "MOBILE // READY",
    lowering         = "HYDRAULICS LOWERING",
    deploying_spikes = "DRIVING SPIKES",
    anchored         = "SECURED // ANCHORED",
    retracting       = "RETRACTING SPIKES",
    raising          = "HYDRAULICS RAISING",
    lofted           = "CRITICAL // DETACHED",
}

local STATE_ACTIONS = {
    idle             = "[B] DEPLOY",
    anchored         = "[B] RETRACT",
    lowering         = "WAITING",
    deploying_spikes = "WAITING",
    retracting       = "WAITING",
    raising          = "WAITING",
    lofted           = "DETACHED",
}

local EF_THRESHOLDS = { 65, 86, 111, 136, 166 }
local EF_COLORS = {
    Color(100, 220, 100),
    Color(180, 220, 50),
    Color(240, 200, 40),
    Color(240, 130, 30),
    Color(240, 50, 40)
}

-- ============================================================================
-- MAIN HUD PAINT
-- ============================================================================
hook.Add("HUDPaint", "TIV_DrawHUD", function()
    if not cvarHudEnabled:GetBool() then return end
    if not TIV.Config or not TIV.Config.HUDEnabled then return end
    if not TIV.Instruments or not TIV.Instruments.Data then return end

    local ply = LocalPlayer()
    if not IsValid(ply) then return end

    local veh = (TIV.ResolveVehicle and TIV.ResolveVehicle(ply)) or ply:GetVehicle()
    if not IsValid(veh) then return end

    if TIV.IsSupportedVehicle and not TIV.IsSupportedVehicle(veh) then
        local parent = veh:GetParent()
        if IsValid(parent) and TIV.IsSupportedVehicle(parent) then
            veh = parent
        else
            return
        end
    end

    local cls   = string.lower(veh:GetClass() or "")
    local model = string.lower(veh:GetModel() or "")
    local isAPC = cls == "prop_vehicle_apc" or string.find(model, "apc", 1, true) ~= nil

    local data = TIV.Instruments.Data
    local windSpeed         = data.windSpeed         or 0
    local vehicleSpeed      = data.vehicleSpeed      or 0
    local activeConstraints = data.activeConstraints or 0
    local stress            = data.stress            or 0
    local state             = data.deployState       or "idle"

    -- Unit conversion
    local unitMode = string.lower(cvarHudUnit:GetString() or "mph")
    local unitSuffix = "MPH"
    local unitScale = 1.0
    if unitMode == "kmh" or unitMode == "km/h" then
        unitSuffix = "KM/H"
        unitScale  = 1.60934
    elseif unitMode == "knots" or unitMode == "kts" or unitMode == "knot" then
        unitSuffix = "KTS"
        unitScale  = 0.868976
    end

    -- Wind limit & loft check
    local threshold = (IsValid(veh) and veh._TIVEffectiveStats and veh._TIVEffectiveStats.effective_loft_mph)
        or TIV.Config.LoftWindThreshold
        or 180
    local isOverLimit = (windSpeed >= threshold)

    -- Warning levels
    local anchorFail = TIV.Instruments.GetAnchorFail and TIV.Instruments.GetAnchorFail(veh)
    local warningLevel = 0
    local warningText = ""
    if isOverLimit then
        warningLevel = 2
        warningText  = "CRITICAL: WIND VELOCITY EXCEEDS STRUCTURAL LIMIT"
    elseif anchorFail then
        warningLevel = 2
        warningText  = "ALERT: GROUND ANCHOR PIN FAILURE DETECTED"
    elseif windSpeed >= 150 then
        warningLevel = 1
        warningText  = "CAUTION: EXTREME VORTEX CORE SHEAR PASS"
    end

    -- Theme colors
    local colorTable = isAPC and APC_STATE_COLORS or STATE_COLORS
    local stateColor = colorTable[state] or Color(80, 220, 120)
    if state == "deploying_spikes" then
        local blink = math.abs(math.sin(CurTime() * 4))
        stateColor = Color(stateColor.r, stateColor.g, stateColor.b, 155 + blink * 100)
    end

    -- Layout Dimensions
    local sw, sh = ScrW(), ScrH()
    local scale  = math.Clamp(cvarHudScale:GetFloat(), 0.75, 1.5)
    local panelW = 340 * scale
    local hasAlert = (warningLevel > 0)
    local hasRadar = (TIV.Progression and TIV.Progression.IsUnlocked and TIV.Progression.IsUnlocked("path_screen"))
        or (TIV.Instruments and TIV.Instruments.RadarData and TIV.Instruments.RadarData.active)
    local baseH  = (hasAlert and 220 or 192) + (hasRadar and 42 or 0)
    local panelH = baseH * scale

    local posMode = cvarHudPos:GetInt()
    local marginX, marginY = 24, 24
    local panelX, panelY
    if posMode == 1 then -- Bottom-Left
        panelX = marginX
        panelY = sh - panelH - marginY
    elseif posMode == 2 then -- Top-Right
        panelX = sw - panelW - marginX
        panelY = marginY
    elseif posMode == 3 then -- Top-Left
        panelX = marginX
        panelY = marginY
    else -- 0 = Bottom-Right (Default)
        panelX = sw - panelW - marginX
        panelY = sh - panelH - marginY
    end

    -- Outer Glow / Flash on state transition
    local flashAge = 1.0
    if TIV.Deploy.GetFlashFor then
        flashAge = CurTime() - TIV.Deploy.GetFlashFor(veh)
    elseif TIV.Deploy.LastStateFlash then
        flashAge = CurTime() - TIV.Deploy.LastStateFlash
    end

    if flashAge < 0.4 then
        local fAlpha = (1 - flashAge / 0.4) * 110
        draw.RoundedBox(8, panelX - 3, panelY - 3, panelW + 6, panelH + 6,
            Color(stateColor.r, stateColor.g, stateColor.b, fAlpha))
    else
        draw.RoundedBox(8, panelX - 1, panelY - 1, panelW + 2, panelH + 2,
            Color(stateColor.r * 0.4, stateColor.g * 0.4, stateColor.b * 0.4, 60))
    end

    -- Main Card Background (Modern Dark Translucent Glass)
    draw.RoundedBox(8, panelX, panelY, panelW, panelH, Color(12, 16, 24, 235))
    surface.SetDrawColor(45, 55, 75, 180)
    surface.DrawOutlinedRect(panelX, panelY, panelW, panelH)

    -- Top Accent Line (Color-coded by state)
    draw.RoundedBoxEx(8, panelX + 1, panelY + 1, panelW - 2, 3, stateColor, true, true, false, false)

    -- ------------------------------------------------------------------------
    -- 1. HEADER ROW: Interceptor Title, Pulse Dot, & Points Badge
    -- ------------------------------------------------------------------------
    local curY = panelY + 9

    -- Pulsing Status Dot
    local pulse = math.abs(math.sin(CurTime() * 3))
    draw.RoundedBox(4, panelX + 14, curY + 3, 7, 7, Color(stateColor.r, stateColor.g, stateColor.b, 255))
    draw.RoundedBox(6, panelX + 12 - pulse * 2, curY + 1 - pulse * 2, 11 + pulse * 4, 11 + pulse * 4,
        Color(stateColor.r, stateColor.g, stateColor.b, 60 * (1 - pulse)))

    -- Header Title
    local titleText = isAPC and "TIV // APC TELEMETRY" or "TIV-2 // INTERCEPTOR"
    draw.SimpleText(titleText, "TIV_HUD_Title", panelX + 28, curY + 7, Color(240, 245, 255), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

    -- Points Pill (Top-Right)
    local pts = TIV.Progression and (TIV.Progression.Points or TIV.Progression.CurrentIntercepts) or 0
    local ptsText = "PTS: " .. pts
    local pillW = 76
    local pillX = panelX + panelW - pillW - 12
    draw.RoundedBox(4, pillX, curY - 1, pillW, 18, Color(240, 180, 40, 30))
    surface.SetDrawColor(240, 180, 40, 140)
    surface.DrawOutlinedRect(pillX, curY - 1, pillW, 18)
    draw.SimpleText(ptsText, "TIV_HUD_Bold", pillX + pillW / 2, curY + 8, Color(255, 215, 80), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

    curY = curY + 24

    -- ------------------------------------------------------------------------
    -- 2. PRIMARY HERO TELEMETRY: Wind Velocity (Left) & Ground Speed (Right)
    -- ------------------------------------------------------------------------
    local cardGap = 8
    local padX    = 12
    local totalW  = panelW - (padX * 2)
    local windW   = math.floor(totalW * 0.58)
    local speedW  = totalW - windW - cardGap
    local tileH   = 56

    local windX   = panelX + padX
    local speedX  = windX + windW + cardGap

    -- --- TILE 1: WIND SPEED ---
    draw.RoundedBox(5, windX, curY, windW, tileH, Color(18, 24, 34, 200))
    surface.SetDrawColor(38, 48, 66, 160)
    surface.DrawOutlinedRect(windX, curY, windW, tileH)

    -- Wind Aspect / Bearing relative to vehicle
    local relWindText = ""
    local relWindCol  = Color(140, 160, 180)
    if data.windDir and data.windDir:LengthSqr() > 0.01 and IsValid(veh) then
        local vehForward = veh:GetForward()
        local wDir = data.windDir:GetNormalized()
        local dotFwd = vehForward:Dot(wDir)
        local vehRight = veh:GetRight()
        local dotRight = vehRight:Dot(wDir)

        if dotFwd > 0.707 then
            relWindText = "TAILWIND"
            relWindCol  = Color(240, 180, 50)
        elseif dotFwd < -0.707 then
            relWindText = "HEAD-ON"
            relWindCol  = Color(80, 220, 120)
        elseif dotRight > 0 then
            relWindText = "CROSS-R"
            relWindCol  = Color(240, 130, 50)
        else
            relWindText = "CROSS-L"
            relWindCol  = Color(240, 130, 50)
        end
    end

    draw.SimpleText("WIND VELOCITY", "TIV_HUD_Label", windX + 8, curY + 5, Color(140, 155, 175), TEXT_ALIGN_LEFT)
    if relWindText ~= "" then
        draw.SimpleText(relWindText, "TIV_HUD_Unit", windX + windW - 8, curY + 5, relWindCol, TEXT_ALIGN_RIGHT)
    end

    -- Wind Speed Hero Readout & Unit
    local windVal = math.floor(windSpeed * unitScale)
    local windColor = Color(90, 220, 120)
    if windSpeed > 80  then windColor = Color(230, 210, 60) end
    if windSpeed > 120 then windColor = Color(255, 140, 40) end
    if windSpeed > 150 then windColor = Color(255, 60, 60)  end

    local windStr = tostring(windVal)
    if isOverLimit then
        local blink = (math.floor(CurTime() * 5) % 2 == 0)
        windColor = blink and Color(255, 40, 40) or Color(255, 160, 160)
        windStr   = "ERROR"
    end

    draw.SimpleText(windStr, "TIV_HUD_Hero", windX + 8, curY + 16, windColor, TEXT_ALIGN_LEFT)
    if not isOverLimit then
        draw.SimpleText(unitSuffix, "TIV_HUD_Unit", windX + 8 + string.len(windStr) * 16 + 4, curY + 28, Color(160, 175, 195), TEXT_ALIGN_LEFT)
    end

    -- EF-Scale Intensity Micro-Gauge
    local efW = (windW - 16 - 8) / 5
    for i = 1, 5 do
        local segX = windX + 8 + (i - 1) * (efW + 2)
        local segActive = (windSpeed >= EF_THRESHOLDS[i])
        local segCol = segActive and EF_COLORS[i] or Color(28, 35, 48, 160)
        draw.RoundedBox(2, segX, curY + tileH - 8, efW, 3, segCol)
    end

    -- --- TILE 2: GROUND SPEED ---
    draw.RoundedBox(5, speedX, curY, speedW, tileH, Color(18, 24, 34, 200))
    surface.SetDrawColor(38, 48, 66, 160)
    surface.DrawOutlinedRect(speedX, curY, speedW, tileH)

    draw.SimpleText("GROUND SPEED", "TIV_HUD_Label", speedX + 8, curY + 5, Color(140, 155, 175), TEXT_ALIGN_LEFT)

    local vehVal = math.floor(vehicleSpeed * unitScale)
    local vehStr = tostring(vehVal)
    draw.SimpleText(vehStr, "TIV_HUD_Hero", speedX + 8, curY + 16, Color(210, 230, 255), TEXT_ALIGN_LEFT)
    draw.SimpleText(unitSuffix, "TIV_HUD_Unit", speedX + 8 + string.len(vehStr) * 16 + 4, curY + 28, Color(150, 170, 190), TEXT_ALIGN_LEFT)

    -- Mobile / Parked Tag
    local motionTag = vehicleSpeed < 3 and "PARKED" or "CRUISING"
    local motionCol = vehicleSpeed < 3 and Color(120, 210, 150) or Color(110, 180, 240)
    draw.SimpleText(motionTag, "TIV_HUD_Unit", speedX + speedW - 8, curY + tileH - 10, motionCol, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)

    curY = curY + tileH + 7

    -- ------------------------------------------------------------------------
    -- 3. DEPLOYMENT & ANCHOR ARRAY STATUS
    -- ------------------------------------------------------------------------
    local stateH = 36
    draw.RoundedBox(5, panelX + padX, curY, totalW, stateH, Color(18, 24, 34, 200))
    surface.SetDrawColor(stateColor.r * 0.4, stateColor.g * 0.4, stateColor.b * 0.4, 180)
    surface.DrawOutlinedRect(panelX + padX, curY, totalW, stateH)

    -- Status Label
    local stateTitle = STATE_LABELS[state] or string.upper(state)
    draw.SimpleText(stateTitle, "TIV_HUD_Bold", panelX + padX + 10, curY + 6, stateColor, TEXT_ALIGN_LEFT)

    -- Key Action Prompt Pill Button
    local actionText = STATE_ACTIONS[state] or "[B]"
    local actPillW   = 76
    local actPillX   = panelX + padX + totalW - actPillW - 8
    local actPillCol = (state == "idle" or state == "anchored") and stateColor or Color(140, 150, 165)

    draw.RoundedBox(3, actPillX, curY + 5, actPillW, 16, Color(actPillCol.r * 0.2, actPillCol.g * 0.2, actPillCol.b * 0.2, 180))
    surface.SetDrawColor(actPillCol.r, actPillCol.g, actPillCol.b, 120)
    surface.DrawOutlinedRect(actPillX, curY + 5, actPillW, 16)
    draw.SimpleText(actionText, "TIV_HUD_Unit", actPillX + actPillW / 2, curY + 13, actPillCol, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

    -- 6 Minimalist Anchor Array Pips (FL, FR, ML, MR, RL, RR)
    local pipStartX = panelX + padX + 10
    local pipW = 14
    local pipH = 3
    local pipGap = 4

    local animData = TIV.SpikeAnim and TIV.SpikeAnim.ActiveAnims and TIV.SpikeAnim.ActiveAnims[veh:EntIndex()]
    for i = 1, 6 do
        local pipX = pipStartX + (i - 1) * (pipW + pipGap)
        local pipCol = Color(40, 48, 62)

        if animData and animData.phases and animData.phases[i] then
            local phase = animData.phases[i]
            if phase == "deployed" then
                pipCol = Color(60, 220, 180)
            elseif phase == "deploying" or phase == "retracting" then
                pipCol = Color(245, 165, 40)
            elseif phase == "released" then
                pipCol = Color(240, 60, 60)
            end
        elseif state == "anchored" and i <= activeConstraints then
            pipCol = Color(60, 220, 180)
        end

        draw.RoundedBox(1, pipX, curY + 26, pipW, pipH, pipCol)
    end

    local anchorCountText = activeConstraints > 0 and (activeConstraints .. "/6 ENGAGED") or "DISENGAGED"
    local anchorCountCol  = activeConstraints > 0 and Color(80, 220, 180) or Color(130, 140, 155)
    draw.SimpleText("ANCHORS: " .. anchorCountText, "TIV_HUD_Sub", panelX + padX + totalW - 8, curY + 26, anchorCountCol, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)

    curY = curY + stateH + 7

    -- ------------------------------------------------------------------------
    -- 4. ANCHOR STRESS & VORTEX LOAD METER
    -- ------------------------------------------------------------------------
    local stressFrac = math.Clamp(stress or 0, 0, 1)
    local stressPct  = math.floor(stressFrac * 100)

    draw.SimpleText("ANCHOR LOAD", "TIV_HUD_Label", panelX + padX, curY, Color(140, 155, 175), TEXT_ALIGN_LEFT)
    local stressCol = Color(90, 220, 120)
    if stressFrac >= 0.6  then stressCol = Color(240, 180, 40) end
    if stressFrac >= 0.85 then stressCol = Color(255, 60, 60)  end

    draw.SimpleText(stressPct .. "%", "TIV_HUD_Bold", panelX + padX + totalW, curY, stressCol, TEXT_ALIGN_RIGHT)

    curY = curY + 14

    -- Stress Bar Track
    local barH = 6
    draw.RoundedBox(3, panelX + padX, curY, totalW, barH, Color(20, 26, 36, 220))
    surface.SetDrawColor(40, 50, 70, 140)
    surface.DrawOutlinedRect(panelX + padX, curY, totalW, barH)

    local fillW = math.floor(totalW * stressFrac)
    if fillW > 2 then
        draw.RoundedBox(2, panelX + padX + 1, curY + 1, fillW - 2, barH - 2, stressCol)
        if stressFrac > 0.7 then
            local sPulse = math.abs(math.sin(CurTime() * 8)) * 80
            draw.RoundedBox(2, panelX + padX + 1, curY + 1, fillW - 2, barH - 2, Color(255, 255, 255, sPulse))
        end
    end

    -- 70% Safe Threshold Marker
    local threshX = panelX + padX + math.floor(totalW * 0.7)
    surface.SetDrawColor(240, 80, 80, 220)
    surface.DrawLine(threshX, curY - 2, threshX, curY + barH + 2)

    curY = curY + barH + 7

    -- ------------------------------------------------------------------------
    -- 5. CRITICAL WARNING BANNER (Shows only during storm alerts)
    -- ------------------------------------------------------------------------
    if hasAlert then
        local alertH = 22
        local alertBlink = math.abs(math.sin(CurTime() * (warningLevel == 2 and 7 or 4)))
        local alertBg = (warningLevel == 2)
            and Color(140, 20, 20, 180 + alertBlink * 60)
            or  Color(150, 90, 20, 180 + alertBlink * 60)
        local alertBorder = (warningLevel == 2)
            and Color(255, 60, 60, 220)
            or  Color(255, 170, 40, 220)

        draw.RoundedBox(4, panelX + padX, curY, totalW, alertH, alertBg)
        surface.SetDrawColor(alertBorder)
        surface.DrawOutlinedRect(panelX + padX, curY, totalW, alertH)

        draw.SimpleText(warningText, "TIV_HUD_Alert", panelX + padX + totalW / 2, curY + alertH / 2,
            Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        curY = curY + alertH + 6
    end

    -- ------------------------------------------------------------------------
    -- 6. TACTICAL DOPPLER RADAR TELEMETRY (If path_screen upgrade is active)
    -- ------------------------------------------------------------------------
    if hasRadar then
        local radarH = 34
        draw.RoundedBox(4, panelX + padX, curY, totalW, radarH, Color(12, 18, 28, 220))
        surface.SetDrawColor(0, 180, 220, 140)
        surface.DrawOutlinedRect(panelX + padX, curY, totalW, radarH)

        -- The HUD belongs to the local player, so it must read that player's own
        -- vehicle's packet rather than whichever jeep's packet arrived last.
        -- GetRadarData(nil, ply) resolves the vehicle from the player.
        local rData = (TIV.Instruments and TIV.Instruments.GetRadarData
                and TIV.Instruments.GetRadarData(nil, LocalPlayer()))
            or (TIV.Instruments and TIV.Instruments.RadarData)
        if rData and rData.active then
            local distM = math.Round(rData.dist * 0.01905)

            -- Same track-up projection the radar blip uses. rData.bearing is an
            -- absolute MAP angle, so on its own it can read as "ahead" while the
            -- vortex is actually astern -- always show it next to the relative one.
            local rbVeh = (IsValid(rData.veh) and rData.veh)
                or ((TIV.ResolveVehicle and TIV.ResolveVehicle(LocalPlayer())) or nil)
            local relTxt, relDeg = "", nil
            if IsValid(rbVeh) and rData.pos then
                -- Shared helper: same heading correction and normalisation as the
                -- radar screen and the Expression 2 functions.
                relDeg = TIV.RelativeBearing(rbVeh, rData.pos)
                if relDeg < 45 or relDeg >= 315 then
                    relTxt = "AHEAD"
                elseif relDeg < 135 then
                    relTxt = "RIGHT"
                elseif relDeg < 225 then
                    relTxt = "ASTERN"
                else
                    relTxt = "LEFT"
                end
            end

            local statusCol = Color(0, 230, 255)
            local statusTxt = "TRACKING"
            if rData.impactType == "core" then
                statusCol = Color(255, 60, 60)
                statusTxt = "CORE IMPACT"
            elseif rData.impactType == "side" then
                statusCol = Color(255, 180, 40)
                statusTxt = "SIDE SWEEP"
            elseif rData.impactType == "miss" then
                statusCol = Color(60, 230, 120)
                statusTxt = "PASSING"
            else
                statusCol = Color(140, 180, 240)
                statusTxt = "RECEDING"
            end

            draw.SimpleText("DOPPLER TRACK: " .. statusTxt, "TIV_HUD_Bold", panelX + padX + 8, curY + 4, statusCol, TEXT_ALIGN_LEFT)
            draw.SimpleText(string.format("ETA: %.0fs", rData.eta), "TIV_HUD_Bold", panelX + padX + totalW - 8, curY + 4, Color(255, 255, 255), TEXT_ALIGN_RIGHT)

            local brgTxt = (relDeg and string.format("REL %03.0f %s", relDeg, relTxt))
                or string.format("MAP %.0f", rData.bearing)
            draw.SimpleText(string.format("DIST: %dm | SPD: %.0f MPH | %s", distM, rData.speedMPH, brgTxt),
                "TIV_HUD_Unit", panelX + padX + 8, curY + 18, Color(160, 180, 200), TEXT_ALIGN_LEFT)
        else
            draw.SimpleText("DOPPLER RADAR: SCANNING", "TIV_HUD_Bold", panelX + padX + 8, curY + 4, Color(0, 200, 230), TEXT_ALIGN_LEFT)
            draw.SimpleText("NO ACTIVE TORNADO IN RANGE", "TIV_HUD_Unit", panelX + padX + 8, curY + 18, Color(130, 150, 170), TEXT_ALIGN_LEFT)
        end
    end
end)

print("[TIV] Modern cockpit instruments HUD loaded")
