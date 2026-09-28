-- ============================================================================
-- TIV CLIENT SETTINGS & FIELD MANUAL
-- Comprehensive control center, presets, spike positioning visualizer,
-- storm physics tuning, HUD configuration, Wiremod guides, and field manual.
-- ============================================================================

TIV = TIV or {}
TIV.Menu = TIV.Menu or {}

-- ============================================================================
-- COLOR PALETTE & STYLES
-- ============================================================================
local THEME = {
    bg          = Color(20, 22, 26, 255),
    panelBg     = Color(28, 31, 38, 255),
    headerBg    = Color(15, 17, 21, 255),
    accent      = Color(230, 130, 35, 255),  -- Storm amber
    accentDark  = Color(160, 85, 20, 255),
    accentBlue  = Color(50, 150, 230, 255),  -- Sky blue
    text        = Color(230, 235, 240, 255),
    textDim     = Color(150, 160, 170, 255),
    textMuted   = Color(100, 110, 120, 255),
    success     = Color(60, 200, 100, 255),
    warning     = Color(240, 180, 40, 255),
    danger      = Color(240, 60, 60, 255),
    border      = Color(50, 55, 65, 255),
    grid        = Color(40, 45, 55, 180),
}

-- ============================================================================
-- PRESETS DEFINITION
-- ============================================================================
local PRESETS = {
    {
        id          = "the_tank",
        name        = "The Tank",
        color       = Color(240, 80, 50),
        desc        = "Heavy-duty anchors built to sit inside violent EF4 and EF5 tornadoes. Unbreakable force limit, high loft resistance, and auto-deploys when wind hits 130 MPH.",
        cvars = {
            tiv_spike_count                = 6,
            tiv_spike_force                = 0,      -- 0 = unbreakable
            tiv_loft_wind_threshold        = 320,
            tiv_hide_spikes                = 0,
            tiv_compat_mode                = 1,
            tiv_compat_anchored_wind_scale = 0.35,
            tiv_auto_deploy_wind           = 130,
            tiv_deploy_speed               = 1.5,
            tiv_suspension_limit           = 0,
            tiv_deploy_handbrake           = 1,
            tiv_spike_drive_depth          = 22,
            tiv_spike_group_front          = 1,
            tiv_spike_group_mid            = 1,
            tiv_spike_group_rear           = 1,
            tiv_loft_release_spikes        = 0,
        }
    },
    {
        id          = "daily_driver",
        name        = "Daily Driver",
        color       = Color(60, 180, 240),
        desc        = "Balanced everyday setup for normal storm chasing. Uses 6 standard spikes with realistic wind strain and automatic suspension lowering.",
        cvars = {
            tiv_spike_count                = 6,
            tiv_spike_force                = 80000,
            tiv_loft_wind_threshold        = 180,
            tiv_hide_spikes                = 0,
            tiv_compat_mode                = 1,
            tiv_compat_anchored_wind_scale = 0.65,
            tiv_auto_deploy_wind           = 0,
            tiv_deploy_speed               = 1.0,
            tiv_suspension_limit           = 0,
            tiv_deploy_handbrake           = 1,
            tiv_spike_drive_depth          = 18,
            tiv_spike_group_front          = 1,
            tiv_spike_group_mid            = 1,
            tiv_spike_group_rear           = 1,
            tiv_loft_release_spikes        = 0,
        }
    },
    {
        id          = "quick_spotter",
        name        = "Quick Spotter",
        color       = Color(240, 200, 40),
        desc        = "Light and nimble for fast chasing and quick escapes. Runs 4 corner spikes with doubled deploy speed so you can get in and out fast.",
        cvars = {
            tiv_spike_count                = 4,
            tiv_spike_force                = 60000,
            tiv_loft_wind_threshold        = 150,
            tiv_hide_spikes                = 0,
            tiv_compat_mode                = 1,
            tiv_compat_anchored_wind_scale = 0.75,
            tiv_auto_deploy_wind           = 0,
            tiv_deploy_speed               = 2.0,
            tiv_suspension_limit           = 0,
            tiv_deploy_handbrake           = 1,
            tiv_spike_drive_depth          = 15,
            tiv_spike_group_front          = 1,
            tiv_spike_group_mid            = 0,
            tiv_spike_group_rear           = 1,
            tiv_loft_release_spikes        = 0,
        }
    },
    {
        id          = "defaults",
        name        = "Reset to Default",
        color       = Color(160, 160, 160),
        desc        = "Resets all spike counts, forces, timings, and compatibility settings back to standard out-of-the-box defaults.",
        cvars = {
            tiv_spike_count                = 6,
            tiv_spike_force                = 80000,
            tiv_loft_wind_threshold        = 180,
            tiv_hide_spikes                = 0,
            tiv_wire_hide_controller       = 0,
            tiv_wire_auto_controller       = 1,
            tiv_compat_mode                = 1,
            tiv_compat_anchored_wind_scale = 0.65,
            tiv_compat_max_deploy_linear   = 650,
            tiv_compat_max_deploy_angular  = 300,
            tiv_compat_recovery_cooldown   = 3.0,
            tiv_auto_deploy_wind           = 0,
            tiv_deploy_speed               = 1.0,
            tiv_suspension_limit           = 0,
            tiv_deploy_handbrake           = 1,
            tiv_spike_drive_depth          = 18,
            tiv_spike_spread_offset        = 0,
            tiv_spike_length_offset        = 0,
            tiv_spike_group_front          = 1,
            tiv_spike_group_mid            = 1,
            tiv_spike_group_rear           = 1,
            tiv_loft_release_spikes        = 0,
        }
    }
}

function TIV.Menu.ApplyPreset(preset)
    if not preset or not preset.cvars then return end
    for cvar, val in pairs(preset.cvars) do
        RunConsoleCommand(cvar, tostring(val))
    end
    surface.PlaySound("buttons/button14.wav")
    notification.AddLegacy("[TIV] Applied preset: " .. preset.name, NOTIFY_GENERIC, 4)
end

-- ============================================================================
-- INTERACTIVE 2D SPIKE CHASSIS SCHEMATIC PANEL
-- ============================================================================
function TIV.Menu.CreateSpikeVisualizer(parent, width, height)
    local pnl = vgui.Create("DPanel", parent)
    pnl:SetSize(width or 320, height or 280)

    pnl.Paint = function(self, w, h)
        -- Dark blueprint/radar container
        draw.RoundedBox(6, 0, 0, w, h, THEME.panelBg)
        surface.SetDrawColor(THEME.border)
        surface.DrawOutlinedRect(0, 0, w, h)

        -- Radar grid lines
        surface.SetDrawColor(THEME.grid)
        local cx, cy = w / 2, h / 2
        for r = 30, math.min(w, h) / 2 - 10, 30 do
            surface.DrawOutlinedRect(cx - r, cy - r, r * 2, r * 2)
        end
        surface.DrawLine(cx, 10, cx, h - 10)
        surface.DrawLine(10, cy, w - 10, cy)

        -- Heading arrow
        draw.SimpleText("^ FRONT (NORTH)", "DermaDefaultBold", cx, 8, THEME.textDim, TEXT_ALIGN_CENTER)

        -- Vehicle chassis silhouette
        local carW = 70
        local carH = 170
        local carX = cx - carW / 2
        local carY = cy - carH / 2

        -- Shadow & body
        draw.RoundedBox(8, carX, carY, carW, carH, Color(35, 40, 50, 255))
        draw.RoundedBox(4, carX + 6, carY + 35, carW - 12, 60, Color(22, 25, 32, 255)) -- Cabin
        surface.SetDrawColor(THEME.accentDark)
        surface.DrawOutlinedRect(carX, carY, carW, carH)

        -- Wheels (4 corners)
        local function drawWheel(wx, wy)
            draw.RoundedBox(2, wx, wy, 10, 24, Color(15, 15, 18, 255))
            surface.SetDrawColor(60, 65, 75)
            surface.DrawOutlinedRect(wx, wy, 10, 24)
        end
        drawWheel(carX - 8, carY + 15)           -- FL
        drawWheel(carX + carW - 2, carY + 15)   -- FR
        drawWheel(carX - 8, carY + carH - 35)   -- RL
        drawWheel(carX + carW - 2, carY + carH - 35) -- RR

        -- Fetch ConVar offsets & groups
        local spreadOff = GetConVar("tiv_spike_spread_offset") and GetConVar("tiv_spike_spread_offset"):GetFloat() or 0
        local lengthOff = GetConVar("tiv_spike_length_offset") and GetConVar("tiv_spike_length_offset"):GetFloat() or 0
        local groupFront = GetConVar("tiv_spike_group_front") and GetConVar("tiv_spike_group_front"):GetBool() ~= false
        local groupMid   = GetConVar("tiv_spike_group_mid")   and GetConVar("tiv_spike_group_mid"):GetBool() ~= false
        local groupRear  = GetConVar("tiv_spike_group_rear")  and GetConVar("tiv_spike_group_rear"):GetBool() ~= false
        local spikeCount = GetConVar("tiv_spike_count") and GetConVar("tiv_spike_count"):GetInt() or 6

        -- Spike definitions
        local spikes = {
            { id = 1, name = "FR", group = "front", enabled = groupFront, x =  25 + spreadOff, y =  50 + lengthOff },
            { id = 2, name = "FL", group = "front", enabled = groupFront, x = -25 - spreadOff, y =  50 + lengthOff },
            { id = 3, name = "MR", group = "mid",   enabled = groupMid,   x =  30 + spreadOff, y = -20 + lengthOff },
            { id = 4, name = "ML", group = "mid",   enabled = groupMid,   x = -30 - spreadOff, y = -20 + lengthOff },
            { id = 5, name = "RR", group = "rear",  enabled = groupRear,  x =  20 + spreadOff, y = -95 + lengthOff },
            { id = 6, name = "RL", group = "rear",  enabled = groupRear,  x = -20 - spreadOff, y = -95 + lengthOff },
        }

        local scale = 0.9
        for _, spk in ipairs(spikes) do
            if spk.id <= spikeCount then
                local sx = cx + (spk.x * scale)
                local sy = cy - (spk.y * scale) -- Invert Y because +Y is forward

                local active = spk.enabled
                local spkColor = active and THEME.success or THEME.danger
                local glowSize = active and 10 or 8

                -- Pulse effect if active
                if active then
                    local pulse = math.abs(math.sin(CurTime() * 3)) * 4
                    surface.SetDrawColor(spkColor.r, spkColor.g, spkColor.b, 60)
                    surface.DrawOutlinedRect(sx - glowSize - pulse / 2, sy - glowSize - pulse / 2, (glowSize + pulse / 2) * 2, (glowSize + pulse / 2) * 2)
                end

                draw.RoundedBox(4, sx - 8, sy - 8, 16, 16, spkColor)
                draw.SimpleText(spk.name, "DermaDefaultBold", sx, sy, Color(0, 0, 0, 230), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            end
        end

        -- Legend at bottom
        local ly = h - 22
        draw.RoundedBox(2, 15, ly, 8, 8, THEME.success)
        draw.SimpleText("Active Anchor", "DermaDefault", 28, ly - 1, THEME.textDim)
        draw.RoundedBox(2, 115, ly, 8, 8, THEME.danger)
        draw.SimpleText("Disabled", "DermaDefault", 128, ly - 1, THEME.textDim)
        draw.SimpleText("Wheelbase Center", "DermaDefault", w - 15, ly - 1, THEME.textMuted, TEXT_ALIGN_RIGHT)
    end

    return pnl
end

-- ============================================================================
-- SPAWNMENU TOOL MENU TABS (UTILITIES -> TIV)
-- ============================================================================
hook.Add("PopulateToolMenu", "TIV_PopulateFullSettingsMenu", function()

    -- ------------------------------------------------------------------------
    -- 0. 3D CUSTOMIZER TAB
    -- ------------------------------------------------------------------------
    spawnmenu.AddToolMenuOption("Utilities", "TIV", "TIV_Menu_Customizer", "3D Vehicle Customizer", "", "", function(panel)
        panel:ClearControls()

        local title = panel:Help("3D Interceptor Customizer")
        title:SetFont("DermaDefaultBold")
        panel:Help("Visually configure armor plates, front deflector cowls, and ground anchor spikes in full 3D. Positions and angles are calculated strictly in vehicle-local coordinates.")

        local editBtn = vgui.Create("DButton", panel)
        editBtn:SetText("OPEN 3D INTERCEPTOR EDITOR")
        editBtn:SetTall(40)
        editBtn:SetTextColor(Color(255, 255, 255))
        editBtn.Paint = function(self, w, h)
            draw.RoundedBox(6, 0, 0, w, h, self:IsHovered() and Color(240, 170, 30) or Color(200, 130, 20))
        end
        editBtn.DoClick = function()
            if TIV.Editor3D and TIV.Editor3D.Open then
                TIV.Editor3D.Open()
            end
        end
        panel:AddItem(editBtn)

        local copyBtn = vgui.Create("DButton", panel)
        copyBtn:SetText("COPY ACTIVE CONFIGURATION")
        copyBtn:SetTall(32)
        copyBtn:SetTextColor(Color(255, 255, 255))
        copyBtn.Paint = function(self, w, h)
            draw.RoundedBox(4, 0, 0, w, h, self:IsHovered() and Color(35, 140, 95) or Color(28, 105, 75))
        end
        copyBtn.DoClick = function()
            local cfg = (TIV.Editor3D and TIV.Editor3D.LoadConfigFromFile) and TIV.Editor3D.LoadConfigFromFile()
                or TIV.CustomConfig.GetDefaultConfig("models/buggy.mdl")
            local luaCode = TIV.CustomConfig.SerializeToLua(cfg)
            SetClipboardText(luaCode)
            Derma_Message("Vehicle configuration copied to clipboard in AI-friendly Lua format!", "Configuration Export", "OK")
        end
        panel:AddItem(copyBtn)

        local tagBtn = vgui.Create("DButton", panel)
        tagBtn:SetText("TAG AIMED ENTITY AS INTERCEPTOR")
        tagBtn:SetTall(32)
        tagBtn:SetTextColor(Color(255, 255, 255))
        tagBtn.Paint = function(self, w, h)
            draw.RoundedBox(4, 0, 0, w, h, self:IsHovered() and Color(180, 110, 30) or Color(140, 80, 20))
        end
        tagBtn.DoClick = function()
            net.Start("TIV_TagAimedInterceptor")
            net.SendToServer()
        end
        panel:AddItem(tagBtn)

        panel:Help("Switch models in the 3D editor to create and save distinct configurations for Buggy, Jalopy, APC, Airboat, or custom vehicles/entities.")
        panel:Help("Coordinate Orientation: Forward (+Y), Right (+X), Up (+Z).")
    end)

    -- ------------------------------------------------------------------------
    -- 0B. PROGRESSION & UPGRADES TAB
    -- ------------------------------------------------------------------------
    spawnmenu.AddToolMenuOption("Utilities", "TIV", "TIV_Menu_Progression", "Progression & Upgrades", "", "", function(panel)
        panel:ClearControls()

        local title = panel:Help("Interceptor Career & Upgrades")
        title:SetFont("DermaDefaultBold")
        panel:Help("Earn Intercept points by anchoring in severe storm winds (>= 70 MPH) and surviving violent tornado vortex cores.")

        local shopBtn = vgui.Create("DButton", panel)
        shopBtn:SetText("OPEN UPGRADE TREE")
        shopBtn:SetTall(40)
        shopBtn:SetTextColor(Color(255, 255, 255))
        shopBtn.Paint = function(self, w, h)
            draw.RoundedBox(6, 0, 0, w, h, self:IsHovered() and THEME.accent or THEME.accentDark)
        end
        shopBtn.DoClick = function()
            if TIV.Progression and TIV.Progression.OpenUpgradeMenu then
                TIV.Progression.OpenUpgradeMenu()
            end
        end
        panel:AddItem(shopBtn)

        local pPts = TIV.Progression and (TIV.Progression.Points or TIV.Progression.CurrentIntercepts) or 0
        local pInt = TIV.Progression and (TIV.Progression.Intercepts or TIV.Progression.TotalIntercepts) or 0
        panel:Help(string.format("Spendable Points: %d pts  |  Total Intercepts: %d", pPts, pInt))
    end)

    -- ------------------------------------------------------------------------
    -- 1. PRESETS TAB
    -- ------------------------------------------------------------------------
    spawnmenu.AddToolMenuOption("Utilities", "TIV", "TIV_Menu_Presets", "Presets & Profiles", "", "", function(panel)
        panel:ClearControls()

        local title = panel:Help("Quick Intercept Profiles")
        title:SetFont("DermaDefaultBold")
        panel:Help("Instantly configure all vehicle, anchor, and safety settings for different storm conditions and playstyles with one click.")

        -- Master Console Launcher Button
        local launchBtn = vgui.Create("DButton", panel)
        launchBtn:SetText("OPEN FULL TIV MASTER CONSOLE")
        launchBtn:SetTall(36)
        launchBtn:SetTextColor(Color(255, 255, 255))
        launchBtn.Paint = function(self, w, h)
            draw.RoundedBox(6, 0, 0, w, h, self:IsHovered() and THEME.accent or THEME.accentDark)
        end
        launchBtn.DoClick = function()
            RunConsoleCommand("tiv_menu")
        end
        panel:AddItem(launchBtn)

        panel:Help("Available Storm Profiles:")

        for _, preset in ipairs(PRESETS) do
            local card = vgui.Create("DPanel", panel)
            card:SetTall(75)
            card.Paint = function(self, w, h)
                draw.RoundedBox(6, 0, 0, w, h, THEME.panelBg)
                surface.SetDrawColor(preset.color)
                surface.DrawRect(0, 0, 4, h)
                surface.SetDrawColor(THEME.border)
                surface.DrawOutlinedRect(0, 0, w, h)
            end

            local applyBtn = vgui.Create("DButton", card)
            applyBtn:SetWide(75)
            applyBtn:Dock(RIGHT)
            applyBtn:DockMargin(6, 20, 10, 20)
            applyBtn:SetText("APPLY")
            applyBtn:SetTextColor(Color(255, 255, 255))
            applyBtn.Paint = function(self, w, h)
                draw.RoundedBox(4, 0, 0, w, h, self:IsHovered() and THEME.accent or Color(45, 50, 60))
            end
            applyBtn.DoClick = function()
                TIV.Menu.ApplyPreset(preset)
            end

            local textPanel = vgui.Create("DPanel", card)
            textPanel:Dock(FILL)
            textPanel:DockMargin(12, 6, 6, 6)
            textPanel.Paint = function() end

            local nameLbl = vgui.Create("DLabel", textPanel)
            nameLbl:Dock(TOP)
            nameLbl:SetTall(20)
            nameLbl:SetFont("DermaDefaultBold")
            nameLbl:SetTextColor(preset.color)
            nameLbl:SetText(preset.name)

            local descLbl = vgui.Create("DLabel", textPanel)
            descLbl:Dock(FILL)
            descLbl:SetFont("DermaDefault")
            descLbl:SetTextColor(THEME.textDim)
            descLbl:SetWrap(true)
            descLbl:SetText(preset.desc)

            panel:AddItem(card)
        end
    end)

    -- ------------------------------------------------------------------------
    -- 2. SPIKES & RADAR TAB
    -- ------------------------------------------------------------------------
    spawnmenu.AddToolMenuOption("Utilities", "TIV", "TIV_Menu_Spikes", "Spikes & Positions", "", "", function(panel)
        panel:ClearControls()

        local title = panel:Help("Spike Layout & Anchor Radar")
        title:SetFont("DermaDefaultBold")
        panel:Help("Fine-tune the count, spread, length, and ground drive depth of vehicle anchor spikes. Changes apply automatically to subsequent deploys.")

        -- 2D Schematic Radar
        local visualizer = TIV.Menu.CreateSpikeVisualizer(panel, 310, 270)
        panel:AddItem(visualizer)

        panel:Help("Anchor Spike Configuration:")
        panel:NumSlider("Installed Spikes", "tiv_spike_count", 0, 6, 0)
            :SetTooltip("Total number of spikes attached to the vehicle chassis (0 to 6).")

        panel:CheckBox("Hide Spike Models", "tiv_hide_spikes")
            :SetTooltip("Hides spike physical models while retaining full ground anchoring functionality.")

        panel:Help("Independent Pair Enable/Disable:")
        panel:CheckBox("Enable Front Spikes (FR, FL)", "tiv_spike_group_front")
        panel:CheckBox("Enable Mid Spikes (MR, ML)", "tiv_spike_group_mid")
        panel:CheckBox("Enable Rear Spikes (RR, RL)", "tiv_spike_group_rear")

        panel:Help("Spike Position Calibration:")
        panel:NumSlider("Lateral Spread Offset", "tiv_spike_spread_offset", -25, 25, 0)
            :SetTooltip("Adjusts lateral spacing of spikes outward or inward across the vehicle track.")

        panel:NumSlider("Wheelbase Length Offset", "tiv_spike_length_offset", -40, 40, 0)
            :SetTooltip("Shifts spike positions forward or rearward along the vehicle wheelbase.")

        panel:NumSlider("Ground Drive Depth", "tiv_spike_drive_depth", 5, 50, 0)
            :SetTooltip("Depth in Hammer units that hydraulic spikes penetrate below the surface.")
    end)

    -- ------------------------------------------------------------------------
    -- 3. SUSPENSION & HYDRAULICS TAB
    -- ------------------------------------------------------------------------
    spawnmenu.AddToolMenuOption("Utilities", "TIV", "TIV_Menu_Suspension", "Suspension & Deploy", "", "", function(panel)
        panel:ClearControls()

        local title = panel:Help("Suspension & Hydraulic Tuning")
        title:SetFont("DermaDefaultBold")
        panel:Help("Controls how the vehicle lowers its chassis, handles emergency handbrakes, and speeds up hydraulic deployment.")

        panel:Help("Suspension Travel Limiter:")
        panel:NumSlider("Lowering Limit (0=Auto)", "tiv_suspension_limit", 0, 15, 1)
            :SetTooltip("Distance in units the chassis lowers. Set to 0 to automatically compute the vehicle's exact suspension compression limit so tires never clip the ground.")

        panel:Help("Hydraulic Speed & Timing:")
        panel:NumSlider("Deployment Speed", "tiv_deploy_speed", 0.5, 3.0, 1)
            :SetTooltip("Speed multiplier for hydraulic lowering and raising sequence.")

        panel:CheckBox("Lock Handbrake On Anchor", "tiv_deploy_handbrake")
            :SetTooltip("Automatically locks vehicle handbrake when anchored, and releases when raising.")

        panel:Help("Storm Auto-Deployment:")
        panel:NumSlider("Auto-Deploy Wind (MPH)", "tiv_auto_deploy_wind", 0, 250, 0)
            :SetTooltip("Automatically triggers intercept deployment when wind reaches this speed while stopped (0 = disabled).")

        panel:Help("Manual Test Controls:")
        local deployBtn = panel:Button("Toggle Deploy / Retract (Current Vehicle)", "")
        deployBtn.DoClick = function()
            local ply = LocalPlayer()
            if IsValid(ply) and ply:InVehicle() then
                RunConsoleCommand("tiv_toggle")
            else
                notification.AddLegacy("[TIV] Enter a supported vehicle first!", NOTIFY_ERROR, 3)
            end
        end
    end)

    -- ------------------------------------------------------------------------
    -- 4. TORNADO & WIND PHYSICS TAB
    -- ------------------------------------------------------------------------
    spawnmenu.AddToolMenuOption("Utilities", "TIV", "TIV_Menu_Physics", "Storm & Wind Physics", "", "", function(panel)
        panel:ClearControls()

        local title = panel:Help("Tornado Intercept Physics")
        title:SetFont("DermaDefaultBold")
        panel:Help("Tuning parameters for anchor strength, storm loft thresholds, and aerodynamic drag coupling.")

        panel:Help("Anchor Failure & Loft:")
        panel:NumSlider("Loft Threshold (MPH)", "tiv_loft_wind_threshold", 50, 350, 0)
            :SetTooltip("Wind speed where vehicle anchor holds fail and tornado lofting begins.")

        panel:NumSlider("Spike Force Limit", "tiv_spike_force", 0, 200000, 0)
            :SetTooltip("Braking force limit on anchor ball-sockets. 0 = Unbreakable by lateral wind force.")

        panel:CheckBox("Release Spikes On Loft", "tiv_loft_release_spikes")
            :SetTooltip("Violently tears spikes loose as free-flying physics props when lofted.")

        panel:Help("Weather Mod Compatibility Guards:")
        panel:CheckBox("Compatibility Mode", "tiv_compat_mode")
            :SetTooltip("Enables multi-addon safety guards for GStorms, XTwisters 3, and custom tornado mods.")

        panel:NumSlider("Compat Anchored Wind Scale", "tiv_compat_anchored_wind_scale", 0.1, 1.0, 2)
            :SetTooltip("Scales lateral wind force exerted on the vehicle while firmly anchored.")

        panel:NumSlider("Compat Max Linear Vel", "tiv_compat_max_deploy_linear", 50, 5000, 0)
        panel:NumSlider("Compat Max Angular Vel", "tiv_compat_max_deploy_angular", 20, 4000, 0)
        panel:NumSlider("Compat Recovery Cooldown (s)", "tiv_compat_recovery_cooldown", 0, 30, 1)

        panel:Help("Wind Simulation Test Buttons:")
        local windSpeeds = {
            { "Calm (0 MPH)", 0 },
            { "EF1 Storm (90 MPH)", 90 },
            { "EF2 Gale (125 MPH)", 125 },
            { "EF3 Severe (150 MPH)", 150 },
            { "EF4 Violent (185 MPH)", 185 },
            { "EF5 Extreme (260 MPH)", 260 },
        }
        for _, ws in ipairs(windSpeeds) do
            local btn = panel:Button(ws[1], "")
            btn.DoClick = function()
                RunConsoleCommand("tiv_wind_set", tostring(ws[2]))
            end
        end

        local clearBtn = panel:Button("Clear Manual Wind (Resume Auto Weather)", "")
        clearBtn.DoClick = function()
            RunConsoleCommand("tiv_wind_clear")
        end
    end)

    -- ------------------------------------------------------------------------
    -- 5. HUD & INSTRUMENT COCKPIT TAB
    -- ------------------------------------------------------------------------
    spawnmenu.AddToolMenuOption("Utilities", "TIV", "TIV_Menu_HUD", "HUD & Cockpit", "", "", function(panel)
        panel:ClearControls()

        local title = panel:Help("Cockpit HUD & Telemetry")
        title:SetFont("DermaDefaultBold")
        panel:Help("Customize the instrument display shown when piloting a Tornado Intercept Vehicle.")

        panel:CheckBox("Enable Cockpit HUD", "tiv_hud_enabled")
            :SetTooltip("Toggles the cockpit instrument display on or off.")

        panel:Help("Display Units:")
        local unitBox = panel:ComboBox("Speed & Wind Unit", "tiv_hud_unit")
        unitBox:AddChoice("Miles Per Hour (MPH)", "mph")
        unitBox:AddChoice("Kilometers Per Hour (KM/H)", "kmh")
        unitBox:AddChoice("Knots (KTS)", "knots")

        panel:Help("Screen Corner Position:")
        local posBox = panel:ComboBox("HUD Position", "tiv_hud_position")
        posBox:AddChoice("Bottom Right (Default)", "0")
        posBox:AddChoice("Bottom Left", "1")
        posBox:AddChoice("Top Right", "2")
        posBox:AddChoice("Top Left", "3")

        panel:Help("HUD Scale Factor:")
        panel:NumSlider("HUD Size Scale", "tiv_hud_scale", 0.75, 1.5, 2)
            :SetTooltip("Scales the size of the cockpit instrument cluster.")
    end)

    -- ------------------------------------------------------------------------
    -- 6. WIREMOD & AUTOMATION TAB
    -- ------------------------------------------------------------------------
    spawnmenu.AddToolMenuOption("Utilities", "TIV", "TIV_Menu_Wiremod", "Wiremod & E2", "", "", function(panel)
        panel:ClearControls()

        local title = panel:Help("Wiremod & Expression 2")
        title:SetFont("DermaDefaultBold")
        panel:Help("Integrate your interceptor with Wiremod chips, gates, digital screens, and E2 automation.")

        panel:CheckBox("Auto-attach Wire Controller", "tiv_wire_auto_controller")
            :SetTooltip("Automatically attaches a Wiremod controller entity to spawned TIVs.")

        panel:CheckBox("Hide Wire Controller Model", "tiv_wire_hide_controller")
            :SetTooltip("Hides the physical model of the auto-attached Wire controller.")

        panel:Help("Wire Input Ports:")
        panel:ControlHelp("- Deploy (NORMAL): Triggers deploy sequence (1 = deploy).\n- Retract (NORMAL): Triggers retract sequence (1 = retract).\n- ToggleDeploy (NORMAL): Toggles deploy/retract on pulse.\n- EmergencyStop (NORMAL): Aborts deployment immediately.\n- Reset (NORMAL): Emergency resets faulted systems.\n- Handbrake (NORMAL): Manual override for parking brake.")

        panel:Help("Wire Output Telemetry:")
        panel:ControlHelp("- State (STRING): idle, lowering, deploying_spikes, anchored, etc.\n- IsDeployed (NORMAL): 1 when anchored, 0 otherwise.\n- WindSpeed (NORMAL): Real-time storm wind at vehicle in MPH.\n- WindDirection (VECTOR): Unit direction vector of the wind.\n- Stress (NORMAL): Wind stress ratio on anchors (0.0 to 1.0).\n- ActiveSpikes (NORMAL): Number of intact deployed spikes.\n- AnchorIntegrity (NORMAL): 1 if holding, 0 if compromised.")

        panel:Help("Expression 2 Functions:")
        panel:ControlHelp("- E:isTIV() -> number\n- E:tivState() -> string\n- E:tivWindSpeed() -> number\n- E:tivStress() -> number\n- E:tivDeploy() -> number\n- E:tivRetract() -> number\n- E:tivToggle() -> number")
    end)

    -- ------------------------------------------------------------------------
    -- 7. FIELD MANUAL & GUIDES TAB
    -- ------------------------------------------------------------------------
    spawnmenu.AddToolMenuOption("Utilities", "TIV", "TIV_Menu_Guide", "Field Manual & Guide", "", "", function(panel)
        panel:ClearControls()

        local title = panel:Help("Storm Chaser Field Manual")
        title:SetFont("DermaDefaultBold")

        panel:Help("Phase 1: Approach & Positioning")
        panel:ControlHelp("1. Track tornado trajectory via wind direction vector or radar.\n2. Drive into the expected path of the tornado.\n3. Bring vehicle to a COMPLETE STOP (< 5 MPH).\n4. Orient vehicle nose facing directly into oncoming wind for minimal drag.")

        panel:Help("Phase 2: Deployment")
        panel:ControlHelp("1. Press [B] or trigger Wire 'Deploy' input.\n2. Hydraulic suspension lowers chassis flush to the ground limit.\n3. Steel anchor spikes drive into the terrain.\n4. Dual-stage ballsocket constraints anchor vehicle to the world.")

        panel:Help("Phase 3: Interception")
        panel:ControlHelp("1. Monitor HUD wind speed and Anchor Stress bar.\n2. Normal stress is below 70% (Green to Amber).\n3. If stress exceeds 70%, the warning light pulses.\n4. If wind exceeds Loft Threshold, anchors can shear!")

        panel:Help("Phase 4: Retraction & Relocation")
        panel:ControlHelp("1. Once vortex passes, press [B] or trigger Wire 'Retract'.\n2. Spikes retract smoothly from the terrain.\n3. Suspension re-pressurizes to ride height.\n4. Handbrake disengages automatically.")

        panel:Help("Enhanced Fujita (EF) Scale Reference:")
        local efCard = vgui.Create("DPanel", panel)
        efCard:SetTall(155)
        efCard.Paint = function(self, w, h)
            draw.RoundedBox(6, 0, 0, w, h, THEME.panelBg)
            surface.SetDrawColor(THEME.border)
            surface.DrawOutlinedRect(0, 0, w, h)

            local rows = {
                { "EF0", "65-85 MPH",   "Light damage",     "0-20% Stress", Color(100, 220, 100) },
                { "EF1", "86-110 MPH",  "Moderate damage",  "20-40% Stress", Color(180, 220, 50) },
                { "EF2", "111-135 MPH", "Considerable",     "40-60% Stress", Color(240, 200, 40) },
                { "EF3", "136-165 MPH", "Severe damage",    "60-80% Stress", Color(240, 130, 30) },
                { "EF4", "166-200 MPH", "Devastating",      "80-95% Stress", Color(240, 60, 40) },
                { "EF5", "200+ MPH",    "Total destruction","CRITICAL STRAIN", Color(220, 20, 60) },
            }

            local y = 6
            for _, r in ipairs(rows) do
                draw.SimpleText(r[1], "DermaDefaultBold", 10, y, r[5])
                draw.SimpleText(r[2], "DermaDefault", 50, y, THEME.text)
                draw.SimpleText(r[3], "DermaDefault", 145, y, THEME.textDim)
                draw.SimpleText(r[4], "DermaDefaultBold", w - 10, y, r[5], TEXT_ALIGN_RIGHT)
                y = y + 24
            end
        end
        panel:AddItem(efCard)

        panel:Help("Troubleshooting FAQ:")
        panel:ControlHelp("Q: Vehicle won't deploy?\nA: Vehicle must be almost stopped (< 15 MPH) and on solid ground.\n\nQ: Do spikes damage the vehicle?\nA: No, all spikes and constraints are collision-filtered.\n\nQ: Can spikes snap?\nA: Yes, if Spike Force Limit is non-zero and lateral storm force exceeds the limit.")
    end)

    -- ------------------------------------------------------------------------
    -- 8. CHEATS & DEV SANDBOX TAB
    -- ------------------------------------------------------------------------
    spawnmenu.AddToolMenuOption("Utilities", "TIV", "TIV_Menu_Cheats", "Cheats & Dev Sandbox", "", "", function(panel)
        panel:ClearControls()

        panel:Help("TIV Sandbox & Cheat Controls:")
        panel:ControlHelp("Use these controls in sandbox or singleplayer to test extreme intercepts, record cinematic sequences, or instantly unlock all upgrades.")

        panel:CheckBox("Godmode Anchors (Immune to violent lofting)", "tiv_cheat_godmode_anchors")
        panel:ControlHelp("When enabled, hydraulic spikes and anchors will never snap or fail under any tornado wind speed.")

        local unlockBtn = vgui.Create("DButton", panel)
        unlockBtn:SetText("UNLOCK ALL UPGRADES")
        unlockBtn:SetTall(34)
        unlockBtn:SetTextColor(Color(255, 255, 255))
        unlockBtn.Paint = function(s, w, h)
            draw.RoundedBox(4, 0, 0, w, h, s:IsHovered() and Color(240, 160, 30) or Color(190, 120, 20))
        end
        unlockBtn.DoClick = function()
            if TIV.Progression and TIV.Progression.RequestCheat then
                TIV.Progression.RequestCheat("unlock_all")
            else
                RunConsoleCommand("tiv_unlock_all")
            end
            surface.PlaySound("buttons/button14.wav")
            notification.AddLegacy("[TIV Sandbox] All vehicle upgrades unlocked!", NOTIFY_GENERIC, 3)
        end
        panel:AddItem(unlockBtn)

        panel:Help("Grant Intercept Points:")
        local pnlPts = vgui.Create("DPanel", panel)
        pnlPts:SetTall(34)
        pnlPts.Paint = function() end

        local btn50 = vgui.Create("DButton", pnlPts)
        btn50:Dock(LEFT)
        btn50:SetWide(80)
        btn50:SetText("+50 PTS")
        btn50.DoClick = function()
            if TIV.Progression and TIV.Progression.RequestCheat then
                TIV.Progression.RequestCheat("add_points", 50)
            end
            surface.PlaySound("garrysmod/save_load1.wav")
        end

        local btn200 = vgui.Create("DButton", pnlPts)
        btn200:Dock(LEFT)
        btn200:DockMargin(8, 0, 0, 0)
        btn200:SetWide(80)
        btn200:SetText("+200 PTS")
        btn200.DoClick = function()
            if TIV.Progression and TIV.Progression.RequestCheat then
                TIV.Progression.RequestCheat("add_points", 200)
            end
            surface.PlaySound("garrysmod/save_load1.wav")
        end

        local btn1000 = vgui.Create("DButton", pnlPts)
        btn1000:Dock(LEFT)
        btn1000:DockMargin(8, 0, 0, 0)
        btn1000:SetWide(90)
        btn1000:SetText("+1000 PTS")
        btn1000.DoClick = function()
            if TIV.Progression and TIV.Progression.RequestCheat then
                TIV.Progression.RequestCheat("add_points", 1000)
            end
            surface.PlaySound("garrysmod/save_load1.wav")
        end

        panel:AddItem(pnlPts)

        local resetBtn = vgui.Create("DButton", panel)
        resetBtn:SetText("RESET PROGRESSION PROFILE")
        resetBtn:SetTall(28)
        resetBtn:SetTextColor(Color(255, 140, 140))
        resetBtn.Paint = function(s, w, h)
            draw.RoundedBox(4, 0, 0, w, h, s:IsHovered() and Color(140, 40, 40) or Color(60, 25, 25))
        end
        resetBtn.DoClick = function()
            Derma_Query("Are you sure you want to reset your TIV progression points and unlocked upgrades back to zero?", "Reset Progression", "Yes", function()
                if TIV.Progression and TIV.Progression.RequestCheat then
                    TIV.Progression.RequestCheat("reset")
                end
                surface.PlaySound("buttons/button19.wav")
            end, "No", function() end)
        end
        panel:AddItem(resetBtn)
    end)
end)

-- ============================================================================
-- STANDALONE MASTER CONSOLE WINDOW (`tiv_menu` / `tiv_settings`)
-- ============================================================================
function TIV.Menu.OpenMasterConsole()
    if IsValid(TIV.Menu.Frame) then
        TIV.Menu.Frame:Close()
    end

    local w, h = 880, 600
    local frame = vgui.Create("DFrame")
    frame:SetSize(w, h)
    frame:Center()
    frame:SetTitle("")
    frame:MakePopup()
    frame:SetDraggable(true)
    frame:SetSizable(false)
    frame:ShowCloseButton(false)

    frame.Paint = function(self, fw, fh)
        -- Window background
        draw.RoundedBox(8, 0, 0, fw, fh, THEME.bg)

        -- Header bar
        draw.RoundedBoxEx(8, 0, 0, fw, 50, THEME.headerBg, true, true, false, false)
        surface.SetDrawColor(THEME.accent)
        surface.DrawRect(0, 48, fw, 2)

        -- Title & Subtitle
        draw.SimpleText("TIV-2 COMMAND CONSOLE", "DermaDefaultBold", 20, 12, THEME.text)
        draw.SimpleText("ADVANCED TORNADO INTERCEPT SYSTEMS & FIELD TELEMETRY", "DermaDefault", 20, 28, THEME.accent)

        -- Outer border
        surface.SetDrawColor(THEME.border)
        surface.DrawOutlinedRect(0, 0, fw, fh)
    end

    -- Close Button
    local closeBtn = vgui.Create("DButton", frame)
    closeBtn:SetPos(w - 42, 10)
    closeBtn:SetSize(32, 30)
    closeBtn:SetText("X")
    closeBtn:SetFont("DermaDefaultBold")
    closeBtn:SetTextColor(THEME.textDim)
    closeBtn.Paint = function(self, bw, bh)
        draw.RoundedBox(4, 0, 0, bw, bh, self:IsHovered() and THEME.danger or Color(35, 40, 50))
    end
    closeBtn.DoClick = function()
        frame:Close()
    end

    -- Sidebar for tab navigation
    local sidebarW = 200
    local sidebar = vgui.Create("DPanel", frame)
    sidebar:SetPos(0, 50)
    sidebar:SetSize(sidebarW, h - 50)
    sidebar.Paint = function(self, sw, sh)
        draw.RoundedBoxEx(0, 0, 0, sw, sh, THEME.headerBg, false, false, true, false)
        surface.SetDrawColor(THEME.border)
        surface.DrawLine(sw - 1, 0, sw - 1, sh)
    end

    -- Content container
    local contentArea = vgui.Create("DPanel", frame)
    contentArea:SetPos(sidebarW, 50)
    contentArea:SetSize(w - sidebarW, h - 50)
    contentArea.Paint = function(self, cw, ch)
        draw.RoundedBoxEx(0, 0, 0, cw, ch, THEME.bg, false, false, false, true)
    end

    local currentPanel = nil
    local function SwitchTab(tabFunc)
        if IsValid(currentPanel) then
            currentPanel:Remove()
        end
        currentPanel = tabFunc(contentArea)
        currentPanel:Dock(FILL)
        currentPanel:DockMargin(15, 15, 15, 15)
    end

    local tabButtons = {}
    local function AddSidebarTab(label, tabFunc)
        local btn = vgui.Create("DButton", sidebar)
        btn:SetTall(42)
        btn:Dock(TOP)
        btn:DockMargin(8, 6, 8, 0)
        btn:SetText("  " .. label)
        btn:SetFont("DermaDefaultBold")
        btn:SetContentAlignment(4)
        btn:SetTextColor(THEME.textDim)

        btn.Paint = function(self, bw, bh)
            local active = (btn.IsActive == true)
            local col = active and THEME.accentDark or (self:IsHovered() and Color(35, 40, 50) or Color(0, 0, 0, 0))
            draw.RoundedBox(6, 0, 0, bw, bh, col)
            if active then
                surface.SetDrawColor(THEME.accent)
                surface.DrawRect(0, 4, 3, bh - 8)
            end
        end

        btn.DoClick = function()
            for _, b in ipairs(tabButtons) do
                b.IsActive = false
                b:SetTextColor(THEME.textDim)
            end
            btn.IsActive = true
            btn:SetTextColor(Color(255, 255, 255))
            SwitchTab(tabFunc)
        end

        table.insert(tabButtons, btn)
        return btn
    end

    -- ========================================================================
    -- TAB 1: PRESETS
    -- ========================================================================
    local function BuildPresetsTab(parent)
        local pnl = vgui.Create("DScrollPanel", parent)

        local title = vgui.Create("DLabel", pnl)
        title:SetFont("DermaLarge")
        title:SetTextColor(THEME.text)
        title:SetText("Quick Intercept Presets")
        title:Dock(TOP)
        title:DockMargin(0, 0, 0, 5)

        local sub = vgui.Create("DLabel", pnl)
        sub:SetFont("DermaDefault")
        sub:SetTextColor(THEME.textDim)
        sub:SetText("Select an optimized operational configuration to instantly apply to your vehicle.")
        sub:Dock(TOP)
        sub:DockMargin(0, 0, 0, 15)

        for _, preset in ipairs(PRESETS) do
            local card = vgui.Create("DPanel", pnl)
            card:SetTall(80)
            card:Dock(TOP)
            card:DockMargin(0, 0, 0, 10)

            card.Paint = function(self, cw, ch)
                draw.RoundedBox(6, 0, 0, cw, ch, THEME.panelBg)
                surface.SetDrawColor(preset.color)
                surface.DrawRect(0, 0, 5, ch)
                surface.SetDrawColor(THEME.border)
                surface.DrawOutlinedRect(0, 0, cw, ch)
            end

            local applyBtn = vgui.Create("DButton", card)
            applyBtn:SetWide(115)
            applyBtn:Dock(RIGHT)
            applyBtn:DockMargin(10, 22, 14, 22)
            applyBtn:SetText("APPLY PRESET")
            applyBtn:SetFont("DermaDefaultBold")
            applyBtn:SetTextColor(Color(255, 255, 255))
            applyBtn.Paint = function(self, bw, bh)
                draw.RoundedBox(4, 0, 0, bw, bh, self:IsHovered() and THEME.accent or Color(45, 50, 62))
            end
            applyBtn.DoClick = function()
                TIV.Menu.ApplyPreset(preset)
            end

            local textPanel = vgui.Create("DPanel", card)
            textPanel:Dock(FILL)
            textPanel:DockMargin(16, 8, 8, 8)
            textPanel.Paint = function() end

            local nameLbl = vgui.Create("DLabel", textPanel)
            nameLbl:Dock(TOP)
            nameLbl:SetTall(22)
            nameLbl:SetFont("DermaDefaultBold")
            nameLbl:SetTextColor(preset.color)
            nameLbl:SetText(preset.name)

            local descLbl = vgui.Create("DLabel", textPanel)
            descLbl:Dock(FILL)
            descLbl:SetFont("DermaDefault")
            descLbl:SetTextColor(THEME.textDim)
            descLbl:SetWrap(true)
            descLbl:SetText(preset.desc)
        end

        return pnl
    end

    -- ========================================================================
    -- TAB 2: SPIKE SCHEMATIC & POSITIONING
    -- ========================================================================
    local function BuildSpikesTab(parent)
        local pnl = vgui.Create("DPanel", parent)
        pnl.Paint = function() end

        local left = vgui.Create("DPanel", pnl)
        left:SetWide(300)
        left:Dock(LEFT)
        left:DockMargin(0, 0, 15, 0)
        left.Paint = function() end

        local vis = TIV.Menu.CreateSpikeVisualizer(left, 300, 450)
        vis:Dock(FILL)

        local right = vgui.Create("DScrollPanel", pnl)
        right:Dock(FILL)

        local rTitle = vgui.Create("DLabel", right)
        rTitle:SetFont("DermaLarge")
        rTitle:SetTextColor(THEME.text)
        rTitle:SetText("Spike Tuning & Alignment")
        rTitle:Dock(TOP)
        rTitle:DockMargin(0, 0, 0, 10)

        local function addSlider(label, cvar, min, max, dec)
            local s = vgui.Create("DNumSlider", right)
            s:SetText(label)
            s:SetMin(min)
            s:SetMax(max)
            s:SetDecimals(dec)
            s:SetConVar(cvar)
            s:Dock(TOP)
            s:DockMargin(0, 5, 0, 5)
            s:SetDark(false)
            return s
        end

        local function addCheck(label, cvar)
            local cb = vgui.Create("DCheckBoxLabel", right)
            cb:SetText(label)
            cb:SetConVar(cvar)
            cb:Dock(TOP)
            cb:DockMargin(0, 6, 0, 6)
            cb:SetTextColor(THEME.text)
            return cb
        end

        addSlider("Installed Spikes (0-6)", "tiv_spike_count", 0, 6, 0)
        addCheck("Hide Physical Spike Models", "tiv_hide_spikes")

        local div1 = vgui.Create("DLabel", right)
        div1:SetFont("DermaDefaultBold")
        div1:SetTextColor(THEME.accent)
        div1:SetText("Anchor Group Pair Controls:")
        div1:Dock(TOP)
        div1:DockMargin(0, 12, 0, 4)

        addCheck("Enable Front Spike Pair (FR, FL)", "tiv_spike_group_front")
        addCheck("Enable Middle Spike Pair (MR, ML)", "tiv_spike_group_mid")
        addCheck("Enable Rear Spike Pair (RR, RL)", "tiv_spike_group_rear")

        local div2 = vgui.Create("DLabel", right)
        div2:SetFont("DermaDefaultBold")
        div2:SetTextColor(THEME.accent)
        div2:SetText("Coordinate Alignment:")
        div2:Dock(TOP)
        div2:DockMargin(0, 12, 0, 4)

        addSlider("Lateral Spread Offset", "tiv_spike_spread_offset", -25, 25, 0)
        addSlider("Wheelbase Length Offset", "tiv_spike_length_offset", -40, 40, 0)
        addSlider("Ground Penetration Depth", "tiv_spike_drive_depth", 5, 50, 0)

        return pnl
    end

    -- ========================================================================
    -- TAB 3: HYDRAULICS & SUSPENSION
    -- ========================================================================
    local function BuildSuspensionTab(parent)
        local pnl = vgui.Create("DScrollPanel", parent)

        local title = vgui.Create("DLabel", pnl)
        title:SetFont("DermaLarge")
        title:SetTextColor(THEME.text)
        title:SetText("Hydraulic Suspension & Deploy Controls")
        title:Dock(TOP)
        title:DockMargin(0, 0, 0, 15)

        local function addSlider(label, cvar, min, max, dec)
            local s = vgui.Create("DNumSlider", pnl)
            s:SetText(label)
            s:SetMin(min)
            s:SetMax(max)
            s:SetDecimals(dec)
            s:SetConVar(cvar)
            s:Dock(TOP)
            s:DockMargin(0, 6, 0, 6)
            s:SetDark(false)
            return s
        end

        local function addCheck(label, cvar)
            local cb = vgui.Create("DCheckBoxLabel", pnl)
            cb:SetText(label)
            cb:SetConVar(cvar)
            cb:Dock(TOP)
            cb:DockMargin(0, 6, 0, 6)
            cb:SetTextColor(THEME.text)
            return cb
        end

        addSlider("Suspension Lowering Limit (0 = Auto)", "tiv_suspension_limit", 0, 15, 1)
        addSlider("Hydraulic Deployment Speed", "tiv_deploy_speed", 0.5, 3.0, 1)
        addCheck("Lock Parking Handbrake When Anchored", "tiv_deploy_handbrake")
        addSlider("Auto-Deploy Wind Trigger (MPH, 0=Off)", "tiv_auto_deploy_wind", 0, 250, 0)

        local actionTitle = vgui.Create("DLabel", pnl)
        actionTitle:SetFont("DermaDefaultBold")
        actionTitle:SetTextColor(THEME.accent)
        actionTitle:SetText("Direct Vehicle Hydraulic Actions:")
        actionTitle:Dock(TOP)
        actionTitle:DockMargin(0, 20, 0, 8)

        local actBtn = vgui.Create("DButton", pnl)
        actBtn:SetTall(36)
        actBtn:Dock(TOP)
        actBtn:DockMargin(0, 0, 0, 8)
        actBtn:SetText("TOGGLE DEPLOY / RETRACT ON CURRENT VEHICLE")
        actBtn:SetFont("DermaDefaultBold")
        actBtn:SetTextColor(Color(255, 255, 255))
        actBtn.Paint = function(self, bw, bh)
            draw.RoundedBox(6, 0, 0, bw, bh, self:IsHovered() and THEME.accent or Color(45, 52, 65))
        end
        actBtn.DoClick = function()
            RunConsoleCommand("tiv_toggle")
        end

        return pnl
    end

    -- ========================================================================
    -- TAB 4: STORM & WIND SIMULATOR
    -- ========================================================================
    local function BuildWindTab(parent)
        local pnl = vgui.Create("DScrollPanel", parent)

        local title = vgui.Create("DLabel", pnl)
        title:SetFont("DermaLarge")
        title:SetTextColor(THEME.text)
        title:SetText("Storm & Tornado Wind Physics")
        title:Dock(TOP)
        title:DockMargin(0, 0, 0, 15)

        local function addSlider(label, cvar, min, max, dec)
            local s = vgui.Create("DNumSlider", pnl)
            s:SetText(label)
            s:SetMin(min)
            s:SetMax(max)
            s:SetDecimals(dec)
            s:SetConVar(cvar)
            s:Dock(TOP)
            s:DockMargin(0, 5, 0, 5)
            s:SetDark(false)
            return s
        end

        local function addCheck(label, cvar)
            local cb = vgui.Create("DCheckBoxLabel", pnl)
            cb:SetText(label)
            cb:SetConVar(cvar)
            cb:Dock(TOP)
            cb:DockMargin(0, 5, 0, 5)
            cb:SetTextColor(THEME.text)
            return cb
        end

        addSlider("Loft Threshold (MPH)", "tiv_loft_wind_threshold", 50, 350, 0)
        addSlider("Spike Force Limit (0=Unbreakable)", "tiv_spike_force", 0, 200000, 0)
        addCheck("Violently Release Spikes When Lofted", "tiv_loft_release_spikes")
        addCheck("Compatibility Mode (GStorms / XT2 / XT3)", "tiv_compat_mode")
        addSlider("Compat Anchored Wind Scale", "tiv_compat_anchored_wind_scale", 0.1, 1.0, 2)

        local simTitle = vgui.Create("DLabel", pnl)
        simTitle:SetFont("DermaDefaultBold")
        simTitle:SetTextColor(THEME.accent)
        simTitle:SetText("Interactive Wind Speed Simulator (Test Interceptor):")
        simTitle:Dock(TOP)
        simTitle:DockMargin(0, 18, 0, 8)

        local speeds = {
            { "Calm Weather (0 MPH)", 0 },
            { "EF0 Gale (75 MPH)", 75 },
            { "EF1 Storm (100 MPH)", 100 },
            { "EF2 Severe (125 MPH)", 125 },
            { "EF3 Violent (150 MPH)", 150 },
            { "EF4 Devastating (185 MPH)", 185 },
            { "EF5 Incredible (260 MPH)", 260 },
        }

        for _, sp in ipairs(speeds) do
            local btn = vgui.Create("DButton", pnl)
            btn:SetTall(28)
            btn:Dock(TOP)
            btn:DockMargin(0, 0, 0, 5)
            btn:SetText(sp[1])
            btn:SetTextColor(Color(255, 255, 255))
            btn.Paint = function(self, bw, bh)
                draw.RoundedBox(4, 0, 0, bw, bh, self:IsHovered() and THEME.accent or Color(38, 42, 52))
            end
            btn.DoClick = function()
                RunConsoleCommand("tiv_wind_set", tostring(sp[2]))
                notification.AddLegacy("[TIV] Set simulated wind to " .. sp[2] .. " MPH", NOTIFY_GENERIC, 3)
            end
        end

        local clearBtn = vgui.Create("DButton", pnl)
        clearBtn:SetTall(32)
        clearBtn:Dock(TOP)
        clearBtn:DockMargin(0, 8, 0, 8)
        clearBtn:SetText("RESET TO AUTO WEATHER (CLEAR OVERRIDE)")
        clearBtn:SetFont("DermaDefaultBold")
        clearBtn:SetTextColor(Color(255, 255, 255))
        clearBtn.Paint = function(self, bw, bh)
            draw.RoundedBox(4, 0, 0, bw, bh, self:IsHovered() and THEME.danger or Color(55, 35, 40))
        end
        clearBtn.DoClick = function()
            RunConsoleCommand("tiv_wind_clear")
            notification.AddLegacy("[TIV] Cleared manual wind override", NOTIFY_GENERIC, 3)
        end

        return pnl
    end

    -- ========================================================================
    -- TAB 5: HUD & COCKPIT
    -- ========================================================================
    local function BuildHUDTab(parent)
        local pnl = vgui.Create("DScrollPanel", parent)

        local title = vgui.Create("DLabel", pnl)
        title:SetFont("DermaLarge")
        title:SetTextColor(THEME.text)
        title:SetText("Cockpit HUD & Display Customization")
        title:Dock(TOP)
        title:DockMargin(0, 0, 0, 15)

        local cb = vgui.Create("DCheckBoxLabel", pnl)
        cb:SetText("Enable Cockpit Instrument HUD")
        cb:SetConVar("tiv_hud_enabled")
        cb:Dock(TOP)
        cb:DockMargin(0, 6, 0, 10)
        cb:SetTextColor(THEME.text)

        local uLbl = vgui.Create("DLabel", pnl)
        uLbl:SetFont("DermaDefaultBold")
        uLbl:SetTextColor(THEME.accent)
        uLbl:SetText("Speedometer & Anemometer Units:")
        uLbl:Dock(TOP)
        uLbl:DockMargin(0, 6, 0, 4)

        local unitCombo = vgui.Create("DComboBox", pnl)
        unitCombo:Dock(TOP)
        unitCombo:DockMargin(0, 0, 0, 12)
        unitCombo:AddChoice("Miles Per Hour (MPH)", "mph")
        unitCombo:AddChoice("Kilometers Per Hour (KM/H)", "kmh")
        unitCombo:AddChoice("Knots (KTS)", "knots")
        local curUnit = GetConVar("tiv_hud_unit") and GetConVar("tiv_hud_unit"):GetString() or "mph"
        unitCombo:SetValue(curUnit == "kmh" and "Kilometers Per Hour (KM/H)" or (curUnit == "knots" and "Knots (KTS)" or "Miles Per Hour (MPH)"))
        unitCombo.OnSelect = function(_, _, _, val)
            RunConsoleCommand("tiv_hud_unit", val)
        end

        local pLbl = vgui.Create("DLabel", pnl)
        pLbl:SetFont("DermaDefaultBold")
        pLbl:SetTextColor(THEME.accent)
        pLbl:SetText("Screen Corner Placement:")
        pLbl:Dock(TOP)
        pLbl:DockMargin(0, 6, 0, 4)

        local posCombo = vgui.Create("DComboBox", pnl)
        posCombo:Dock(TOP)
        posCombo:DockMargin(0, 0, 0, 12)
        posCombo:AddChoice("Bottom Right (Default)", "0")
        posCombo:AddChoice("Bottom Left", "1")
        posCombo:AddChoice("Top Right", "2")
        posCombo:AddChoice("Top Left", "3")
        local curPos = GetConVar("tiv_hud_position") and GetConVar("tiv_hud_position"):GetInt() or 0
        posCombo:SetValue(curPos == 1 and "Bottom Left" or (curPos == 2 and "Top Right" or (curPos == 3 and "Top Left" or "Bottom Right (Default)")))
        posCombo.OnSelect = function(_, _, _, val)
            RunConsoleCommand("tiv_hud_position", val)
        end

        local scaleSlider = vgui.Create("DNumSlider", pnl)
        scaleSlider:SetText("HUD Size Scale")
        scaleSlider:SetMin(0.75)
        scaleSlider:SetMax(1.5)
        scaleSlider:SetDecimals(2)
        scaleSlider:SetConVar("tiv_hud_scale")
        scaleSlider:Dock(TOP)
        scaleSlider:DockMargin(0, 6, 0, 12)
        scaleSlider:SetDark(false)

        return pnl
    end

    -- ========================================================================
    -- TAB 6: WIREMOD & AUTOMATION
    -- ========================================================================
    local function BuildWiremodTab(parent)
        local pnl = vgui.Create("DScrollPanel", parent)

        local title = vgui.Create("DLabel", pnl)
        title:SetFont("DermaLarge")
        title:SetTextColor(THEME.text)
        title:SetText("Wiremod & Expression 2 Integration")
        title:Dock(TOP)
        title:DockMargin(0, 0, 0, 15)

        local cb1 = vgui.Create("DCheckBoxLabel", pnl)
        cb1:SetText("Automatically Attach Wiremod Controller To Spawned TIVs")
        cb1:SetConVar("tiv_wire_auto_controller")
        cb1:Dock(TOP)
        cb1:DockMargin(0, 4, 0, 6)
        cb1:SetTextColor(THEME.text)

        local cb2 = vgui.Create("DCheckBoxLabel", pnl)
        cb2:SetText("Hide Controller Physical Entity Model")
        cb2:SetConVar("tiv_wire_hide_controller")
        cb2:Dock(TOP)
        cb2:DockMargin(0, 4, 0, 16)
        cb2:SetTextColor(THEME.text)

        local inTitle = vgui.Create("DLabel", pnl)
        inTitle:SetFont("DermaDefaultBold")
        inTitle:SetTextColor(THEME.accent)
        inTitle:SetText("Wire Inputs (Control Ports):")
        inTitle:Dock(TOP)

        local inDesc = vgui.Create("DLabel", pnl)
        inDesc:SetFont("DermaDefault")
        inDesc:SetTextColor(THEME.textDim)
        inDesc:SetWrap(true)
        inDesc:SetAutoStretchVertical(true)
        inDesc:SetText([[- Deploy (NORMAL): Triggers deploy sequence when pulsed to 1.
- Retract (NORMAL): Triggers unanchoring and suspension raising when pulsed to 1.
- ToggleDeploy (NORMAL): Toggles deployed/retracted state.
- EmergencyStop (NORMAL): Immediately halts deployment and recovers vehicle.
- Reset (NORMAL): Emergency clears faults and rebuilds spikes.
- Handbrake (NORMAL): Manually applies or releases parking brake.]])
        inDesc:Dock(TOP)
        inDesc:DockMargin(0, 4, 0, 16)

        local outTitle = vgui.Create("DLabel", pnl)
        outTitle:SetFont("DermaDefaultBold")
        outTitle:SetTextColor(THEME.accent)
        outTitle:SetText("Wire Outputs (Live Telemetry):")
        outTitle:Dock(TOP)

        local outDesc = vgui.Create("DLabel", pnl)
        outDesc:SetFont("DermaDefault")
        outDesc:SetTextColor(THEME.textDim)
        outDesc:SetWrap(true)
        outDesc:SetAutoStretchVertical(true)
        outDesc:SetText([[- State (STRING): idle, lowering, deploying_spikes, anchored, retracting, raising, lofted.
- IsDeployed (NORMAL): 1 if vehicle is anchored, 0 otherwise.
- WindSpeed (NORMAL): Current storm wind speed at vehicle in MPH.
- WindDirection (VECTOR): Unit direction vector of the wind.
- Stress (NORMAL): Wind stress ratio on anchor constraints (0.0 to 1.0).
- ActiveSpikes (NORMAL): Number of intact ground spikes.
- AnchorIntegrity (NORMAL): 1 if constraints are intact, 0 if compromised.
- VehicleSpeed (NORMAL): Vehicle ground speed in MPH.
- VerticalVelocity (NORMAL): Vehicle ascent/descent rate in MPH.]])
        outDesc:Dock(TOP)
        outDesc:DockMargin(0, 4, 0, 16)

        return pnl
    end

    -- ========================================================================
    -- TAB 7: FIELD MANUAL & EF SCALE
    -- ========================================================================
    local function BuildManualTab(parent)
        local pnl = vgui.Create("DScrollPanel", parent)

        local title = vgui.Create("DLabel", pnl)
        title:SetFont("DermaLarge")
        title:SetTextColor(THEME.text)
        title:SetText("Official Storm Intercept Field Manual")
        title:Dock(TOP)
        title:DockMargin(0, 0, 0, 15)

        local guideText = [[STEP 1: PRE-INTERCEPT APPROACH
- Use the cockpit HUD or Wiremod radar to track storm wind direction.
- Position vehicle directly into the projected path of the tornado.
- Bring the vehicle to a COMPLETE STOP (< 5 MPH).
- Align vehicle nose into the wind vector to minimize lateral surface area.

STEP 2: DEPLOYMENT EXECUTION
- Press [B] or pulse the Wire 'Deploy' input.
- Hydraulic rams lower vehicle chassis flush to suspension limits.
- Steel spikes drive into the ground terrain.
- Heavy-duty ballsocket constraints link the vehicle to the earth.

STEP 3: INTERCEPT MONITORING
- Monitor the Anchor Stress Bar on your HUD:
  * 0% - 60%: Safe holding capacity.
  * 60% - 85%: High lateral load (Caution).
  * 85% - 100%: Severe storm vortex shear.
- Monitor the HUD status indicator if wind approaches the loft threshold.

STEP 4: RETRACTION & RELOCATION
- Once the vortex core passes, press [B] or pulse Wire 'Retract'.
- Spikes retract smoothly from the ground.
- Hydraulic suspension re-pressurizes to road height.
- Vehicle parking handbrake automatically disengages.]]

        local body = vgui.Create("DLabel", pnl)
        body:SetFont("DermaDefault")
        body:SetTextColor(THEME.text)
        body:SetWrap(true)
        body:SetAutoStretchVertical(true)
        body:SetText(guideText)
        body:Dock(TOP)
        body:DockMargin(0, 0, 0, 20)

        local efTitle = vgui.Create("DLabel", pnl)
        efTitle:SetFont("DermaDefaultBold")
        efTitle:SetTextColor(THEME.accent)
        efTitle:SetText("Enhanced Fujita (EF) Tornado Scale Reference:")
        efTitle:Dock(TOP)
        efTitle:DockMargin(0, 0, 0, 8)

        local efCard = vgui.Create("DPanel", pnl)
        efCard:SetTall(160)
        efCard:Dock(TOP)
        efCard:DockMargin(0, 0, 0, 20)
        efCard.Paint = function(self, ew, eh)
            draw.RoundedBox(6, 0, 0, ew, eh, THEME.panelBg)
            surface.SetDrawColor(THEME.border)
            surface.DrawOutlinedRect(0, 0, ew, eh)

            local rows = {
                { "EF0", "65-85 MPH",   "Light damage to trees and signs",     "0-20% Stress", Color(100, 220, 100) },
                { "EF1", "86-110 MPH",  "Roofs peeled, trailers overturned",   "20-40% Stress", Color(180, 220, 50) },
                { "EF2", "111-135 MPH", "Roofs torn, large trees snapped",     "40-60% Stress", Color(240, 200, 40) },
                { "EF3", "136-165 MPH", "Severe structural destruction",       "60-80% Stress", Color(240, 130, 30) },
                { "EF4", "166-200 MPH", "Houses leveled, vehicles thrown",     "80-95% Stress", Color(240, 60, 40) },
                { "EF5", "200+ MPH",    "Total destruction, ground swept",     "CRITICAL STRAIN", Color(220, 20, 60) },
            }

            local y = 8
            for _, r in ipairs(rows) do
                draw.SimpleText(r[1], "DermaDefaultBold", 14, y, r[5])
                draw.SimpleText(r[2], "DermaDefault", 60, y, THEME.text)
                draw.SimpleText(r[3], "DermaDefault", 180, y, THEME.textDim)
                draw.SimpleText(r[4], "DermaDefaultBold", ew - 14, y, r[5], TEXT_ALIGN_RIGHT)
                y = y + 25
            end
        end

        return pnl
    end

    -- ========================================================================
    -- TAB 8: CHEATS & DEV SANDBOX
    -- ========================================================================
    local function BuildCheatsTab(parent)
        local pnl = vgui.Create("DScrollPanel", parent)

        local title = vgui.Create("DLabel", pnl)
        title:SetFont("DermaLarge")
        title:SetTextColor(Color(255, 255, 255))
        title:SetText("Dev Sandbox & Cheat Controls")
        title:Dock(TOP)
        title:DockMargin(0, 0, 0, 5)

        local sub = vgui.Create("DLabel", pnl)
        sub:SetFont("DermaDefault")
        sub:SetTextColor(THEME.textDim)
        sub:SetText("Sandbox testing tools for extreme intercepts, cinematic recording, and instant unlock testing.")
        sub:Dock(TOP)
        sub:DockMargin(0, 0, 0, 20)

        -- Godmode Anchors Card
        local godCard = vgui.Create("DPanel", pnl)
        godCard:SetTall(75)
        godCard:Dock(TOP)
        godCard:DockMargin(0, 0, 0, 15)
        godCard.Paint = function(s, w, h)
            draw.RoundedBox(6, 0, 0, w, h, THEME.panelBg)
            surface.SetDrawColor(THEME.border)
            surface.DrawOutlinedRect(0, 0, w, h)
            surface.SetDrawColor(Color(80, 160, 240))
            surface.DrawRect(0, 0, 4, h)
        end

        local godTextPnl = vgui.Create("DPanel", godCard)
        godTextPnl:Dock(FILL)
        godTextPnl:DockMargin(16, 12, 10, 10)
        godTextPnl.Paint = function() end

        local godTitle = vgui.Create("DLabel", godTextPnl)
        godTitle:Dock(TOP)
        godTitle:SetFont("DermaDefaultBold")
        godTitle:SetTextColor(Color(240, 240, 240))
        godTitle:SetText("Godmode Anchors")

        local godDesc = vgui.Create("DLabel", godTextPnl)
        godDesc:Dock(FILL)
        godDesc:SetFont("DermaDefault")
        godDesc:SetTextColor(THEME.textDim)
        godDesc:SetWrap(true)
        godDesc:SetText("Prevents anchors and spikes from failing or lofting the vehicle, even at extreme EF5 core wind velocities.")

        local godCheck = vgui.Create("DCheckBoxLabel", godCard)
        godCheck:SetWide(110)
        godCheck:Dock(RIGHT)
        godCheck:DockMargin(10, 24, 16, 20)
        godCheck:SetText("Enabled")
        godCheck:SetConVar("tiv_cheat_godmode_anchors")
        godCheck:SetTextColor(Color(255, 255, 255))

        -- Progression Cheats Card
        local progCard = vgui.Create("DPanel", pnl)
        progCard:SetTall(200)
        progCard:Dock(TOP)
        progCard:DockMargin(0, 0, 0, 15)
        progCard.Paint = function(s, w, h)
            draw.RoundedBox(6, 0, 0, w, h, THEME.panelBg)
            surface.SetDrawColor(THEME.border)
            surface.DrawOutlinedRect(0, 0, w, h)
            surface.SetDrawColor(Color(240, 170, 30))
            surface.DrawRect(0, 0, 4, h)
            draw.SimpleText("Progression & Upgrades Sandbox", "DermaDefaultBold", 16, 12, Color(240, 200, 50))
            draw.SimpleText("Instantly unlock all vehicle components or grant intercept points to your profile.", "DermaDefault", 16, 32, THEME.textDim)
        end

        local unlockBtn = vgui.Create("DButton", progCard)
        unlockBtn:SetPos(16, 60)
        unlockBtn:SetSize(220, 36)
        unlockBtn:SetText("UNLOCK ALL UPGRADES")
        unlockBtn:SetTextColor(Color(255, 255, 255))
        unlockBtn.Paint = function(s, w, h)
            draw.RoundedBox(4, 0, 0, w, h, s:IsHovered() and Color(240, 170, 30) or Color(200, 130, 20))
        end
        unlockBtn.DoClick = function()
            if TIV.Progression and TIV.Progression.RequestCheat then
                TIV.Progression.RequestCheat("unlock_all")
            else
                RunConsoleCommand("tiv_unlock_all")
            end
            surface.PlaySound("buttons/button14.wav")
            notification.AddLegacy("[TIV Sandbox] All vehicle upgrades unlocked!", NOTIFY_GENERIC, 3)
        end

        local grantLbl = vgui.Create("DLabel", progCard)
        grantLbl:SetPos(16, 110)
        grantLbl:SetSize(200, 20)
        grantLbl:SetFont("DermaDefaultBold")
        grantLbl:SetTextColor(Color(200, 210, 225))
        grantLbl:SetText("Grant Intercept Points:")

        local b50 = vgui.Create("DButton", progCard)
        b50:SetPos(16, 136)
        b50:SetSize(90, 30)
        b50:SetText("+50 PTS")
        b50.DoClick = function()
            if TIV.Progression and TIV.Progression.RequestCheat then
                TIV.Progression.RequestCheat("add_points", 50)
            end
            surface.PlaySound("garrysmod/save_load1.wav")
        end

        local b200 = vgui.Create("DButton", progCard)
        b200:SetPos(116, 136)
        b200:SetSize(90, 30)
        b200:SetText("+200 PTS")
        b200.DoClick = function()
            if TIV.Progression and TIV.Progression.RequestCheat then
                TIV.Progression.RequestCheat("add_points", 200)
            end
            surface.PlaySound("garrysmod/save_load1.wav")
        end

        local b1000 = vgui.Create("DButton", progCard)
        b1000:SetPos(216, 136)
        b1000:SetSize(100, 30)
        b1000:SetText("+1000 PTS")
        b1000.DoClick = function()
            if TIV.Progression and TIV.Progression.RequestCheat then
                TIV.Progression.RequestCheat("add_points", 1000)
            end
            surface.PlaySound("garrysmod/save_load1.wav")
        end

        local rstBtn = vgui.Create("DButton", progCard)
        rstBtn:SetPos(336, 136)
        rstBtn:SetSize(160, 30)
        rstBtn:SetText("RESET PROGRESSION")
        rstBtn:SetTextColor(Color(255, 140, 140))
        rstBtn.Paint = function(s, w, h)
            draw.RoundedBox(4, 0, 0, w, h, s:IsHovered() and Color(140, 40, 40) or Color(60, 25, 25))
        end
        rstBtn.DoClick = function()
            Derma_Query("Reset progression points and unlocked upgrades back to zero?", "Reset Progression", "Yes", function()
                if TIV.Progression and TIV.Progression.RequestCheat then
                    TIV.Progression.RequestCheat("reset")
                end
                surface.PlaySound("buttons/button19.wav")
            end, "No", function() end)
        end

        return pnl
    end

    -- Register sidebar tabs
    local t1 = AddSidebarTab("Quick Presets", BuildPresetsTab)
    AddSidebarTab("3D Customizer", function(parent)
        local pnl = vgui.Create("DPanel", parent)
        pnl:Dock(FILL)
        pnl.Paint = function() end

        local title = vgui.Create("DLabel", pnl)
        title:SetFont("DermaLarge")
        title:SetTextColor(Color(255, 255, 255))
        title:SetText("3D Interceptor Customizer")
        title:Dock(TOP)
        title:DockMargin(0, 0, 0, 10)

        local desc = vgui.Create("DLabel", pnl)
        desc:SetFont("DermaDefault")
        desc:SetTextColor(THEME.textDim)
        desc:SetText("Launch the full 3D visual workspace to position armor plates, cowls, and angled ground anchors directly on the vehicle in vehicle-local coordinates. Features instant AI-friendly configuration export and import.")
        desc:SetWrap(true)
        desc:SetAutoStretchVertical(true)
        desc:Dock(TOP)
        desc:DockMargin(0, 0, 0, 20)

        local openBtn = vgui.Create("DButton", pnl)
        openBtn:SetText("LAUNCH FULL 3D INTERCEPTOR EDITOR")
        openBtn:SetTall(48)
        openBtn:SetTextColor(Color(255, 255, 255))
        openBtn:Dock(TOP)
        openBtn:DockMargin(0, 0, 0, 15)
        openBtn.Paint = function(s, w, h)
            draw.RoundedBox(6, 0, 0, w, h, s:IsHovered() and Color(240, 170, 30) or Color(200, 130, 20))
        end
        openBtn.DoClick = function()
            if TIV.Editor3D and TIV.Editor3D.Open then
                TIV.Editor3D.Open()
            end
        end

        local copyBtn = vgui.Create("DButton", pnl)
        copyBtn:SetText("COPY ACTIVE CONFIGURATION")
        copyBtn:SetTall(36)
        copyBtn:SetTextColor(Color(255, 255, 255))
        copyBtn:Dock(TOP)
        copyBtn:DockMargin(0, 0, 0, 10)
        copyBtn.Paint = function(s, w, h)
            draw.RoundedBox(4, 0, 0, w, h, s:IsHovered() and Color(35, 140, 95) or Color(28, 105, 75))
        end
        copyBtn.DoClick = function()
            local cfg = (TIV.Editor3D and TIV.Editor3D.LoadConfigFromFile) and TIV.Editor3D.LoadConfigFromFile()
                or TIV.CustomConfig.GetDefaultConfig("models/buggy.mdl")
            local luaCode = TIV.CustomConfig.SerializeToLua(cfg)
            SetClipboardText(luaCode)
            Derma_Message("Vehicle configuration copied to clipboard in AI-friendly Lua format!", "Configuration Export", "OK")
        end

        return pnl
    end)

    AddSidebarTab("Progression", function(parent)
        local pnl = vgui.Create("DPanel", parent)
        pnl:Dock(FILL)
        pnl.Paint = function() end

        local title = vgui.Create("DLabel", pnl)
        title:SetFont("DermaLarge")
        title:SetTextColor(Color(255, 255, 255))
        title:SetText("Interceptor Progression & Upgrades")
        title:Dock(TOP)
        title:DockMargin(0, 0, 0, 10)

        local desc = vgui.Create("DLabel", pnl)
        desc:SetFont("DermaDefault")
        desc:SetTextColor(THEME.textDim)
        desc:SetText("Earn Intercept points by anchoring in active tornado wind fields (>= 70 MPH) and surviving violent core passes. Spend your Intercepts to unlock Angled Spikes, Side Armor, Front Deflectors, and Heavy Hydraulics.")
        desc:SetWrap(true)
        desc:SetAutoStretchVertical(true)
        desc:Dock(TOP)
        desc:DockMargin(0, 0, 0, 20)

        local statsPanel = vgui.Create("DPanel", pnl)
        statsPanel:SetTall(60)
        statsPanel:Dock(TOP)
        statsPanel:DockMargin(0, 0, 0, 20)
        statsPanel.Paint = function(s, w, h)
            draw.RoundedBox(6, 0, 0, w, h, THEME.panelBg)
            local pPts = TIV.Progression and (TIV.Progression.Points or TIV.Progression.CurrentIntercepts) or 0
            local pInt = TIV.Progression and (TIV.Progression.Intercepts or TIV.Progression.TotalIntercepts) or 0
            draw.SimpleText("SPENDABLE: " .. tostring(pPts) .. " PTS", "DermaDefaultBold", 20, 20, Color(240, 200, 50), TEXT_ALIGN_LEFT)
            draw.SimpleText("INTERCEPTS: " .. tostring(pInt), "DermaDefaultBold", 240, 20, Color(80, 200, 255), TEXT_ALIGN_LEFT)
        end

        local openShopBtn = vgui.Create("DButton", pnl)
        openShopBtn:SetText("OPEN UPGRADE TREE")
        openShopBtn:SetTall(42)
        openShopBtn:SetTextColor(Color(255, 255, 255))
        openShopBtn:Dock(TOP)
        openShopBtn.Paint = function(s, w, h)
            draw.RoundedBox(6, 0, 0, w, h, s:IsHovered() and THEME.accent or THEME.accentDark)
        end
        openShopBtn.DoClick = function()
            if TIV.Progression and TIV.Progression.OpenUpgradeMenu then
                TIV.Progression.OpenUpgradeMenu()
            end
        end

        return pnl
    end)

    AddSidebarTab("Spikes & Radar", BuildSpikesTab)
    AddSidebarTab("Suspension & Deploy", BuildSuspensionTab)
    AddSidebarTab("Storm & Wind", BuildWindTab)
    AddSidebarTab("Cockpit HUD", BuildHUDTab)
    AddSidebarTab("Wiremod & E2", BuildWiremodTab)
    AddSidebarTab("Field Manual", BuildManualTab)
    AddSidebarTab("Cheats / Sandbox", BuildCheatsTab)

    -- Default to Presets tab
    t1:DoClick()

    TIV.Menu.Frame = frame
end

-- Console commands to open master console
concommand.Add("tiv_menu", TIV.Menu.OpenMasterConsole)
concommand.Add("tiv_settings", TIV.Menu.OpenMasterConsole)

-- Chat command support
hook.Add("OnPlayerChat", "TIV_ChatCommand", function(ply, text)
    if ply == LocalPlayer() and (string.lower(text) == "!tiv" or string.lower(text) == "/tiv") then
        TIV.Menu.OpenMasterConsole()
        return true
    end
end)

print("[TIV] Comprehensive settings menu and master console loaded")
