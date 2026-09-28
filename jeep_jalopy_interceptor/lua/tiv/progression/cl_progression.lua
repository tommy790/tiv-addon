-- ============================================================================
-- TIV PROGRESSION & UPGRADE SYSTEM - Client
-- Progression cache, animated HUD award notifications, and upgrade shop UI.
-- ============================================================================

TIV = TIV or {}
TIV.Progression = TIV.Progression or {}

TIV.Progression.Points            = TIV.Progression.Points            or 0
TIV.Progression.TotalPoints       = TIV.Progression.TotalPoints       or 0
TIV.Progression.Intercepts        = TIV.Progression.Intercepts        or 0
TIV.Progression.CurrentIntercepts = TIV.Progression.Points -- legacy alias
TIV.Progression.TotalIntercepts   = TIV.Progression.Intercepts -- legacy alias
TIV.Progression.UnlockedUpgrades  = TIV.Progression.UnlockedUpgrades  or {}

-- HUD Toast Notification State
local activeToast = nil

-- ============================================================================
-- NETWORK RECEIVERS
-- ============================================================================
net.Receive("TIV_SyncProgression", function()
    TIV.Progression.Points            = net.ReadUInt(16)
    TIV.Progression.TotalPoints       = net.ReadUInt(16)
    TIV.Progression.Intercepts        = net.ReadUInt(16)
    TIV.Progression.CurrentIntercepts = TIV.Progression.Points
    TIV.Progression.TotalIntercepts   = TIV.Progression.Intercepts

    local count = net.ReadUInt(8)
    local unlocked = {}
    for i = 1, count do
        local id = net.ReadString()
        unlocked[id] = true
    end
    TIV.Progression.UnlockedUpgrades = unlocked

    hook.Run("TIV_ProgressionUpdated")
end)

net.Receive("TIV_InterceptAwarded", function()
    local intercepts = net.ReadUInt(16)
    local reason     = net.ReadString()

    TIV.Progression.Intercepts      = intercepts
    TIV.Progression.TotalIntercepts = intercepts

    activeToast = {
        toastType  = "intercept",
        amount     = 1,
        reason     = reason,
        intercepts = intercepts,
        startTime  = CurTime(),
        duration   = 5.5,
    }

    hook.Run("TIV_ProgressionUpdated")
end)

net.Receive("TIV_PointsAwarded", function()
    local amount      = net.ReadUInt(8)
    local points      = net.ReadUInt(16)
    local totalPoints = net.ReadUInt(16)
    local intercepts  = net.ReadUInt(16)
    local reason      = net.ReadString()

    TIV.Progression.Points            = points
    TIV.Progression.TotalPoints       = totalPoints
    TIV.Progression.Intercepts        = intercepts
    TIV.Progression.CurrentIntercepts = points
    TIV.Progression.TotalIntercepts   = intercepts

    activeToast = {
        toastType   = "points",
        amount      = amount,
        reason      = reason,
        points      = points,
        totalPoints = totalPoints,
        intercepts  = intercepts,
        startTime   = CurTime(),
        duration    = 4.5,
    }

    hook.Run("TIV_ProgressionUpdated")
end)

function TIV.Progression.IsUnlocked(id)
    return TIV.Progression.UnlockedUpgrades[id] == true
end

function TIV.Progression.RequestCheat(action, arg)
    net.Start("TIV_CheatAction")
        net.WriteString(action or "")
        net.WriteInt(arg or 0, 32)
    net.SendToServer()
end

function TIV.Progression.RequestSync()
    net.Start("TIV_RequestProgression")
    net.SendToServer()
end

-- ============================================================================
-- HUD NOTIFICATION BANNER
-- ============================================================================
hook.Add("HUDPaint", "TIV_InterceptToastHUD", function()
    if not activeToast then return end

    local elapsed = CurTime() - activeToast.startTime
    if elapsed > activeToast.duration then
        activeToast = nil
        return
    end

    local alpha = 255
    if elapsed < 0.5 then
        alpha = math.Clamp(elapsed / 0.5 * 255, 0, 255)
    elseif elapsed > (activeToast.duration - 0.7) then
        alpha = math.Clamp((activeToast.duration - elapsed) / 0.7 * 255, 0, 255)
    end

    local w, h = 430, 84
    local x = (ScrW() - w) / 2
    local y = 60

    -- Background frame
    draw.RoundedBox(6, x, y, w, h, Color(16, 20, 28, alpha * 0.95))
    draw.RoundedBox(4, x + 2, y + 2, w - 4, h - 4, Color(24, 30, 42, alpha * 0.9))

    local isInterceptToast = (activeToast.toastType == "intercept")
    local accentCol = isInterceptToast and Color(0, 220, 255, alpha) or Color(240, 180, 40, alpha)

    -- Left accent indicator bar
    draw.RoundedBox(3, x + 4, y + 4, 6, h - 8, accentCol)

    -- Header text & amount
    if isInterceptToast then
        draw.SimpleText("TORNADO INTERCEPT LOGGED", "Trebuchet24", x + 22, y + 8, Color(80, 220, 255, alpha), TEXT_ALIGN_LEFT)
        draw.SimpleText("+1 INTERCEPT", "Trebuchet24", x + w - 16, y + 8, Color(250, 210, 60, alpha), TEXT_ALIGN_RIGHT)
        draw.SimpleText(activeToast.reason, "DefaultFixedDropShadow", x + 22, y + 36, Color(220, 230, 240, alpha), TEXT_ALIGN_LEFT)
        local balStr = string.format("Career Intercepts: %d  |  Spendable Points: %d pts", activeToast.intercepts or 0, TIV.Progression.Points or 0)
        draw.SimpleText(balStr, "DefaultFixedDropShadow", x + 22, y + 58, Color(160, 200, 230, alpha), TEXT_ALIGN_LEFT)
    else
        draw.SimpleText("INTERCEPT POINTS", "Trebuchet24", x + 22, y + 8, Color(240, 200, 50, alpha), TEXT_ALIGN_LEFT)
        draw.SimpleText("+" .. activeToast.amount .. " PTS", "Trebuchet24", x + w - 16, y + 8, Color(80, 230, 100, alpha), TEXT_ALIGN_RIGHT)
        draw.SimpleText(activeToast.reason, "DefaultFixedDropShadow", x + 22, y + 36, Color(220, 220, 220, alpha), TEXT_ALIGN_LEFT)
        local balStr = string.format("Spendable: %d pts  |  Career Intercepts: %d", activeToast.points or 0, activeToast.intercepts or TIV.Progression.Intercepts or 0)
        draw.SimpleText(balStr, "DefaultFixedDropShadow", x + 22, y + 58, Color(160, 180, 210, alpha), TEXT_ALIGN_LEFT)
    end
end)

-- ============================================================================
-- UPGRADE SHOP WINDOW
-- ============================================================================
function TIV.Progression.OpenUpgradeMenu()
    local frame = vgui.Create("DFrame")
    frame:SetSize(780, 620)
    frame:Center()
    frame:SetTitle("")
    frame:MakePopup()
    frame:ShowCloseButton(false)

    frame.Paint = function(s, w, h)
        draw.RoundedBox(8, 0, 0, w, h, Color(20, 24, 32, 250))
        draw.RoundedBox(6, 1, 1, w - 2, h - 2, Color(28, 34, 46, 255))
        draw.RoundedBox(4, 2, 2, w - 4, 48, Color(16, 20, 28, 255))

        draw.SimpleText("TIV PROGRESSION & UPGRADE TREE", "Trebuchet24", 16, 12, Color(240, 200, 60), TEXT_ALIGN_LEFT)
    end

    local closeBtn = vgui.Create("DButton", frame)
    closeBtn:SetSize(36, 28)
    closeBtn:SetPos(frame:GetWide() - 44, 10)
    closeBtn:SetText("X")
    closeBtn:SetTextColor(Color(200, 200, 200))
    closeBtn.Paint = function(s, w, h)
        local bg = s:IsHovered() and Color(200, 40, 40) or Color(50, 56, 70)
        draw.RoundedBox(4, 0, 0, w, h, bg)
    end
    closeBtn.DoClick = function()
        frame:Close()
    end

    -- Stats summary bar
    local statsBar = vgui.Create("DPanel", frame)
    statsBar:SetPos(16, 56)
    statsBar:SetSize(frame:GetWide() - 32, 60)
    statsBar.Paint = function(s, w, h)
        draw.RoundedBox(6, 0, 0, w, h, Color(18, 22, 30, 255))

        -- Stat 1: Spendable Points
        draw.SimpleText("SPENDABLE POINTS", "DermaDefaultBold", 20, 10, Color(160, 170, 190), TEXT_ALIGN_LEFT)
        draw.SimpleText(tostring(TIV.Progression.Points or 0) .. " PTS", "Trebuchet24", 20, 26, Color(250, 200, 50), TEXT_ALIGN_LEFT)

        -- Stat 2: Total Career Intercepts
        draw.SimpleText("CAREER INTERCEPTS", "DermaDefaultBold", 260, 10, Color(160, 170, 190), TEXT_ALIGN_LEFT)
        draw.SimpleText(tostring(TIV.Progression.Intercepts or 0), "Trebuchet24", 260, 26, Color(80, 200, 255), TEXT_ALIGN_LEFT)

        -- Stat 3: Unlocked Count
        local unlockedCount = 0
        local totalUpgrades = #TIV.Progression.GetAllUpgrades()
        for _, u in ipairs(TIV.Progression.GetAllUpgrades()) do
            if TIV.Progression.IsUnlocked(u.id) then unlockedCount = unlockedCount + 1 end
        end
        draw.SimpleText("UPGRADES UNLOCKED", "DermaDefaultBold", 500, 10, Color(160, 170, 190), TEXT_ALIGN_LEFT)
        draw.SimpleText(string.format("%d / %d", unlockedCount, totalUpgrades), "Trebuchet24", 500, 26, Color(120, 240, 120), TEXT_ALIGN_LEFT)
    end

    -- Scrollable list of upgrades
    local scroll = vgui.Create("DScrollPanel", frame)
    scroll:SetPos(16, 124)
    scroll:SetSize(frame:GetWide() - 32, frame:GetTall() - 180)

    local function RebuildList()
        scroll:Clear()

        for _, upg in ipairs(TIV.Progression.GetAllUpgrades()) do
            local isUnlocked = TIV.Progression.IsUnlocked(upg.id)
            local canAfford  = (TIV.Progression.Points or 0) >= upg.cost

            local item = scroll:Add("DPanel")
            item:Dock(TOP)
            item:DockMargin(0, 0, 0, 10)
            item:SetTall(100)

            item.Paint = function(s, w, h)
                local bg = isUnlocked and Color(24, 38, 30, 240) or Color(22, 26, 36, 240)
                local border = isUnlocked and Color(60, 140, 80) or Color(45, 52, 70)
                draw.RoundedBox(6, 0, 0, w, h, border)
                draw.RoundedBox(4, 1, 1, w - 2, h - 2, bg)
            end

            -- Right action button
            local actionBtn = vgui.Create("DButton", item)
            actionBtn:SetWide(150)
            actionBtn:Dock(RIGHT)
            actionBtn:DockMargin(8, 28, 14, 28)

            if isUnlocked then
                actionBtn:SetText("PURCHASED")
                actionBtn:SetTextColor(Color(120, 240, 120))
                actionBtn:SetEnabled(false)
                actionBtn.Paint = function(s, w, h)
                    draw.RoundedBox(4, 0, 0, w, h, Color(30, 60, 40))
                end
            else
                local costStr = string.format("UNLOCK (%d PTS)", upg.cost)
                actionBtn:SetText(costStr)
                actionBtn:SetTextColor(canAfford and Color(255, 255, 255) or Color(160, 160, 160))
                actionBtn:SetEnabled(canAfford)
                actionBtn.Paint = function(s, w, h)
                    local bg
                    if not canAfford then
                        bg = Color(50, 54, 64)
                    elseif s:IsHovered() then
                        bg = Color(240, 170, 30)
                    else
                        bg = Color(200, 130, 20)
                    end
                    draw.RoundedBox(4, 0, 0, w, h, bg)
                end
                actionBtn.DoClick = function()
                    net.Start("TIV_PurchaseUpgrade")
                        net.WriteString(upg.id)
                    net.SendToServer()

                    surface.PlaySound("buttons/button14.wav")
                    timer.Simple(0.3, function()
                        if IsValid(frame) then
                            RebuildList()
                            statsBar:InvalidateLayout()
                        end
                    end)
                end
            end

            -- Left Content Area (strictly partitioned from the right action button)
            local content = vgui.Create("DPanel", item)
            content:Dock(FILL)
            content:DockMargin(12, 8, 8, 8)
            content.Paint = function() end

            -- Top header row: Category badge + Title
            local topRow = vgui.Create("DPanel", content)
            topRow:Dock(TOP)
            topRow:SetTall(22)
            topRow:DockMargin(0, 0, 0, 4)
            topRow.Paint = function(s, w, h)
                draw.RoundedBox(3, 0, 2, 78, 18, Color(35, 42, 58))
                draw.SimpleText(string.upper(upg.category or "UPGRADE"), "DermaDefault", 39, 3, Color(180, 200, 230), TEXT_ALIGN_CENTER)
                draw.SimpleText(upg.name, "Trebuchet18", 88, 1, Color(240, 240, 240), TEXT_ALIGN_LEFT)
            end

            -- Upgrade description (wrapped safely inside left container)
            local descLbl = vgui.Create("DLabel", content)
            descLbl:Dock(TOP)
            descLbl:SetTall(34)
            descLbl:SetFont("DermaDefault")
            descLbl:SetTextColor(Color(190, 195, 205))
            descLbl:SetWrap(true)
            descLbl:SetText(upg.desc)

            -- Physics benefits preview
            local bonusText = ""
            if upg.bonuses then
                local parts = {}
                if upg.bonuses.loft_threshold then table.insert(parts, "+" .. upg.bonuses.loft_threshold .. " MPH Loft Resistance") end
                if upg.bonuses.rock_torque_mult then table.insert(parts, "-" .. math.Round((1 - upg.bonuses.rock_torque_mult) * 100) .. "% Rocking Torque") end
                if upg.bonuses.wind_force_mult then table.insert(parts, "-" .. math.Round((1 - upg.bonuses.wind_force_mult) * 100) .. "% Wind Drag") end
                if upg.bonuses.anchor_hold_mult then table.insert(parts, "+" .. math.Round((upg.bonuses.anchor_hold_mult - 1) * 100) .. "% Anchor Strength") end
                if upg.bonuses.added_mass then table.insert(parts, "+" .. upg.bonuses.added_mass .. " kg Mass") end
                bonusText = table.concat(parts, "  |  ")
            end

            local bonusLbl = vgui.Create("DLabel", content)
            bonusLbl:Dock(TOP)
            bonusLbl:SetTall(18)
            bonusLbl:SetFont("DermaDefaultBold")
            bonusLbl:SetTextColor(Color(140, 210, 160))
            bonusLbl:SetText("Physics: " .. bonusText)
        end
    end

    RebuildList()

    -- Bottom instructions footer
    local footer = vgui.Create("DPanel", frame)
    footer:SetPos(16, frame:GetTall() - 48)
    footer:SetSize(frame:GetWide() - 32, 38)
    footer.Paint = function(s, w, h)
        draw.RoundedBox(4, 0, 0, w, h, Color(16, 20, 28, 255))
        draw.SimpleText("How to earn: Deploy & anchor inside severe tornado winds (>= 70 MPH) or survive a violent vortex core passage.",
            "DermaDefault", 10, 11, Color(160, 180, 210), TEXT_ALIGN_LEFT)
    end
end

concommand.Add("tiv_upgrades", function()
    TIV.Progression.OpenUpgradeMenu()
end)

print("[TIV] Client progression module loaded")
