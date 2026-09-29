-- Minimal Garry's Mod API surface for executing the TIV anchor / loft / ground
-- pierce modules headlessly. Run via tools/harness/run_anchor_tests.js.
--
-- Models the engine behaviours that have already caused real bugs here:
--   * no physics object exists until the entity has a model (GetPhysicsObject
--     returns NULL, and calling anything on it raises);
--   * Source's exact Angle basis, so aiming and local-space maths can be checked;
--   * constraint.AdvBallsocket only ever sets the constraint's POSITION, never
--     its angles -- exactly as garrysmod/lua/includes/modules/constraint.lua does.

local V = {}
V.__index = V
local function newvec(x, y, z) return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, V) end
Vector = newvec
vector_origin = newvec(0, 0, 0)
function V.__add(a, b) return newvec(a.x + b.x, a.y + b.y, a.z + b.z) end
function V.__sub(a, b) return newvec(a.x - b.x, a.y - b.y, a.z - b.z) end
function V.__mul(a, b)
    if type(a) == "number" then return newvec(b.x * a, b.y * a, b.z * a) end
    if type(b) == "number" then return newvec(a.x * b, a.y * b, a.z * b) end
    return newvec(a.x * b.x, a.y * b.y, a.z * b.z)
end
function V.__div(a, b) return newvec(a.x / b, a.y / b, a.z / b) end
function V.__unm(a) return newvec(-a.x, -a.y, -a.z) end
function V.__eq(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end
function V.__tostring(a) return string.format("%.2f %.2f %.2f", a.x, a.y, a.z) end
function V:LengthSqr() return self.x * self.x + self.y * self.y + self.z * self.z end
function V:Length() return math.sqrt(self:LengthSqr()) end
function V:Dot(o) return self.x * o.x + self.y * o.y + self.z * o.z end
function V:Cross(o) return newvec(self.y * o.z - self.z * o.y, self.z * o.x - self.x * o.z, self.x * o.y - self.y * o.x) end
function V:GetNormalized()
    local l = self:Length()
    if l < 0.000001 then return newvec(0, 0, 0) end
    return newvec(self.x / l, self.y / l, self.z / l)
end
function V:Distance(o) return (self - o):Length() end
function isvector(v) return getmetatable(v) == V end
function VectorRand() return newvec(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) end

local A = {}
A.__index = A
function Angle(p, y, r) return setmetatable({ p = p or 0, y = y or 0, r = r or 0 }, A) end
function A:Forward()
    local p, y = math.rad(self.p), math.rad(self.y)
    return newvec(math.cos(p) * math.cos(y), math.cos(p) * math.sin(y), -math.sin(p))
end
function A:Right()
    local p, y, r = math.rad(self.p), math.rad(self.y), math.rad(self.r)
    local cp, sp, cy, sy, cr, sr = math.cos(p), math.sin(p), math.cos(y), math.sin(y), math.cos(r), math.sin(r)
    return newvec(cy * sp * sr + sy * cr, sy * sp * sr - cy * cr, cp * sr)
end
function A:Up()
    local p, y, r = math.rad(self.p), math.rad(self.y), math.rad(self.r)
    local cp, sp, cy, sy, cr, sr = math.cos(p), math.sin(p), math.cos(y), math.sin(y), math.cos(r), math.sin(r)
    return newvec(cy * sp * cr - sy * sr, sy * sp * cr + cy * sr, cp * cr)
end
function isangle(a) return getmetatable(a) == A end

function istable(v) return type(v) == "table" end
function isfunction(v) return type(v) == "function" end
function isnumber(v) return type(v) == "number" end
function isstring(v) return type(v) == "string" end
function isentity(v) return type(v) == "table" and v.__isEntity == true end
function tobool(v)
    if v == nil or v == false then return false end
    if type(v) == "number" then return v ~= 0 end
    if type(v) == "string" then return v ~= "0" and v ~= "false" and v ~= "" end
    return true
end
function IsValid(e) return e ~= nil and e.__isEntity == true and e.__removed ~= true and e.__isNull ~= true end
function Color(r, g, b, a) return { r = r, g = g, b = b, a = a } end
function math.Clamp(v, lo, hi) if v < lo then return lo end if v > hi then return hi end return v end
function math.Round(v, d) local m = 10 ^ (d or 0) return math.floor(v * m + 0.5) / m end
function math.Rand(a, b) return a + (b - a) * math.random() end
math.atan2 = math.atan2 or math.atan

PHYS_MT = {}
PHYS_MT.__index = PHYS_MT
NULL_PHYS = setmetatable({ __isEntity = true, __isNull = true, __removed = false }, {
    __index = function(_, k) error("Tried to use a NULL physics object! (" .. tostring(k) .. ")", 2) end,
})

ENT_MT = {}
ENT_MT.__index = ENT_MT
local entIndexCounter = 0
ENT_REGISTRY = {}
local worldEntity
function Entity(idx) return ENT_REGISTRY[idx] end

local function makeEntity(class)
    entIndexCounter = entIndexCounter + 1
    local e = setmetatable({
        __isEntity = true, __index = entIndexCounter, __class = class or "prop_physics",
        __model = nil, __pos = newvec(0, 0, 0), __ang = Angle(0, 0, 0), __parent = nil,
        __constraints = {}, __nw = {}, __mass = 25, __motion = true, __gravity = true,
        __collision = true, __asleep = false, __vel = newvec(0, 0, 0), __angvel = newvec(0, 0, 0),
        __mins = newvec(-20, -20, -10), __maxs = newvec(20, 20, 10), __removed = false,
    }, ENT_MT)
    ENT_REGISTRY[entIndexCounter] = e
    return e
end

function ENT_MT:EntIndex() return self.__index end
function ENT_MT:GetClass() return self.__class end
function ENT_MT:GetPos() return self.__pos end
function ENT_MT:SetPos(p) self.__pos = p; if self.__phys then self.__phys.__pos = p end end
function ENT_MT:GetAngles() return self.__ang end
function ENT_MT:SetAngles(a) self.__ang = a; if self.__phys then self.__phys.__ang = a end end
function ENT_MT:GetModel() return self.__model end
function ENT_MT:SetModel(m) self.__model = m end
function ENT_MT:GetParent() return self.__parent end
function ENT_MT:SetParent(p) self.__parent = p end
function ENT_MT:IsWorld() return self == worldEntity end
function ENT_MT:IsPlayer() return self.__class == "player" end
function ENT_MT:IsVehicle() return string.find(self.__class, "vehicle") ~= nil end
function ENT_MT:OBBMins() return self.__mins end
function ENT_MT:OBBMaxs() return self.__maxs end
function ENT_MT:GetModelBounds() return self.__mins, self.__maxs end
-- Runs the SENT's Initialize body; for the grabber that is the real
-- gmod_wire_grabber.lua:17-26 including the SetMass that needs a model.
function ENT_MT:Spawn()
    if self.__class == "gmod_wire_grabber" then
        self.WeldStrength = 0
        self.Weld = nil
        self.WeldEntity = nil
        self.Gravity = true
        self:GetPhysicsObject():SetMass(10)
        self:Setup(100, true)
    end
end
function ENT_MT:Activate() end
function ENT_MT:Remove()
    if self.__kind and self.__live then
        self.__live = false
        if self.Ent1 and self.Ent1.__constraints then self.Ent1.__constraints[self] = nil end
        if self.Ent2 and self.Ent2.__constraints then self.Ent2.__constraints[self] = nil end
    end
    self.__removed = true
    hook.Run("EntityRemoved", self)
end
function ENT_MT:IsConstrained() return next(self.__constraints) ~= nil end
function ENT_MT:EmitSound() end
function ENT_MT:SetNWBool(k, v) self.__nw[k] = v end
function ENT_MT:GetNWBool(k, d) local v = self.__nw[k]; if v == nil then return d end; return v end
function ENT_MT:SetNWEntity(k, v) self.__nw[k] = v end
function ENT_MT:SetOwner(o) self.__owner = o end
function ENT_MT:GetOwner() return self.__owner end
function ENT_MT:SetCollisionGroup(g) self.__collgroup = g end
function ENT_MT:SetMoveType(t) self.__movetype = t end
function ENT_MT:SetNoDraw() end
function ENT_MT:DrawShadow() end
function ENT_MT:SetColor() end
function ENT_MT:GetColor() return Color(255, 255, 255, 255) end
function ENT_MT:SetMaterial() end
function ENT_MT:SetSolid() end
function ENT_MT:PhysicsInit() end
function ENT_MT:Fire() end
function ENT_MT:SetKeyValue() end
function ENT_MT:SetLocalPos(p) self.__localpos = p end
function ENT_MT:GetLocalPos() return self.__localpos or newvec(0, 0, 0) end
function ENT_MT:SetLocalAngles(a) self.__localang = a end
function ENT_MT:SetHandbrake(b) self.__handbrake = b end
function ENT_MT:GetVelocity() return self.__vel end
function ENT_MT:GetUp() return self.__ang:Up() end
function ENT_MT:GetForward() return self.__ang:Forward() end
function ENT_MT:GetRight() return self.__ang:Right() end
function ENT_MT:DeleteOnRemove() end
function ENT_MT:SetBeamLength(l) self.__beam = l end
function ENT_MT:GetBeamLength() return self.__beam or 100 end
function ENT_MT:LocalToWorld(v)
    local a = self.__ang
    return self.__pos + a:Forward() * v.x + a:Right() * v.y + a:Up() * v.z
end
function ENT_MT:WorldToLocal(v)
    local a = self.__ang
    local d = v - self.__pos
    return newvec(d:Dot(a:Forward()), d:Dot(a:Right()), d:Dot(a:Up()))
end
function ENT_MT:LocalToWorldAngles(a) return Angle(self.__ang.p + a.p, self.__ang.y + a.y, self.__ang.r + a.r) end
function ENT_MT:WorldToLocalAngles(a) return Angle(a.p - self.__ang.p, a.y - self.__ang.y, a.r - self.__ang.r) end
function ENT_MT:GetPhysicsObject()
    if not self.__model then return NULL_PHYS end
    if not self.__phys then
        self.__phys = setmetatable({ __ent = self, __pos = self.__pos, __ang = self.__ang, __isEntity = true }, PHYS_MT)
    end
    return self.__phys
end
function ENT_MT:GetPhysicsObjectNum() return self:GetPhysicsObject() end
function PHYS_MT:GetMass() return self.__ent.__mass end
function PHYS_MT:SetMass(m) self.__ent.__mass = m end
function PHYS_MT:EnableMotion(b) self.__ent.__motion = b end
function PHYS_MT:IsMotionEnabled() return self.__ent.__motion end
function PHYS_MT:EnableGravity(b) self.__ent.__gravity = b end
function PHYS_MT:IsGravityEnabled() return self.__ent.__gravity end
function PHYS_MT:EnableCollisions(b) self.__ent.__collision = b end
function PHYS_MT:IsAsleep() return self.__ent.__asleep end
function PHYS_MT:Wake() self.__ent.__asleep = false end
function PHYS_MT:GetVelocity() return self.__ent.__vel end
function PHYS_MT:SetVelocity(v) self.__ent.__vel = v end
function PHYS_MT:SetAngleVelocity(v) self.__ent.__angvel = v end
function PHYS_MT:GetAngleVelocity() return self.__ent.__angvel end
function PHYS_MT:SetPos(p) self.__ent.__pos = p end
function PHYS_MT:SetAngles(a) self.__ent.__ang = a end
function PHYS_MT:ApplyForceCenter() end
function PHYS_MT:ApplyForceOffset() end
function PHYS_MT:ApplyTorqueCenter() end
function PHYS_MT:LocalToWorld(v) return self.__ent:LocalToWorld(v) end
function PHYS_MT:WorldToLocal(v) return self.__ent:WorldToLocal(v) end

constraint = {}
local function newConstraint(kind, e1, e2, fields)
    local c = makeEntity("phys_" .. kind)
    c.__model = "models/props_junk/cardboard_box004a.mdl"
    c.__kind = kind
    c.Ent1 = e1
    c.Ent2 = e2
    c.Type = kind
    c.__live = true
    for k, v in pairs(fields or {}) do c[k] = v end
    if e1 and e1.__constraints then e1.__constraints[c] = true end
    if e2 and e2.__constraints then e2.__constraints[c] = true end
    return c
end
function constraint.Weld(e1, e2, b1, b2, forcelimit, nocollide)
    return newConstraint("weld", e1, e2, { forcelimit = forcelimit or 0, nocollide = nocollide })
end
function constraint.NoCollide(e1, e2, b1, b2)
    if constraint.Find(e1, e2, "NoCollide", b1 or 0, b2 or 0) then return false end
    return newConstraint("logic_collision_pair", e1, e2, { Type = "NoCollide" })
end
function constraint.AdvBallsocket(e1, e2, b1, b2, lp1, lp2, forcelimit, torquelimit,
                                  xmin, ymin, zmin, xmax, ymax, zmax, xfric, yfric, zfric,
                                  onlyrotation, nocollide)
    if e1 == e2 then return false end
    return newConstraint("phys_ragdollconstraint", e1, e2, {
        Type = "AdvBallsocket", LPos1 = lp1, LPos2 = lp2,
        WPos1 = e1:GetPhysicsObject():LocalToWorld(lp1),
        forcelimit = forcelimit or 0, torquelimit = torquelimit or 0,
        xmin = xmin, xmax = xmax, ymin = ymin, ymax = ymax, zmin = zmin, zmax = zmax,
        xfric = xfric or 0, yfric = yfric or 0, zfric = zfric or 0,
        onlyrotation = onlyrotation or 0,
        nocollide = nocollide,
    })
end
-- Mirrors the real Elastic: LPos1 is honoured via Phys1:LocalToWorld(LPos1),
-- LPos2 via Phys2:LocalToWorld(LPos2) -- world space when Ent2 is the world.
function constraint.Elastic(e1, e2, b1, b2, lp1, lp2, constant, damping, rdamping, material, width, stretchonly)
    if e1 == e2 then return false end
    return newConstraint("phys_spring", e1, e2, {
        Type = "Elastic", LPos1 = lp1, LPos2 = lp2,
        constant = constant, damping = damping, stretchonly = stretchonly,
    })
end
function constraint.Find(e1, e2, kind)
    if not e1 or not e1.__constraints then return nil end
    for c in pairs(e1.__constraints) do
        if c.__live and c.Type == kind then
            if (c.Ent1 == e1 and c.Ent2 == e2) or (c.Ent1 == e2 and c.Ent2 == e1) then return c end
        end
    end
    return nil
end
function constraint.GetTable(e)
    local out = {}
    if not e or not e.__constraints then return out end
    for c in pairs(e.__constraints) do if c.__live then out[#out + 1] = c end end
    return out
end
function constraint.RemoveAll(e)
    if not e or not e.__constraints then return end
    for c in pairs(e.__constraints) do
        c.__live = false
        c.__removed = true
        if c.Ent1 and c.Ent1.__constraints then c.Ent1.__constraints[c] = nil end
        if c.Ent2 and c.Ent2.__constraints then c.Ent2.__constraints[c] = nil end
    end
    e.__constraints = {}
end

SPIKE_REGISTRY = {}
scripted_ents = { __stored = {} }
function scripted_ents.GetStored(name) return scripted_ents.__stored[name] end
function scripted_ents.Get(name) return scripted_ents.__stored[name] end

ents = {}
function ents.Create(class)
    local e = makeEntity(class)
    if class == "gmod_wire_grabber" then
        function e:Setup(range, grav) self:SetBeamLength(range); self.Gravity = grav end
        function e:TriggerInput(iname, value)
            if iname == "Strength" then
                self.WeldStrength = math.max(value or 0, 0)
            elseif iname == "Grab" then
                if value ~= 0 and self.Weld == nil then
                    local up = self.__ang:Up()
                    local best, bestDot = nil, 0.995
                    for _, sp in ipairs(SPIKE_REGISTRY) do
                        if IsValid(sp) then
                            local to = sp:GetPos() - self.__pos
                            local len = to:Length()
                            if len > 0.001 and len <= (self.__beam or 100) then
                                local d = to:GetNormalized():Dot(up)
                                if d > bestDot then bestDot = d; best = sp end
                            end
                        end
                    end
                    self.WeldEntity = best
                    if not IsValid(self.WeldEntity) then return end
                    self.Weld = constraint.Weld(self, self.WeldEntity, 0, 0, self.WeldStrength)
                elseif value == 0 and self.Weld ~= nil then
                    if IsValid(self.Weld) then self.Weld:Remove() end
                    self.Weld = nil
                    self.WeldEntity = nil
                end
            end
        end
    end
    return e
end
function ents.FindByClass() return {} end
function ents.GetAll() return {} end

VALID_MODELS = {
    ["models/jaanus/wiretool/wiretool_grabber_forcer.mdl"] = true,
    ["models/jaanus/wiretool/wiretool_range.mdl"] = true,
    ["models/props_junk/plasticcrate01a.mdl"] = true,
    ["models/props_junk/harpoon002a.mdl"] = true,
    ["models/props_c17/oildrum001.mdl"] = true,
}
util = {}
function util.AddNetworkString() end
function util.IsValidModel(m) return VALID_MODELS[m] == true end
function util.TraceLine(t)
    if t.start.z > 0 and t.endpos.z <= 0 then
        return { Hit = true, HitPos = newvec(t.start.x, t.start.y, 0), HitNormal = newvec(0, 0, 1), StartSolid = false, Entity = worldEntity }
    end
    return { Hit = false, StartSolid = false, Entity = worldEntity }
end
function util.Effect() end
function util.ScreenShake() end

net = { __sent = {} }
function net.Start(name) net.__current = { name = name, writes = {} } end
function net.WriteEntity(e) table.insert(net.__current.writes, e) end
function net.WriteUInt(v) table.insert(net.__current.writes, v) end
function net.WriteString(s) table.insert(net.__current.writes, s) end
function net.WriteVector(v) table.insert(net.__current.writes, v) end
function net.WriteFloat(v) table.insert(net.__current.writes, v) end
function net.Broadcast() net.__sent[#net.__sent + 1] = net.__current end
function net.Receive() end

hook = { __hooks = {} }
function hook.Add(ev, name, fn) hook.__hooks[ev] = hook.__hooks[ev] or {}; hook.__hooks[ev][name] = fn end
function hook.Remove(ev, name) if hook.__hooks[ev] then hook.__hooks[ev][name] = nil end end
function hook.Run(ev, ...)
    if not hook.__hooks[ev] then return end
    for _, fn in pairs(hook.__hooks[ev]) do fn(...) end
end

timer = { __timers = {}, __simple = {} }
function timer.Create(name, delay, reps, fn) timer.__timers[name] = { delay = delay, fn = fn } end
function timer.Simple(delay, fn) timer.__simple[#timer.__simple + 1] = { delay = delay, fn = fn } end
function timer.Remove(name) timer.__timers[name] = nil end
function timer.Exists(name) return timer.__timers[name] ~= nil end

local convars = {}
local CONVAR_MT = { __index = {
    GetString = function(self) return self.value end,
    GetInt    = function(self) return math.floor(tonumber(self.value) or 0) end,
    GetFloat  = function(self) return tonumber(self.value) or 0 end,
    GetBool   = function(self) return tobool(self.value) end,
    SetString = function(self, v) self.value = tostring(v) end,
} }
function CreateConVar(name, default)
    convars[name] = setmetatable({ value = tostring(default), __name = name }, CONVAR_MT)
    return convars[name]
end
function CreateClientConVar(n, d) return CreateConVar(n, d) end
function GetConVar(name) return convars[name] end
cvars = {}
function cvars.AddChangeCallback() end
concommand = { __cmds = {} }
function concommand.Add(name, fn) concommand.__cmds[name] = fn end
function concommand.Run(name, ...) if concommand.__cmds[name] then concommand.__cmds[name](nil, nil, ...) end end

CURTIME = 0
function CurTime() return CURTIME end
player = {}
function player.GetAll() return {} end
function player.GetHumans() return {} end
function SafeRemoveEntity(e) if IsValid(e) then e:Remove() end end
function SafeRemoveEntityDelayed(e) if IsValid(e) then e:Remove() end end
function EffectData()
    local ed = {}
    function ed:SetOrigin() end
    function ed:SetMagnitude() end
    function ed:SetScale() end
    return ed
end
function Lerp(t, a, b) return a + (b - a) * t end
FCVAR_ARCHIVE = 1
FCVAR_NOTIFY = 2
FCVAR_REPLICATED = 4
COLLISION_GROUP_NONE = 0
COLLISION_GROUP_DEBRIS = 1
COLLISION_GROUP_IN_VEHICLE = 15
MOVETYPE_NONE = 0
MOVETYPE_VPHYSICS = 6
MASK_SOLID = 33579009
game = {}
function game.SinglePlayer() return true end
function game.GetWorld()
    if not worldEntity then
        worldEntity = makeEntity("worldspawn")
        worldEntity.__model = "models/error.mdl"
    end
    return worldEntity
end
function ENT_MT:GetDriver() return nil end
