AddCSLuaFile()

DEFINE_BASECLASS("base_wire_entity")

ENT.Type            = "anim"
ENT.PrintName       = "Wire TIV Controller"
ENT.Author          = "TIV Team"
ENT.WireDebugName   = "TIV Controller"

local hasWire = istable(rawget(_G, "WireLib")) and scripted_ents.Get("base_wire_entity") ~= nil
ENT.Base            = hasWire and "base_wire_entity" or "base_gmodentity"
ENT.Spawnable       = hasWire
ENT.AdminOnly       = false
ENT.IsWire          = true

local function GetBaseClass()
    if istable(BaseClass) then return BaseClass end
    if istable(baseclass) and isfunction(baseclass.Get) then
        local b = baseclass.Get(ENT.Base or "base_wire_entity")
        if istable(b) then return b end
        b = baseclass.Get("base_gmodentity")
        if istable(b) then return b end
    end
    return nil
end

local function CallBase(self, method, ...)
    local base = GetBaseClass()
    if base and isfunction(base[method]) then
        return base[method](self, ...)
    end
end

if CLIENT then
    function ENT:Initialize()
        CallBase(self, "Initialize")
        self.NextRBUpdate = CurTime() + 0.25
    end

    -- Wire world-tip overlay formatting
    function ENT:GetOverlayText()
        local header = "- " .. (self.PrintName or "TIV Controller") .. " -"
        local data = isfunction(self.GetOverlayData) and self:GetOverlayData()
        if data and data.txt then
            return data.txt
        end
        return header
    end

    return -- No more client code in this file
end

function ENT:Initialize()
    CallBase(self, "Initialize")

    if not self:GetModel() or self:GetModel() == "" or self:GetModel() == "models/error.mdl" then
        local sirenModel = "models/jaanus/wiretool/wiretool_siren.mdl"
        local fallbackModel = "models/props_lab/reciever01a.mdl"
        if util.IsValidModel(sirenModel) then
            self:SetModel(sirenModel)
        else
            self:SetModel(fallbackModel)
        end
    end

    self:PhysicsInit(SOLID_VPHYSICS)
    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:SetSolid(SOLID_VPHYSICS)

    local phys = self:GetPhysicsObject()
    if IsValid(phys) then
        phys:Wake()
    end

    if TIV and TIV.Wire and TIV.Wire.SetupPorts then
        TIV.Wire.SetupPorts(self)
    end

    if TIV and TIV.Wire and TIV.Wire.RegisterController then
        TIV.Wire.RegisterController(self, self.Vehicle)
    end

    self:UpdateOverlay()
end

function ENT:LinkEnt(veh)
    if not IsValid(veh) then return false, "Invalid vehicle" end
    if not (TIV and TIV.IsSupportedVehicle and TIV.IsSupportedVehicle(veh)) then
        if TIV and TIV.TagAsInterceptor then
            TIV.TagAsInterceptor(veh, true)
        else
            return false, "Entity is not a supported TIV vehicle"
        end
    end

    local ply = self:GetPlayer()
    if IsValid(ply) and TIV.Wire and TIV.Wire.CanControl and not TIV.Wire.CanControl(ply, veh) then
        return false, "You do not have permission to control this TIV"
    end

    self.Vehicle = veh

    local wire = rawget(_G, "WireLib")
    if istable(wire) then
        if isfunction(wire.SendMarks) then wire.SendMarks(self, { veh }) end
        if isfunction(wire.TriggerOutput) then wire.TriggerOutput(self, "Vehicle", veh) end
    end

    if self.ColorByLinkStatus then
        self:ColorByLinkStatus(self.LINK_STATUS_ACTIVE)
    end

    if TIV.Wire and TIV.Wire.RegisterController then
        TIV.Wire.RegisterController(self, veh)
    end

    if TIV.Wire and TIV.Wire.UpdateOutputs then
        TIV.Wire.UpdateOutputs(veh)
    end

    self:UpdateOverlay()
    return true
end

function ENT:UnlinkEnt()
    self.Vehicle = nil

    local wire = rawget(_G, "WireLib")
    if istable(wire) then
        if isfunction(wire.SendMarks) then wire.SendMarks(self, {}) end
        if isfunction(wire.TriggerOutput) then wire.TriggerOutput(self, "Vehicle", NULL) end
    end

    if self.ColorByLinkStatus then
        self:ColorByLinkStatus(self.LINK_STATUS_UNLINKED)
    end

    if TIV.Wire and TIV.Wire.UnregisterController then
        TIV.Wire.UnregisterController(self)
    end

    if TIV.Wire and TIV.Wire.ResetOutputsForEnt then
        TIV.Wire.ResetOutputsForEnt(self)
    end

    self:UpdateOverlay()
    return true
end

function ENT:ClearEntities()
    return self:UnlinkEnt()
end

function ENT:TriggerInput(iname, value)
    if TIV and TIV.Wire and TIV.Wire.HandleInput then
        TIV.Wire.HandleInput(self, iname, value, self.Vehicle)
    end
end

function ENT:UpdateOverlay()
    if not IsValid(self.Vehicle) then
        self:SetOverlayText("- TIV Controller -\n(Unlinked - Aim with Wire Tool to Link)")
        return
    end

    local veh = self.Vehicle
    local data = TIV.Deploy and TIV.Deploy.GetState and TIV.Deploy.GetState(veh)
    local state = (data and data.state or "idle"):upper()
    local wind = math.Round((TIV.Wind and TIV.Wind.GetSpeed and TIV.Wind.GetSpeed(veh)) or 0)
    local stress = (data and data.state == "anchored" and TIV.Loft and TIV.Loft.CalculateStress)
        and math.Round(TIV.Loft.CalculateStress(wind) * 100) or 0
    local spikeCount = (data and TIV.Spikes and TIV.Spikes.GetCount and TIV.Spikes.GetCount(data)) or 0
    local activeSpikes = 0
    for _, sd in ipairs(data and data.spikes or {}) do
        if IsValid(sd.entity) and sd.phase == "deployed" then
            activeSpikes = activeSpikes + 1
        end
    end

    local phys = veh:GetPhysicsObject()
    local spd = IsValid(phys) and math.Round(phys:GetVelocity():Length() * 0.0568182) or 0
    local alt = math.Round(veh:GetPos().z)

    local txt = string.format(
        "- TIV Controller -\nVehicle: %s [#%d]\nState: %s\nWind: %d MPH\nStress: %d%%\nSpikes: %d / %d\nSpeed: %d MPH\nAltitude: %d",
        veh:GetClass(),
        veh:EntIndex(),
        state,
        wind,
        stress,
        activeSpikes,
        spikeCount,
        spd,
        alt
    )
    self:SetOverlayText(txt)
end

function ENT:Think()
    CallBase(self, "Think")

    if not self.NextOverlayUpdate or CurTime() >= self.NextOverlayUpdate then
        self.NextOverlayUpdate = CurTime() + 0.2
        self:UpdateOverlay()
    end

    self:NextThink(CurTime() + 0.1)
    return true
end

function ENT:OnRemove()
    local wire = rawget(_G, "WireLib")
    if istable(wire) and isfunction(wire.Remove) then
        wire.Remove(self)
    end

    if TIV and TIV.Wire and TIV.Wire.UnregisterController then
        TIV.Wire.UnregisterController(self)
    end

    if IsValid(self.Vehicle) and self.Vehicle.TIVWireController == self then
        self.Vehicle.TIVWireController = nil
    end

    CallBase(self, "OnRemove")
end

function ENT:OnRestore()
    local wire = rawget(_G, "WireLib")
    if istable(wire) and isfunction(wire.Restored) then
        wire.Restored(self)
    end
    CallBase(self, "OnRestore")
end

function ENT:BuildDupeInfo()
    local info = CallBase(self, "BuildDupeInfo")
    if not istable(info) then
        local wire = rawget(_G, "WireLib")
        if istable(wire) and isfunction(wire.BuildDupeInfo) then
            info = wire.BuildDupeInfo(self)
        end
    end
    info = info or {}

    if IsValid(self.Vehicle) then
        info.Vehicle = self.Vehicle:EntIndex()
    end
    info.IsAutoAttached = self.IsAutoAttached
    return info
end

function ENT:ApplyDupeInfo(ply, ent, info, GetEntByID)
    CallBase(self, "ApplyDupeInfo", ply, ent, info, GetEntByID)
    if info and info.Vehicle and isfunction(GetEntByID) then
        local target = GetEntByID(info.Vehicle)
        if IsValid(target) then
            self:LinkEnt(target)
        end
    end
    if info and info.IsAutoAttached then
        self.IsAutoAttached = true
    end
end

if istable(rawget(_G, "WireLib")) and isfunction(WireLib.MakeWireEnt) then
    duplicator.RegisterEntityClass("gmod_wire_tiv_controller", WireLib.MakeWireEnt, "Data")
    duplicator.RegisterEntityClass("gmod_wire_tiv", WireLib.MakeWireEnt, "Data")
    scripted_ents.Register(ENT, "gmod_wire_tiv")
end
