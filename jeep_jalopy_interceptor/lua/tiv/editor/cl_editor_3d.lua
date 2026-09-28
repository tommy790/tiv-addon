-- ============================================================================
-- TIV 3D INTERCEPTOR CONFIGURATION EDITOR - Client
-- Interactive 3D viewport, real-time component manipulation, model selection,
-- vehicle-relative coordinate axes, persistence, and deterministic Lua import/export.
-- ============================================================================

TIV = TIV or {}
TIV.Editor3D = TIV.Editor3D or {}

local SAVE_FILE_PATH = "tiv/saved_vehicle_config.json"

-- Active editor state
TIV.Editor3D.ActiveFrame       = nil
TIV.Editor3D.ActiveConfig      = nil
TIV.Editor3D.SelectedIndex     = 1
TIV.Editor3D.ClientsideModels  = {}

-- ============================================================================
-- PERSISTENCE HELPERS
-- ============================================================================
function TIV.Editor3D.SaveConfigToFile(config)
    if not istable(config) then return end
    if not file.IsDir("tiv", "DATA") then file.CreateDir("tiv") end
    if not file.IsDir("tiv/configs", "DATA") then file.CreateDir("tiv/configs") end

    local model = string.lower(config.vehicle_model or "models/buggy.mdl")
    local json = util.TableToJSON(config, true)

    -- Save to per-model configuration file
    local modelPath = TIV.CustomConfig.GetConfigFileName(model)
    file.Write(modelPath, json)

    -- Keep legacy global path updated as latest
    file.Write(SAVE_FILE_PATH, json)
end

function TIV.Editor3D.LoadConfigFromFile(targetModel)
    targetModel = string.lower(targetModel or "models/buggy.mdl")
    local modelPath = TIV.CustomConfig.GetConfigFileName(targetModel)

    local raw = nil
    if file.Exists(modelPath, "DATA") then
        raw = file.Read(modelPath, "DATA")
    elseif file.Exists(SAVE_FILE_PATH, "DATA") then
        local legacyRaw = file.Read(SAVE_FILE_PATH, "DATA")
        if legacyRaw and legacyRaw ~= "" then
            local decoded = util.JSONToTable(legacyRaw)
            if not decoded or (decoded.vehicle_model and string.lower(decoded.vehicle_model) == targetModel) then
                raw = legacyRaw
            end
        end
    end

    if raw and raw ~= "" then
        local decoded, err = TIV.CustomConfig.DeserializeFromLua(raw)
        if decoded and istable(decoded.components) then
            decoded.vehicle_model = targetModel
            for _, c in ipairs(decoded.components) do
                if c.type == "armor_side" or c.type == "armor_front" or c.type == "armor_roof" then
                    if c.model == "models/props_c17/fence01a.mdl" or c.model == "models/props_combine/combine_fence01b.mdl" then
                        c.model = "models/props_phx/construct/metal_plate1x2.mdl"
                    end
                end
            end

            -- Auto-apply angled spike preset if upgrade is active and spikes are at default 90 degrees
            local hasAngledUpg = TIV.Progression and TIV.Progression.IsUnlocked and TIV.Progression.IsUnlocked("angled_spikes")
            if hasAngledUpg then
                for _, c in ipairs(decoded.components) do
                    if c.type == "spike" and c.ang and math.abs(c.ang.p - 90) < 0.1 and math.abs(c.ang.y) < 0.1 and math.abs(c.ang.r) < 0.1 then
                        if c.pos and c.pos.x > 0 then
                            c.ang = Angle(80, 0, 0)
                        elseif c.pos and c.pos.x < 0 then
                            c.ang = Angle(100, 0, 0)
                        end
                    end
                end
            else
                -- Lock all spikes to straight 90 degrees if upgrade has not been purchased
                for _, c in ipairs(decoded.components) do
                    if c.type == "spike" then
                        c.ang = Angle(90, 0, 0)
                    end
                end
            end

            return decoded
        end
    end

    return TIV.CustomConfig.GetDefaultConfig(targetModel)
end

-- ============================================================================
-- CLEANUP CLIENTSIDE MODELS
-- ============================================================================
function TIV.Editor3D.ClearClientsideModels()
    for _, cs in pairs(TIV.Editor3D.ClientsideModels) do
        if IsValid(cs) then
            SafeRemoveEntity(cs)
        end
    end
    TIV.Editor3D.ClientsideModels = {}
end

-- ============================================================================
-- OPEN 3D CONFIGURATION EDITOR
-- ============================================================================
function TIV.Editor3D.Open()
    if IsValid(TIV.Editor3D.ActiveFrame) then
        TIV.Editor3D.ActiveFrame:Remove()
    end

    -- Forward declaration, hoisted above every closure in this function.
    --
    -- The toolbar buttons below (Mirror, Duplicate, Grid Snap) capture
    -- RefreshEditor as an upvalue when their DoClick closures are created.
    -- Declaring the local further down -- as the old "Forward declarations"
    -- block did -- meant those closures resolved the name as a GLOBAL that is
    -- never assigned, so their `if isfunction(RefreshEditor)` guard was always
    -- false and the buttons never refreshed the panel.
    local RefreshEditor

    TIV.Editor3D.ClearClientsideModels()

    -- Resolve active vehicle model
    local ply = LocalPlayer()
    local veh = TIV.Deploy and TIV.Deploy.ResolveVehicle and TIV.Deploy.ResolveVehicle(ply)
    local curVehModel = IsValid(veh) and veh:GetModel() or "models/buggy.mdl"
    curVehModel = string.lower(curVehModel)

    -- Load config or default
    TIV.Editor3D.ActiveConfig  = TIV.Editor3D.LoadConfigFromFile(curVehModel)
    TIV.Editor3D.ActiveConfig.vehicle_model = curVehModel
    TIV.Editor3D.SelectedIndex = 1

    local winW = math.Clamp(ScrW() - 60, 1024, 1360)
    local winH = math.Clamp(ScrH() - 60, 720, 920)

    local frame = vgui.Create("DFrame")
    frame:SetSize(winW, winH)
    frame:Center()
    frame:SetTitle("")
    frame:MakePopup()
    frame:ShowCloseButton(false)
    TIV.Editor3D.ActiveFrame = frame

    frame.Paint = function(s, w, h)
        draw.RoundedBox(8, 0, 0, w, h, Color(18, 22, 30, 252))
        draw.RoundedBox(6, 1, 1, w - 2, h - 2, Color(26, 32, 44, 255))
        draw.RoundedBox(4, 2, 2, w - 4, 46, Color(14, 18, 25, 255))

        draw.SimpleText("TIV 3D INTERCEPTOR CONFIGURATION EDITOR", "Trebuchet24", 18, 11, Color(240, 200, 50), TEXT_ALIGN_LEFT)
        draw.SimpleText("Local Vehicle Coordinate Space: +Y = Forward | +X = Right | +Z = Up", "DermaDefault", 520, 18, Color(160, 180, 210), TEXT_ALIGN_LEFT)
    end

    frame.OnRemove = function()
        TIV.Editor3D.ClearClientsideModels()
    end

    -- Close Button
    local closeBtn = vgui.Create("DButton", frame)
    closeBtn:SetSize(36, 28)
    closeBtn:SetPos(frame:GetWide() - 44, 9)
    closeBtn:SetText("X")
    closeBtn:SetTextColor(Color(220, 220, 220))
    closeBtn.Paint = function(s, w, h)
        draw.RoundedBox(4, 0, 0, w, h, s:IsHovered() and Color(200, 40, 40) or Color(45, 52, 66))
    end
    closeBtn.DoClick = function()
        frame:Close()
    end

    -- ========================================================================
    -- INTERCEPTOR MODEL SWITCHER BAR
    -- Allows switching the base vehicle model to configure different vehicles
    -- or entities identified as interceptors.
    -- ========================================================================
    local modelBar = vgui.Create("DPanel", frame)
    modelBar:SetPos(14, 50)
    modelBar:SetSize(winW - 28, 42)
    modelBar.Paint = function(s, w, h)
        draw.RoundedBox(6, 0, 0, w, h, Color(14, 18, 25, 255))
        draw.RoundedBox(4, 1, 1, w - 2, h - 2, Color(24, 30, 42, 255))
    end

    local modelLbl = vgui.Create("DLabel", modelBar)
    modelLbl:SetPos(12, 10)
    modelLbl:SetSize(140, 22)
    modelLbl:SetText("TARGET INTERCEPTOR:")
    modelLbl:SetFont("DermaDefaultBold")
    modelLbl:SetTextColor(Color(240, 205, 50))

    local modelCombo = vgui.Create("DComboBox", modelBar)
    modelCombo:SetPos(156, 8)
    modelCombo:SetSize(210, 26)

    local modelEntry = vgui.Create("DTextEntry", modelBar)
    modelEntry:SetPos(372, 8)
    modelEntry:SetSize(180, 26)
    modelEntry:SetText(curVehModel)

    local switchBtn = vgui.Create("DButton", modelBar)
    switchBtn:SetPos(558, 8)
    switchBtn:SetSize(90, 26)
    switchBtn:SetText("Switch Model")
    switchBtn:SetTextColor(Color(255, 255, 255))
    switchBtn.Paint = function(s, w, h)
        draw.RoundedBox(4, 0, 0, w, h, s:IsHovered() and Color(60, 130, 190) or Color(45, 100, 150))
    end

    local useVehBtn = vgui.Create("DButton", modelBar)
    useVehBtn:SetPos(654, 8)
    useVehBtn:SetSize(105, 26)
    useVehBtn:SetText("Use My Vehicle")
    useVehBtn:SetTextColor(Color(255, 255, 255))
    useVehBtn.Paint = function(s, w, h)
        draw.RoundedBox(4, 0, 0, w, h, s:IsHovered() and Color(45, 145, 90) or Color(35, 115, 70))
    end

    local cloneBtn = vgui.Create("DButton", modelBar)
    cloneBtn:SetPos(765, 8)
    cloneBtn:SetSize(95, 26)
    cloneBtn:SetText("Clone From...")
    cloneBtn:SetTextColor(Color(255, 255, 255))
    cloneBtn.Paint = function(s, w, h)
        draw.RoundedBox(4, 0, 0, w, h, s:IsHovered() and Color(110, 80, 150) or Color(85, 60, 115))
    end

    local tagBtn = vgui.Create("DButton", modelBar)
    tagBtn:SetPos(866, 8)
    tagBtn:SetSize(115, 26)
    tagBtn:SetText("Tag Aimed Entity")
    tagBtn:SetTextColor(Color(255, 255, 255))
    tagBtn.Paint = function(s, w, h)
        draw.RoundedBox(4, 0, 0, w, h, s:IsHovered() and Color(165, 105, 35) or Color(130, 80, 25))
    end

    -- Layout: Left = 3D Viewport, Right = Controls & Component Tree
    local rightWidth = 440
    local viewportW  = winW - rightWidth - 28
    local panelY     = 98
    local mainH      = winH - 156

    -- ========================================================================
    -- 3D MODEL VIEWPORT
    -- ========================================================================
    local viewportPanel = vgui.Create("DPanel", frame)
    viewportPanel:SetPos(14, panelY)
    viewportPanel:SetSize(viewportW, mainH)
    viewportPanel.Paint = function(s, w, h)
        draw.RoundedBox(6, 0, 0, w, h, Color(12, 14, 20, 255))
        draw.RoundedBox(4, 1, 1, w - 2, h - 2, Color(18, 22, 32, 255))
    end

    local modelPanel = vgui.Create("DAdjustableModelPanel", viewportPanel)
    modelPanel:Dock(FILL)
    modelPanel:DockMargin(2, 2, 2, 2)
    modelPanel:SetModel(curVehModel)
    modelPanel:SetCamPos(Vector(150, 150, 110))
    modelPanel:SetLookAt(Vector(0, 0, 10))
    modelPanel:SetFOV(42)

    -- Disable default auto-rotation / spinning of the entity or camera
    modelPanel.LayoutEntity = function(self, ent)
        if IsValid(ent) then
            ent:SetAngles(Angle(0, 0, 0))
            ent:SetPos(Vector(0, 0, 0))
        end
    end

    -- Initialize Editor3D state options
    TIV.Editor3D.ShowSpikes     = (TIV.Editor3D.ShowSpikes == nil) and true or TIV.Editor3D.ShowSpikes
    TIV.Editor3D.ShowArmor      = (TIV.Editor3D.ShowArmor == nil) and true or TIV.Editor3D.ShowArmor
    TIV.Editor3D.ShowWireframes = (TIV.Editor3D.ShowWireframes == nil) and false or TIV.Editor3D.ShowWireframes
    TIV.Editor3D.ShowGizmo      = (TIV.Editor3D.ShowGizmo == nil) and true or TIV.Editor3D.ShowGizmo
    TIV.Editor3D.GridSnap       = TIV.Editor3D.GridSnap or 1.0
    TIV.Editor3D.PrecisionStep  = TIV.Editor3D.PrecisionStep or 1.0

    -- Viewport top tool bar (Mirroring, Duplication, Grid Snap, Component Toggles, Precision Adjustment)
    local toolBar = vgui.Create("DPanel", viewportPanel)
    toolBar:SetPos(10, 10)
    toolBar:SetSize(viewportW - 20, 32)
    toolBar.Paint = function(s, w, h)
        draw.RoundedBox(4, 0, 0, w, h, Color(10, 14, 20, 230))
    end

    -- 1. Mirror (X) Tool
    local mirrorBtn = vgui.Create("DButton", toolBar)
    mirrorBtn:Dock(LEFT)
    mirrorBtn:DockMargin(4, 4, 4, 4)
    mirrorBtn:SetWide(76)
    mirrorBtn:SetText("Mirror (X)")
    mirrorBtn:SetTextColor(Color(255, 230, 160))
    mirrorBtn.Paint = function(s, w, h)
        draw.RoundedBox(3, 0, 0, w, h, s:IsHovered() and Color(160, 110, 40) or Color(90, 65, 30))
    end
    mirrorBtn.DoClick = function()
        local config = TIV.Editor3D.ActiveConfig
        local comps  = config and config.components
        local sel    = TIV.Editor3D.SelectedIndex
        local cur    = comps and comps[sel]
        if cur and cur.pos then
            cur.pos.x = -cur.pos.x
            if cur.type == "spike" and math.abs(cur.ang.p - 90) < 45 then
                cur.ang.p = 180 - cur.ang.p
                cur.ang.y = -cur.ang.y
            else
                cur.ang.y = -cur.ang.y
                cur.ang.r = -cur.ang.r
            end
            if isfunction(RefreshEditor) then RefreshEditor() end
            surface.PlaySound("buttons/button14.wav")
        end
    end

    -- 2. Duplicate Tool
    local dupBtn = vgui.Create("DButton", toolBar)
    dupBtn:Dock(LEFT)
    dupBtn:DockMargin(0, 4, 4, 4)
    dupBtn:SetWide(70)
    dupBtn:SetText("Duplicate")
    dupBtn:SetTextColor(Color(220, 230, 255))
    dupBtn.Paint = function(s, w, h)
        draw.RoundedBox(3, 0, 0, w, h, s:IsHovered() and Color(110, 75, 150) or Color(65, 45, 95))
    end
    dupBtn.DoClick = function()
        local config = TIV.Editor3D.ActiveConfig
        local comps  = config and config.components
        local sel    = TIV.Editor3D.SelectedIndex
        local cur    = comps and comps[sel]
        if cur then
            local clone = table.Copy(cur)
            clone.id    = clone.id .. "_copy"
            clone.name  = clone.name .. " (Copy)"
            clone.pos   = clone.pos + Vector(0, 10, 0)
            table.insert(comps, clone)
            TIV.Editor3D.SelectedIndex = #comps
            if isfunction(RefreshEditor) then RefreshEditor() end
            surface.PlaySound("buttons/button14.wav")
        end
    end

    -- 3. Grid Snapping Tool
    local snapBtn = vgui.Create("DButton", toolBar)
    snapBtn:Dock(LEFT)
    snapBtn:DockMargin(0, 4, 4, 4)
    snapBtn:SetWide(78)
    local snapOptions = { 0, 1.0, 5.0, 10.0 }
    local snapLabels  = { "Snap: OFF", "Snap: 1u", "Snap: 5u", "Snap: 10u" }
    local snapIdx     = 2
    snapBtn:SetText(snapLabels[snapIdx])
    snapBtn:SetTextColor(Color(220, 240, 220))
    snapBtn.Paint = function(s, w, h)
        draw.RoundedBox(3, 0, 0, w, h, s:IsHovered() and Color(40, 120, 80) or Color(25, 75, 50))
    end
    snapBtn.DoClick = function()
        snapIdx = (snapIdx % #snapOptions) + 1
        TIV.Editor3D.GridSnap = snapOptions[snapIdx]
        snapBtn:SetText(snapLabels[snapIdx])
        local grid = TIV.Editor3D.GridSnap
        if grid > 0 then
            local config = TIV.Editor3D.ActiveConfig
            local comps  = config and config.components
            local sel    = TIV.Editor3D.SelectedIndex
            local cur    = comps and comps[sel]
            if cur and cur.pos then
                cur.pos.x = math.Round(cur.pos.x / grid) * grid
                cur.pos.y = math.Round(cur.pos.y / grid) * grid
                cur.pos.z = math.Round(cur.pos.z / grid) * grid
                if isfunction(RefreshEditor) then RefreshEditor() end
            end
        end
        surface.PlaySound("buttons/button14.wav")
    end

    -- 4. Precision Step Multiplier
    local stepBtn = vgui.Create("DButton", toolBar)
    stepBtn:Dock(LEFT)
    stepBtn:DockMargin(0, 4, 4, 4)
    stepBtn:SetWide(74)
    local stepOptions = { 0.1, 1.0, 5.0, 10.0 }
    local stepLabels  = { "Step: 0.1", "Step: 1.0", "Step: 5.0", "Step: 10" }
    local stepIdx     = 2
    stepBtn:SetText(stepLabels[stepIdx])
    stepBtn:SetTextColor(Color(200, 230, 255))
    stepBtn.Paint = function(s, w, h)
        draw.RoundedBox(3, 0, 0, w, h, s:IsHovered() and Color(40, 90, 140) or Color(25, 60, 95))
    end
    stepBtn.DoClick = function()
        stepIdx = (stepIdx % #stepOptions) + 1
        TIV.Editor3D.PrecisionStep = stepOptions[stepIdx]
        stepBtn:SetText(stepLabels[stepIdx])
        surface.PlaySound("buttons/button14.wav")
    end

    -- 5. Component Visibility Toggles
    local function AddToggleBtn(label, getState, setState, activeCol)
        local btn = vgui.Create("DButton", toolBar)
        btn:Dock(LEFT)
        btn:DockMargin(0, 4, 4, 4)
        btn:SetWide(68)
        btn:SetText(label .. (getState() and ": ON" or ": OFF"))
        btn:SetTextColor(Color(220, 230, 245))
        btn.Paint = function(s, w, h)
            local st = getState()
            local col = st and activeCol or Color(40, 48, 60)
            if s:IsHovered() then
                col = Color(col.r + 20, col.g + 20, col.b + 20)
            end
            draw.RoundedBox(3, 0, 0, w, h, col)
        end
        btn.DoClick = function()
            setState(not getState())
            btn:SetText(label .. (getState() and ": ON" or ": OFF"))
            surface.PlaySound("buttons/button14.wav")
        end
    end

    AddToggleBtn("Spikes",
        function() return TIV.Editor3D.ShowSpikes end,
        function(v) TIV.Editor3D.ShowSpikes = v end,
        Color(45, 80, 120))

    AddToggleBtn("Armor",
        function() return TIV.Editor3D.ShowArmor end,
        function(v) TIV.Editor3D.ShowArmor = v end,
        Color(40, 110, 85))

    AddToggleBtn("Wire",
        function() return TIV.Editor3D.ShowWireframes end,
        function(v) TIV.Editor3D.ShowWireframes = v end,
        Color(120, 80, 45))

    AddToggleBtn("Gizmo",
        function() return TIV.Editor3D.ShowGizmo end,
        function(v) TIV.Editor3D.ShowGizmo = v end,
        Color(90, 50, 120))

    -- 6. Center View Button
    local centerBtn = vgui.Create("DButton", toolBar)
    centerBtn:Dock(RIGHT)
    centerBtn:DockMargin(4, 4, 4, 4)
    centerBtn:SetWide(86)
    centerBtn:SetText("Center View")
    centerBtn:SetTextColor(Color(220, 230, 245))
    centerBtn.Paint = function(s, w, h)
        draw.RoundedBox(3, 0, 0, w, h, s:IsHovered() and Color(60, 120, 200) or Color(32, 40, 56))
    end
    centerBtn.DoClick = function()
        if IsValid(modelPanel) and IsValid(modelPanel.Entity) then
            local rmn, rmx = modelPanel.Entity:GetRenderBounds()
            local center = (rmn + rmx) * 0.5
            local size   = (rmx - rmn):Length()
            modelPanel:SetLookAt(Vector(0, 0, center.z))
            local dist = math.Clamp(size * 1.35, 140, 480)
            modelPanel:SetCamPos(Vector(dist * 0.7, dist * 0.7, dist * 0.5 + center.z))
            modelPanel:SetFOV(42)
        end
    end

    -- Custom 3D Component Rendering & Coordinate Axes Gizmo
    modelPanel.PostDrawModel = function(self, ent)
        if not IsValid(ent) or not TIV.Editor3D.ActiveConfig then return end

        local config     = TIV.Editor3D.ActiveConfig
        local components = config.components or {}
        local selected   = TIV.Editor3D.SelectedIndex

        -- Render each component
        for idx, comp in ipairs(components) do
            local isSpike = (comp.type == "spike")
            local isArmor = (comp.type == "armor_side" or comp.type == "armor_front" or comp.type == "armor_roof")

            local shouldDraw = true
            if isSpike and not TIV.Editor3D.ShowSpikes then shouldDraw = false end
            if isArmor and not TIV.Editor3D.ShowArmor then shouldDraw = false end

            if shouldDraw then
                local mdl = comp.model or "models/props_junk/harpoon002a.mdl"
                local cs  = TIV.Editor3D.ClientsideModels[idx]

                if not IsValid(cs) or cs:GetModel() ~= mdl then
                    if IsValid(cs) then SafeRemoveEntity(cs) end
                    cs = ClientsideModel(mdl, RENDERGROUP_OPAQUE)
                    if IsValid(cs) then
                        cs:SetNoDraw(true)
                        TIV.Editor3D.ClientsideModels[idx] = cs
                    end
                end

                if IsValid(cs) then
                    local worldPos = ent:LocalToWorld(comp.pos or Vector(0, 0, 0))
                    local worldAng = ent:LocalToWorldAngles(comp.ang or Angle(0, 0, 0))

                    cs:SetPos(worldPos)
                    cs:SetAngles(worldAng)
                    if comp.scale then cs:SetModelScale(comp.scale.x or 1, 0) end

                    -- Material / Color tinting based on component type
                    local isSel = (idx == selected)
                    if isSel then
                        render.SetColorModulation(1.0, 0.85, 0.2) -- Vibrant Gold
                    elseif comp.type == "spike" then
                        render.SetColorModulation(0.6, 0.6, 0.65)
                    elseif comp.type == "armor_side" then
                        render.SetColorModulation(0.4, 0.7, 0.9)  -- Steel Blue
                    elseif comp.type == "armor_front" then
                        render.SetColorModulation(0.9, 0.5, 0.3)  -- Heavy Rust/Orange
                    else
                        render.SetColorModulation(0.8, 0.8, 0.8)
                    end

                    cs:DrawModel()
                    render.SetColorModulation(1, 1, 1)

                    -- Selected component highlight wireframe
                    if isSel or TIV.Editor3D.ShowWireframes then
                        local wCol = isSel and Color(255, 210, 40) or Color(80, 160, 240, 160)
                        render.DrawWireframeBox(worldPos, worldAng, cs:OBBMins(), cs:OBBMaxs(), wCol, true)
                    end
                end
            end
        end

        -- ====================================================================
        -- 3D VEHICLE COORDINATE AXES GIZMO
        -- Clearly shows Forward (+Y), Right (+X), and Up (+Z)
        -- ====================================================================
        if TIV.Editor3D.ShowGizmo then
            local mn, mx   = ent:GetRenderBounds()
            local gizmoPos = ent:LocalToWorld(Vector(0, mx.y * 0.75, math.max(12, mx.z * 0.35)))
            local fwdVec   = ent:GetForward()
            local rgtVec   = ent:GetRight()
            local upVec    = ent:GetUp()

            -- Forward Axis (RED)
            render.DrawLine(gizmoPos, gizmoPos + fwdVec * 40, Color(255, 60, 60), true)
            render.DrawWireframeSphere(gizmoPos + fwdVec * 40, 2, 6, 6, Color(255, 60, 60), true)

            -- Right Axis (GREEN)
            render.DrawLine(gizmoPos, gizmoPos + rgtVec * 40, Color(60, 255, 60), true)
            render.DrawWireframeSphere(gizmoPos + rgtVec * 40, 2, 6, 6, Color(60, 255, 60), true)

            -- Up Axis (BLUE)
            render.DrawLine(gizmoPos, gizmoPos + upVec * 40, Color(60, 140, 255), true)
            render.DrawWireframeSphere(gizmoPos + upVec * 40, 2, 6, 6, Color(60, 140, 255), true)
        end
    end

    -- Viewport overlay instructions
    local instructions = vgui.Create("DPanel", viewportPanel)
    instructions:SetPos(10, mainH - 36)
    instructions:SetSize(viewportW - 20, 26)
    instructions.Paint = function(s, w, h)
        draw.RoundedBox(3, 0, 0, w, h, Color(10, 14, 20, 200))
        draw.SimpleText("Camera Controls: Left-Click + Drag: Rotate  |  Right-Click + Drag / Wheel: Zoom  |  Middle-Click: Pan",
            "DermaDefault", 10, 6, Color(170, 190, 220), TEXT_ALIGN_LEFT)
    end

    -- ========================================================================
    -- RIGHT PANEL: CONTROLS & COMPONENT EDITING
    -- ========================================================================
    local rightPanel = vgui.Create("DScrollPanel", frame)
    rightPanel:SetPos(viewportW + 24, panelY)
    rightPanel:SetSize(rightWidth, mainH)
    rightPanel.Paint = function(s, w, h)
        draw.RoundedBox(6, 0, 0, w, h, Color(16, 20, 28, 255))
        draw.RoundedBox(4, 1, 1, w - 2, h - 2, Color(22, 28, 38, 255))
    end

    local controlsContainer = vgui.Create("DPanel", rightPanel)
    controlsContainer:Dock(TOP)
    controlsContainer:DockMargin(12, 12, 12, 12)
    controlsContainer.Paint = function() end

    -- Forward declarations.
    -- NOTE: RefreshEditor is declared at the TOP of this function, before the
    -- toolbar closures, so they capture the same local. Do not re-declare it
    -- here: a second `local` would shadow the outer one and the Mirror /
    -- Duplicate / Grid Snap buttons would silently stop refreshing again.
    local PopulateModelDropdown
    local SwitchToModel

    PopulateModelDropdown = function(combo, activeMdl)
        if not IsValid(combo) then return end
        combo:Clear()

        local presets = {
            { name = "HL2 Buggy / Jeep",         model = "models/buggy.mdl" },
            { name = "EP2 Jalopy / Muscle Car", model = "models/vehicle.mdl" },
            { name = "Combine APC",             model = "models/props_vehicles/apc001.mdl" },
            { name = "HL2 Airboat",             model = "models/airboat.mdl" },
            { name = "Van / Ambulance",         model = "models/props_vehicles/van.mdl" },
            { name = "Pickup Truck",            model = "models/props_vehicles/pickup01.mdl" },
        }

        local activeLower = string.lower(activeMdl or "")
        local matched = false

        for _, p in ipairs(presets) do
            local isSel = (activeLower == string.lower(p.model))
            if isSel then matched = true end
            combo:AddChoice(p.name .. " (" .. string.GetFileFromFilename(p.model) .. ")", p.model, isSel)
        end

        if TIV.GetIdentifiedInterceptors then
            local activeList = TIV.GetIdentifiedInterceptors()
            if #activeList > 0 then
                combo:AddSpacer()
                for _, info in ipairs(activeList) do
                    local isSel = (activeLower == string.lower(info.model))
                    if isSel then matched = true end
                    combo:AddChoice("[Active] " .. info.name, info.model, isSel)
                end
            end
        end

        if not matched and activeMdl and activeMdl ~= "" then
            combo:AddSpacer()
            combo:AddChoice("Custom: " .. string.GetFileFromFilename(activeMdl), activeMdl, true)
        end
    end

    SwitchToModel = function(targetModel)
        if not targetModel or string.Trim(targetModel) == "" then return end
        targetModel = string.lower(string.Trim(targetModel))

        -- Auto-save previous vehicle configuration before switching
        if TIV.Editor3D.ActiveConfig and TIV.Editor3D.ActiveConfig.vehicle_model then
            TIV.Editor3D.SaveConfigToFile(TIV.Editor3D.ActiveConfig)
        end

        curVehModel = targetModel

        -- Update model in 3D viewport
        if IsValid(modelPanel) then
            modelPanel:SetModel(curVehModel)
            if IsValid(modelPanel.Entity) then
                modelPanel.Entity:SetAngles(Angle(0, 0, 0))
                modelPanel.Entity:SetPos(Vector(0, 0, 0))

                local rmn, rmx = modelPanel.Entity:GetRenderBounds()
                local center = (rmn + rmx) * 0.5
                local size   = (rmx - rmn):Length()
                modelPanel:SetLookAt(Vector(0, 0, center.z))
                local dist = math.Clamp(size * 1.35, 140, 480)
                modelPanel:SetCamPos(Vector(dist * 0.7, dist * 0.7, dist * 0.5 + center.z))
            end
        end

        -- Load configuration for new model
        TIV.Editor3D.ActiveConfig = TIV.Editor3D.LoadConfigFromFile(curVehModel)
        TIV.Editor3D.ActiveConfig.vehicle_model = curVehModel
        TIV.Editor3D.SelectedIndex = 1

        -- Clear clientside preview models
        TIV.Editor3D.ClearClientsideModels()

        -- Synchronize UI inputs
        if IsValid(modelEntry) then
            modelEntry:SetText(curVehModel)
        end
        if IsValid(modelCombo) then
            PopulateModelDropdown(modelCombo, curVehModel)
        end

        if isfunction(RefreshEditor) then
            RefreshEditor()
        end
        surface.PlaySound("buttons/button14.wav")
    end

    -- Initial dropdown population and event wiring
    PopulateModelDropdown(modelCombo, curVehModel)

    modelCombo.OnSelect = function(s, idx, val, modelPath)
        if modelPath and modelPath ~= "" and string.lower(modelPath) ~= string.lower(curVehModel) then
            SwitchToModel(modelPath)
        end
    end

    modelEntry.OnEnter = function(s)
        local inputMdl = s:GetText()
        if inputMdl and inputMdl ~= "" and string.lower(inputMdl) ~= string.lower(curVehModel) then
            SwitchToModel(inputMdl)
        end
    end

    switchBtn.DoClick = function()
        local inputMdl = modelEntry:GetText()
        if inputMdl and inputMdl ~= "" then
            SwitchToModel(inputMdl)
        end
    end

    useVehBtn.DoClick = function()
        local targetEnt = (TIV.Deploy and TIV.Deploy.ResolveVehicle and TIV.Deploy.ResolveVehicle(LocalPlayer()))
        if not IsValid(targetEnt) then
            local tr = LocalPlayer():GetEyeTrace()
            if tr.Hit and IsValid(tr.Entity) and (TIV.IsSupportedVehicle(tr.Entity) or tr.Entity:IsVehicle()) then
                targetEnt = tr.Entity
            end
        end

        if IsValid(targetEnt) then
            local mdl = targetEnt:GetModel()
            if mdl and mdl ~= "" then
                SwitchToModel(mdl)
                Derma_Message("Loaded model from " .. (targetEnt:IsVehicle() and "vehicle" or "interceptor") .. ":\n" .. mdl, "Vehicle Detected", "OK")
                return
            end
        end

        Derma_Message("No vehicle or interceptor found in your cockpit or crosshairs.\nSit inside a vehicle or aim at one in the world.", "Vehicle Detection", "OK")
    end

    cloneBtn.DoClick = function()
        local menu = DermaMenu()
        local presets = {
            { name = "HL2 Buggy / Jeep",         model = "models/buggy.mdl" },
            { name = "EP2 Jalopy / Muscle Car", model = "models/vehicle.mdl" },
            { name = "Combine APC",             model = "models/props_vehicles/apc001.mdl" },
            { name = "HL2 Airboat",             model = "models/airboat.mdl" },
            { name = "Van / Ambulance",         model = "models/props_vehicles/van.mdl" },
            { name = "Pickup Truck",            model = "models/props_vehicles/pickup01.mdl" },
        }

        for _, p in ipairs(presets) do
            if string.lower(p.model) ~= string.lower(curVehModel) then
                menu:AddOption("Copy layout from " .. p.name, function()
                    local srcCfg = TIV.Editor3D.LoadConfigFromFile(p.model)
                    if srcCfg and istable(srcCfg.components) then
                        local clonedComponents = table.Copy(srcCfg.components)
                        TIV.Editor3D.ActiveConfig.components = clonedComponents
                        TIV.Editor3D.SelectedIndex = 1
                        TIV.Editor3D.ClearClientsideModels()
                        RefreshEditor()
                        surface.PlaySound("buttons/button15.wav")
                    end
                end)
            end
        end
        menu:Open()
    end

    tagBtn.DoClick = function()
        net.Start("TIV_TagAimedInterceptor")
        net.SendToServer()
        timer.Simple(0.25, function()
            if IsValid(modelCombo) then
                PopulateModelDropdown(modelCombo, curVehModel)
            end
        end)
    end

    RefreshEditor = function()
        controlsContainer:Clear()

        local config     = TIV.Editor3D.ActiveConfig
        local components = config.components or {}
        local selIdx     = math.Clamp(TIV.Editor3D.SelectedIndex, 1, math.max(1, #components))
        TIV.Editor3D.SelectedIndex = selIdx
        local curComp    = components[selIdx]

        -- Component Selection Dropdown & Header
        local selHeader = vgui.Create("DPanel", controlsContainer)
        selHeader:Dock(TOP)
        selHeader:DockMargin(0, 0, 0, 8)
        selHeader:SetTall(32)
        selHeader.Paint = function(s, w, h)
            draw.SimpleText("ACTIVE COMPONENT", "DermaDefaultBold", 0, 8, Color(240, 200, 50), TEXT_ALIGN_LEFT)
        end

        local compCombo = vgui.Create("DComboBox", controlsContainer)
        compCombo:Dock(TOP)
        compCombo:DockMargin(0, 0, 0, 8)
        compCombo:SetTall(28)

        for i, c in ipairs(components) do
            local tag = string.upper(c.type or "PROP")
            compCombo:AddChoice(string.format("[%d] %s (%s)", i, c.name or "Component", tag), i, i == selIdx)
        end
        compCombo.OnSelect = function(s, idx, val, data)
            TIV.Editor3D.SelectedIndex = data
            RefreshEditor()
        end

        -- Component Management Buttons: Add, Duplicate, Mirror, Delete
        local btnRow = vgui.Create("DPanel", controlsContainer)
        btnRow:Dock(TOP)
        btnRow:DockMargin(0, 0, 0, 12)
        btnRow:SetTall(30)
        btnRow.Paint = function() end

        local function AddActionBtn(label, color, onClick)
            local btn = vgui.Create("DButton", btnRow)
            btn:Dock(LEFT)
            btn:DockMargin(0, 0, 6, 0)
            btn:SetWide(96)
            btn:SetText(label)
            btn:SetTextColor(Color(240, 240, 240))
            btn.Paint = function(s, w, h)
                draw.RoundedBox(4, 0, 0, w, h, s:IsHovered() and Color(color.r + 20, color.g + 20, color.b + 20) or color)
            end
            btn.DoClick = onClick
        end

        AddActionBtn("+ Add Spike", Color(45, 75, 110), function()
            table.insert(components, {
                id    = "spike_" .. (#components + 1),
                type  = "spike",
                name  = "Custom Spike " .. (#components + 1),
                group = "mid",
                model = "models/props_junk/harpoon002a.mdl",
                pos   = Vector(25, 0, 0),
                ang   = Angle(90, 0, 0),
                scale = Vector(1, 1, 1),
            })
            TIV.Editor3D.SelectedIndex = #components
            RefreshEditor()
        end)

        AddActionBtn("+ Add Armor", Color(40, 95, 80), function()
            table.insert(components, {
                id    = "armor_" .. (#components + 1),
                type  = "armor_side",
                name  = "Metal Plate " .. (#components + 1),
                group = "side",
                model = "models/props_phx/construct/metal_plate1x2.mdl",
                pos   = Vector(38, -10, 0),
                ang   = Angle(0, 0, 90),
                scale = Vector(1, 1, 1),
            })
            TIV.Editor3D.SelectedIndex = #components
            RefreshEditor()
        end)

        -- Roof cowl, radar screen and hydraulic rams had no way to be created at
        -- all: "+ Add Armor" hardcodes armor_side and nothing else wrote a type,
        -- so roof_spoiler / path_screen / reinforced_hydraulics could not be laid
        -- out in the editor even once unlocked.
        local btnRow2 = vgui.Create("DPanel", controlsContainer)
        btnRow2:Dock(TOP)
        btnRow2:DockMargin(0, 0, 0, 12)
        btnRow2:SetTall(30)
        btnRow2.Paint = function() end
        local function AddActionBtn2(label, color, onClick)
            local btn = vgui.Create("DButton", btnRow2)
            btn:Dock(LEFT)
            btn:DockMargin(0, 0, 6, 0)
            btn:SetWide(96)
            btn:SetText(label)
            btn:SetTextColor(Color(240, 240, 240))
            btn.Paint = function(s, w, h)
                draw.RoundedBox(4, 0, 0, w, h, s:IsHovered() and Color(color.r + 20, color.g + 20, color.b + 20) or color)
            end
            btn.DoClick = onClick
        end

        AddActionBtn2("+ Add Roof", Color(95, 80, 40), function()
            table.insert(components, {
                id    = "armor_roof_" .. (#components + 1),
                type  = "armor_roof",
                name  = "Roof Cowl " .. (#components + 1),
                group = "roof",
                model = "models/props_phx/construct/metal_plate1x2.mdl",
                pos   = Vector(0, -20, 55),
                ang   = Angle(0, 90, 90),
                scale = Vector(1, 1, 1),
            })
            TIV.Editor3D.SelectedIndex = #components
            RefreshEditor()
        end)

        AddActionBtn2("+ Add Screen", Color(40, 80, 100), function()
            table.insert(components, {
                id    = "screen_" .. (#components + 1),
                type  = "radar_screen",
                name  = "Path Screen " .. (#components + 1),
                group = "interior",
                model = "models/kobilica/wiremonitorsmall.mdl",
                pos   = Vector(14, 14, 42),
                ang   = Angle(10, -125, 0),
                scale = Vector(1, 1, 1),
            })
            TIV.Editor3D.SelectedIndex = #components
            RefreshEditor()
        end)

        AddActionBtn2("+ Add Hydraulics", Color(100, 70, 45), function()
            table.insert(components, {
                id    = "hyd_" .. (#components + 1),
                type  = "hydraulic_ram",
                name  = "Hydraulic Ram " .. (#components + 1),
                group = "hydraulics",
                model = "models/props_c17/TrapPropeller_Lever.mdl",
                pos   = Vector(35, 0, 30),
                ang   = Angle(90, 0, 0),
                scale = Vector(1, 1, 1),
            })
            TIV.Editor3D.SelectedIndex = #components
            RefreshEditor()
        end)

        AddActionBtn("Duplicate", Color(80, 65, 120), function()
            if not curComp then return end
            local clone = table.Copy(curComp)
            clone.id    = clone.id .. "_copy"
            clone.name  = clone.name .. " (Copy)"
            clone.pos   = clone.pos + Vector(0, 5, 0)
            table.insert(components, clone)
            TIV.Editor3D.SelectedIndex = #components
            RefreshEditor()
        end)

        AddActionBtn("Mirror (X)", Color(110, 80, 40), function()
            if not curComp then return end
            local mirror = table.Copy(curComp)
            mirror.id    = mirror.id .. "_mirror"
            mirror.name  = mirror.name .. " (Mirrored)"
            mirror.pos   = Vector(-mirror.pos.x, mirror.pos.y, mirror.pos.z)
            if curComp.type == "spike" and math.abs(mirror.ang.p - 90) < 45 then
                mirror.ang = Angle(180 - mirror.ang.p, -mirror.ang.y, -mirror.ang.r)
            else
                mirror.ang = Angle(mirror.ang.p, mirror.ang.y, mirror.ang.r)
            end
            table.insert(components, mirror)
            TIV.Editor3D.SelectedIndex = #components
            RefreshEditor()
        end)

        if #components > 1 then
            local delBtn = vgui.Create("DButton", btnRow)
            delBtn:Dock(RIGHT)
            delBtn:SetWide(36)
            delBtn:SetText("DEL")
            delBtn:SetTextColor(Color(255, 120, 120))
            delBtn.Paint = function(s, w, h)
                draw.RoundedBox(4, 0, 0, w, h, s:IsHovered() and Color(180, 40, 40) or Color(70, 30, 30))
            end
            delBtn.DoClick = function()
                table.remove(components, selIdx)
                TIV.Editor3D.SelectedIndex = math.Clamp(selIdx - 1, 1, #components)
                TIV.Editor3D.ClearClientsideModels()
                RefreshEditor()
            end
        end

        if not curComp then return end

        -- Component Name & Model Section
        local metaPanel = vgui.Create("DPanel", controlsContainer)
        metaPanel:Dock(TOP)
        metaPanel:DockMargin(0, 0, 0, 10)
        metaPanel:SetTall(140)
        metaPanel.Paint = function(s, w, h)
            draw.RoundedBox(4, 0, 0, w, h, Color(16, 20, 28, 200))
            draw.SimpleText("Component Name", "DermaDefault", 10, 10, Color(180, 190, 210), TEXT_ALIGN_LEFT)
            draw.SimpleText("Model / Prop Path", "DermaDefault", 10, 48, Color(180, 190, 210), TEXT_ALIGN_LEFT)
            draw.SimpleText("Component Type", "DermaDefault", 10, 110, Color(180, 190, 210), TEXT_ALIGN_LEFT)
        end

        local nameEntry = vgui.Create("DTextEntry", metaPanel)
        nameEntry:SetPos(124, 6)
        nameEntry:SetSize(275, 24)
        nameEntry:SetText(curComp.name or "")
        nameEntry.OnChange = function(s)
            curComp.name = s:GetText()
        end

        local modelEntry = vgui.Create("DTextEntry", metaPanel)
        modelEntry:SetPos(124, 44)
        modelEntry:SetSize(275, 24)
        modelEntry:SetText(curComp.model or "")
        modelEntry.OnEnter = function(s)
            curComp.model = s:GetText()
        end

        -- Curated Model Dropdown Selector
        local curatedCombo = vgui.Create("DComboBox", metaPanel)
        curatedCombo:SetPos(124, 72)
        curatedCombo:SetSize(275, 22)
        curatedCombo:SetValue("Choose from curated presets...")

        local curatedList = TIV.CustomConfig.CuratedModels[curComp.type] or TIV.CustomConfig.CuratedModels.spikes
        for _, item in ipairs(curatedList) do
            curatedCombo:AddChoice(item.name, item.model)
        end
        curatedCombo.OnSelect = function(s, idx, val, modelPath)
            curComp.model = modelPath
            modelEntry:SetText(modelPath)
        end

        -- ====================================================================
        -- COMPONENT TYPE
        -- The type decides which upgrade gates the part (armor_roof needs
        -- roof_spoiler, hydraulic_ram needs reinforced_hydraulics, and so on), so
        -- it has to be editable or whole upgrades stay unplaceable.
        -- ====================================================================
        local typeCombo = vgui.Create("DComboBox", metaPanel)
        typeCombo:SetPos(124, 106)
        typeCombo:SetSize(275, 24)
        local typeChoices = {
            { label = "Spike (anchor)",      value = "spike" },
            { label = "Side Armor Panel",    value = "armor_side" },
            { label = "Front Armor Panel",   value = "armor_front" },
            { label = "Roof Cowl",           value = "armor_roof" },
            { label = "Hydraulic Ram",       value = "hydraulic_ram" },
            { label = "Radar / Path Screen", value = "radar_screen" },
        }
        local curType = curComp.type or "spike"
        for _, tc in ipairs(typeChoices) do
            typeCombo:AddChoice(tc.label, tc.value, tc.value == curType)
        end
        typeCombo.OnSelect = function(sel, idx, label, value)
            if value and value ~= curComp.type then
                curComp.type = value
                -- Rebuild so the curated model list matches the new type.
                TIV.Editor3D.ClearClientsideModels()
                RefreshEditor()
            end
        end

        -- ====================================================================
        -- POSITION CONTROLS (X, Y, Z)
        -- ====================================================================
        local posSection = vgui.Create("DPanel", controlsContainer)
        posSection:Dock(TOP)
        posSection:DockMargin(0, 0, 0, 10)
        posSection:SetTall(160)
        posSection.Paint = function(s, w, h)
            draw.RoundedBox(4, 0, 0, w, h, Color(16, 20, 28, 200))
            draw.SimpleText("POSITION (VEHICLE-RELATIVE)", "DermaDefaultBold", 10, 8, Color(240, 200, 50), TEXT_ALIGN_LEFT)
            draw.SimpleText("X: Right(+)/Left(-)   Y: Front(+)/Rear(-)   Z: Up(+)/Down(-)", "DermaDefault", 10, 24, Color(150, 165, 185), TEXT_ALIGN_LEFT)
        end

        local function BuildCoordRow(parent, label, axisKey, minVal, maxVal, yOffset)
            local lbl = vgui.Create("DLabel", parent)
            lbl:SetPos(10, yOffset)
            lbl:SetSize(82, 24)
            lbl:SetText(label)
            lbl:SetTextColor(Color(220, 225, 235))

            local numEntry = vgui.Create("DTextEntry", parent)
            numEntry:SetPos(96, yOffset)
            numEntry:SetSize(52, 24)
            numEntry:SetNumeric(true)
            numEntry:SetText(string.format("%.1f", curComp.pos[axisKey]))

            local slider = vgui.Create("DSlider", parent)
            slider:SetPos(154, yOffset + 4)
            slider:SetSize(156, 16)
            slider:SetSlideX(math.Remap(curComp.pos[axisKey], minVal, maxVal, 0, 1))

            local function UpdateVal(newVal)
                newVal = math.Clamp(newVal, minVal, maxVal)
                curComp.pos[axisKey] = newVal
                numEntry:SetText(string.format("%.1f", newVal))
                slider:SetSlideX(math.Remap(newVal, minVal, maxVal, 0, 1))
            end

            slider.OnValueChanged = function(s, x, y)
                local val = math.Remap(x, 0, 1, minVal, maxVal)
                curComp.pos[axisKey] = math.Round(val, 1)
                numEntry:SetText(string.format("%.1f", curComp.pos[axisKey]))
            end

            numEntry.OnEnter = function(s)
                local val = tonumber(s:GetText()) or 0
                UpdateVal(val)
            end

            -- Step nudge buttons using PrecisionStep
            local step = TIV.Editor3D.PrecisionStep or 1.0
            local stepLabel = (step < 1) and string.format("%.1f", step) or tostring(math.floor(step))

            local btnMinus = vgui.Create("DButton", parent)
            btnMinus:SetPos(316, yOffset)
            btnMinus:SetSize(36, 22)
            btnMinus:SetText("-" .. stepLabel)
            btnMinus.DoClick = function()
                local s = TIV.Editor3D.PrecisionStep or 1.0
                UpdateVal(curComp.pos[axisKey] - s)
            end

            local btnPlus = vgui.Create("DButton", parent)
            btnPlus:SetPos(356, yOffset)
            btnPlus:SetSize(36, 22)
            btnPlus:SetText("+" .. stepLabel)
            btnPlus.DoClick = function()
                local s = TIV.Editor3D.PrecisionStep or 1.0
                UpdateVal(curComp.pos[axisKey] + s)
            end
        end

        BuildCoordRow(posSection, "Pos X (R/L):", "x", -100, 100, 48)
        BuildCoordRow(posSection, "Pos Y (F/R):", "y", -160, 160, 84)
        BuildCoordRow(posSection, "Pos Z (U/D):", "z", -50,  80,  120)

        -- ====================================================================
        -- ROTATION CONTROLS (Pitch, Yaw, Roll)
        -- ====================================================================
        local rotSection = vgui.Create("DPanel", controlsContainer)
        rotSection:Dock(TOP)
        rotSection:DockMargin(0, 0, 0, 10)
        rotSection:SetTall(170)

        local isSpike = (curComp.type == "spike")
        local hasAngledUpg = TIV.Progression.IsUnlocked("angled_spikes")
        local isAngleLocked = isSpike and not hasAngledUpg

        if isAngleLocked then
            curComp.ang = Angle(90, 0, 0)
        end

        rotSection.Paint = function(s, w, h)
            draw.RoundedBox(4, 0, 0, w, h, Color(16, 20, 28, 200))
            draw.SimpleText("ROTATION (PITCH / YAW / ROLL)", "DermaDefaultBold", 10, 8, Color(240, 200, 50), TEXT_ALIGN_LEFT)
            if isAngleLocked then
                draw.SimpleText("[LOCKED: Requires Angled Spikes upgrade in Progression]", "DermaDefaultBold", 10, 24, Color(240, 100, 80), TEXT_ALIGN_LEFT)
            else
                draw.SimpleText("Pitch: Tilt forward/back  |  Yaw: Heading  |  Roll: Lean side-to-side", "DermaDefault", 10, 24, Color(150, 165, 185), TEXT_ALIGN_LEFT)
            end
        end

        local function BuildAngleRow(parent, label, angKey, yOffset)
            local lbl = vgui.Create("DLabel", parent)
            lbl:SetPos(10, yOffset)
            lbl:SetSize(82, 24)
            lbl:SetText(label)
            lbl:SetTextColor(Color(220, 225, 235))

            local numEntry = vgui.Create("DTextEntry", parent)
            numEntry:SetPos(96, yOffset)
            numEntry:SetSize(52, 24)
            numEntry:SetNumeric(true)
            numEntry:SetText(string.format("%.1f", curComp.ang[angKey]))
            numEntry:SetEnabled(not isAngleLocked)

            local slider = vgui.Create("DSlider", parent)
            slider:SetPos(154, yOffset + 4)
            slider:SetSize(156, 16)
            slider:SetSlideX(math.Remap(curComp.ang[angKey], -180, 180, 0, 1))
            slider:SetEnabled(not isAngleLocked)

            local function UpdateVal(newVal)
                if isAngleLocked then return end
                newVal = math.Clamp(newVal, -180, 180)
                curComp.ang[angKey] = newVal
                numEntry:SetText(string.format("%.1f", newVal))
                slider:SetSlideX(math.Remap(newVal, -180, 180, 0, 1))
            end

            slider.OnValueChanged = function(s, x, y)
                if isAngleLocked then return end
                local val = math.Remap(x, 0, 1, -180, 180)
                curComp.ang[angKey] = math.Round(val, 1)
                numEntry:SetText(string.format("%.1f", curComp.ang[angKey]))
            end

            numEntry.OnEnter = function(s)
                local val = tonumber(s:GetText()) or 0
                UpdateVal(val)
            end

            local step = (TIV.Editor3D.PrecisionStep or 1.0) * 5.0
            local stepLabel = (step < 1) and string.format("%.1f°", step) or (math.floor(step) .. "°")

            local btnMinus = vgui.Create("DButton", parent)
            btnMinus:SetPos(316, yOffset)
            btnMinus:SetSize(36, 22)
            btnMinus:SetText("-" .. stepLabel)
            btnMinus:SetEnabled(not isAngleLocked)
            btnMinus.DoClick = function()
                local s = (TIV.Editor3D.PrecisionStep or 1.0) * 5.0
                UpdateVal(curComp.ang[angKey] - s)
            end

            local btnPlus = vgui.Create("DButton", parent)
            btnPlus:SetPos(356, yOffset)
            btnPlus:SetSize(36, 22)
            btnPlus:SetText("+" .. stepLabel)
            btnPlus:SetEnabled(not isAngleLocked)
            btnPlus.DoClick = function()
                local s = (TIV.Editor3D.PrecisionStep or 1.0) * 5.0
                UpdateVal(curComp.ang[angKey] + s)
            end
        end

        BuildAngleRow(rotSection, "Pitch:", "p", 48)
        BuildAngleRow(rotSection, "Yaw:",   "y", 84)
        BuildAngleRow(rotSection, "Roll:",  "r", 120)

        -- Quick angle snap buttons
        local snapRow = vgui.Create("DPanel", controlsContainer)
        snapRow:Dock(TOP)
        snapRow:DockMargin(0, 0, 0, 10)
        snapRow:SetTall(28)
        snapRow.Paint = function() end

        local function AddSnapBtn(label, targetAng)
            local btn = vgui.Create("DButton", snapRow)
            btn:Dock(LEFT)
            btn:DockMargin(0, 0, 6, 0)
            btn:SetWide(110)
            btn:SetText(label)
            btn:SetEnabled(not isAngleLocked)
            btn.DoClick = function()
                curComp.ang = Angle(targetAng.p, targetAng.y, targetAng.r)
                RefreshEditor()
            end
        end

        AddSnapBtn("Straight Down", Angle(90, 0, 0))
        AddSnapBtn("Angled 10°",    (curComp.pos and curComp.pos.x > 0) and Angle(80, 0, 0) or Angle(100, 0, 0))
        AddSnapBtn("Angled 20°",    (curComp.pos and curComp.pos.x > 0) and Angle(70, 0, 0) or Angle(110, 0, 0))
        AddSnapBtn("Angled 30°",    (curComp.pos and curComp.pos.x > 0) and Angle(60, 0, 0) or Angle(120, 0, 0))
        AddSnapBtn("Flat 0°",       Angle(0, 0, 0))

        controlsContainer:InvalidateLayout(true)
        controlsContainer:SizeToChildren(false, true)
    end

    RefreshEditor()

    -- ========================================================================
    -- BOTTOM ACTION BAR: COPY, IMPORT, RESET, SAVE & APPLY
    -- ========================================================================
    local bottomBar = vgui.Create("DPanel", frame)
    bottomBar:SetPos(14, winH - 50)
    bottomBar:SetSize(winW - 28, 42)
    bottomBar.Paint = function(s, w, h)
        draw.RoundedBox(4, 0, 0, w, h, Color(14, 18, 25, 255))
    end

    local function AddFooterBtn(label, color, dockSide, onClick)
        local btn = vgui.Create("DButton", bottomBar)
        btn:Dock(dockSide)
        btn:DockMargin(6, 6, 6, 6)
        btn:SetWide(170)
        btn:SetText(label)
        btn:SetTextColor(Color(255, 255, 255))
        btn.Paint = function(s, w, h)
            draw.RoundedBox(4, 0, 0, w, h, s:IsHovered() and Color(color.r + 25, color.g + 25, color.b + 25) or color)
        end
        btn.DoClick = onClick
        return btn
    end

    -- COPY CONFIGURATION BUTTON
    AddFooterBtn("COPY CONFIGURATION", Color(35, 120, 90), LEFT, function()
        local luaCode = TIV.CustomConfig.SerializeToLua(TIV.Editor3D.ActiveConfig)
        SetClipboardText(luaCode)

        -- Display confirmation dialog with text area
        local exportWin = vgui.Create("DFrame")
        exportWin:SetSize(650, 480)
        exportWin:Center()
        exportWin:SetTitle("TIV EXPORTED CONFIGURATION (COPIED TO CLIPBOARD)")
        exportWin:MakePopup()

        local txt = vgui.Create("DTextEntry", exportWin)
        txt:Dock(FILL)
        txt:DockMargin(10, 10, 10, 40)
        txt:SetMultiline(true)
        txt:SetText(luaCode)

        local copyAgain = vgui.Create("DButton", exportWin)
        copyAgain:SetSize(160, 28)
        copyAgain:SetPos(exportWin:GetWide() - 170, exportWin:GetTall() - 34)
        copyAgain:SetText("Copy to Clipboard")
        copyAgain.DoClick = function()
            SetClipboardText(luaCode)
            surface.PlaySound("buttons/button14.wav")
        end
    end)

    -- IMPORT CONFIGURATION BUTTON
    AddFooterBtn("IMPORT CONFIGURATION", Color(55, 80, 140), LEFT, function()
        local importWin = vgui.Create("DFrame")
        importWin:SetSize(650, 480)
        importWin:Center()
        importWin:SetTitle("IMPORT TIV CONFIGURATION (PASTE LUA TABLE OR JSON)")
        importWin:MakePopup()

        local txt = vgui.Create("DTextEntry", importWin)
        txt:Dock(FILL)
        txt:DockMargin(10, 10, 10, 40)
        txt:SetMultiline(true)
        txt:SetPlaceholderText("Paste your exported Lua configuration or JSON code here...")

        local applyBtn = vgui.Create("DButton", importWin)
        applyBtn:SetSize(180, 28)
        applyBtn:SetPos(importWin:GetWide() - 190, importWin:GetTall() - 34)
        applyBtn:SetText("Parse & Apply to Editor")
        applyBtn.DoClick = function()
            local raw = txt:GetText()
            local imported, err = TIV.CustomConfig.DeserializeFromLua(raw)
            if imported and istable(imported.components) then
                if imported.vehicle_model and string.lower(imported.vehicle_model) ~= string.lower(curVehModel) then
                    SwitchToModel(imported.vehicle_model)
                end
                TIV.Editor3D.ActiveConfig = imported
                TIV.Editor3D.ActiveConfig.vehicle_model = curVehModel
                TIV.Editor3D.SelectedIndex = 1
                TIV.Editor3D.ClearClientsideModels()
                RefreshEditor()
                importWin:Close()
                surface.PlaySound("garrysmod/save_load1.wav")
            else
                Derma_Message("Import Failed: " .. (err or "Invalid configuration syntax"), "Import Error", "OK")
            end
        end
    end)

    -- RESET TO DEFAULTS BUTTON
    AddFooterBtn("RESET TO DEFAULTS", Color(90, 40, 40), LEFT, function()
        Derma_Query("Reset all components back to factory defaults for " .. string.GetFileFromFilename(curVehModel) .. "?", "Confirm Reset",
            "Reset", function()
                TIV.Editor3D.ActiveConfig = TIV.CustomConfig.GetDefaultConfig(curVehModel)
                TIV.Editor3D.SelectedIndex = 1
                TIV.Editor3D.ClearClientsideModels()
                RefreshEditor()
            end,
            "Cancel", function() end
        )
    end)

    -- SAVE & APPLY TO VEHICLE
    AddFooterBtn("SAVE & APPLY TO VEHICLE", Color(180, 120, 20), RIGHT, function()
        local config = TIV.Editor3D.ActiveConfig
        config.vehicle_model = curVehModel
        TIV.Editor3D.SaveConfigToFile(config)

        local luaStr = TIV.CustomConfig.SerializeToLua(config)
        net.Start("TIV_ApplyVehicleConfig")
            net.WriteString(luaStr)
        net.SendToServer()

        surface.PlaySound("garrysmod/save_load1.wav")
        frame:Close()
    end)
end

concommand.Add("tiv_editor", function()
    TIV.Editor3D.Open()
end)

print("[TIV] 3D Interceptor Configuration Editor loaded")
