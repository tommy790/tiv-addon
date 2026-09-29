// Executes the TIV anchor / loft / ground-pierce modules against a GMod stub
// and asserts their behaviour.
//
//   cd tools/harness && npm install && node run_anchor_tests.js
//
// The stub models entity/constraint bookkeeping and Source's angle basis. It
// does NOT model the physics solver, so these checks prove control flow,
// constraint geometry, force limits and state transitions -- never in-game feel.
'use strict';
const fengari = require('fengari');
const lauxlib = fengari.lauxlib, lualib = fengari.lualib, lua = fengari.lua;
const luastr = (Lx, i) => fengari.to_jsstring(lua.lua_tolstring(Lx, i));
const fs = require('fs'), path = require('path');

const ROOT = path.join(__dirname, '../../jeep_jalopy_interceptor/lua');
const L = s => fengari.to_luastring(s);
const U = s => (s === null || s === undefined) ? s : fengari.to_jsstring(s);

const stubSrc = fs.readFileSync(path.join(__dirname, 'gmod_stub.lua'), 'utf8');

const CONFIG_EXTRAS = `
TIV.Config = TIV.Config or {}
TIV.Config.Anchor = TIV.Config.Anchor or {}
TIV.Config.HideSpikes = false
TIV.Config.LoftWindThreshold = 120
TIV.Config.StressCritChance = 0.0
TIV.Config.StressHighSoundChance = 0.0
TIV.Config.StressLowSoundChance = 0.0
TIV.Config.Stress = { SoundLow = 30, SoundHigh = 60, SoundCrit = 85 }

TIV.AnchoredImmunity = 1.5
TIV.MaxLoftStress = 100.0
TIV.LoftDuration = 18
TIV.ArmorTearStress = 85
TIV.ArmorTearThreshold = 10
TIV.ArmorTearCooldown = 2.5
TIV.ArmorTearCount = 3
TIV.MaxArmorPanels = 8
TIV.LoftRecovery = "none"
TIV.ArmorPanelClasses = { "armor_plate", "armor_panel" }
TIV.ArmorPanelOffsets = { [1] = Vector(-30, -10, 60) }
TIV.ArmorPanelAngles = { [1] = Angle(0, 0, 0) }
`;

const LOFT_DEPS = `
TIV.Deploy = TIV.Deploy or {}
TIV.Deploy.Vehicles = TIV.Deploy.Vehicles or {}
TIV.Deploy.EnsureSpikes = TIV.Deploy.EnsureSpikes or function() end
TIV.Deploy.GetState = TIV.Deploy.GetState or function() return nil end
TIV.Deploy.BroadcastState = TIV.Deploy.BroadcastState or function() end
TIV.Deploy.EnsureAnchored = TIV.Deploy.EnsureAnchored or function() end
WIND_MPH = 0
TIV.Wind = TIV.Wind or {}
TIV.Wind.GetSpeed = function() return WIND_MPH or 0 end
TIV.Wind.GetForceVector = function() return Vector(0, WIND_MPH or 0, 0) end
TIV.Wind.GetDirection = function() return Angle(0, 0, 0) end
if not TIV.Spikes then
    TIV.Spikes = {
        GetState = function() return "anchored" end,
        GetSpike = function() return nil end,
        GetCount = function(d) local n = 0 for _ in ipairs((d and d.spikes) or {}) do n = n + 1 end return n end,
        BroadcastState = function() end,
        ReleaseAll = function(d) if d then d.spikes = {} end end,
    }
end
if not TIV.Spikes.GetAll then
    TIV.Spikes.GetAll = function(veh, data) return (data and data.spikes) or {} end
end
if not TIV.Spikes.GetGroup then
    TIV.Spikes.GetGroup = function(i) return "rear" end
end
`;

const HELPERS = `
function countType(data, kind)
    local n = 0
    for _, c in ipairs(data.constraints) do
        if c.type == kind and IsValid(c.constraint) then n = n + 1 end
    end
    return n
end

function makeVehicle(x, y, z)
    local veh = ents.Create("prop_vehicle_jeep")
    veh:SetModel("models/jalopy/jalopy_interceptor.mdl")
    veh:SetPos(Vector(x or 100, y or 100, z or 50))
    veh:SetAngles(Angle(0, 90, 0))
    veh.__minmaxs = { Vector(-60, -110, 15), Vector(60, 110, 95) }
    function veh:OBBMins() return self.__minmaxs[1] end
    function veh:OBBMaxs() return self.__minmaxs[2] end
    veh.JalopyArmorEntities = {}
    return veh
end

-- A plain prop standing above the ground at z=0, pointing straight down.
function makeProp(x, y, z)
    local p = ents.Create("prop_physics")
    p:SetModel("models/props_c17/oildrum001.mdl")
    p:SetPos(Vector(x or 300, y or 300, z or 60))
    p:SetAngles(Angle(90, 0, 0))
    p:GetPhysicsObject():SetMass(40)
    return p
end

function makeSpikes(veh, data)
    local groups = { "rear", "rear", "mid", "mid", "front", "front" }
    local offsets = {
        { -45, 80, 8 }, { 45, 80, 8 }, { -50, 0, 8 },
        { 50, 0, 8 }, { -45, -80, 8 }, { 45, -80, 8 },
    }
    local list = {}
    for i = 1, 6 do
        local e = ents.Create("prop_physics")
        e:SetModel("models/props_junk/harpoon002a.mdl")
        e:SetParent(veh)
        e:SetPos(veh:LocalToWorld(Vector(offsets[i][1], offsets[i][2], offsets[i][3])))
        e:SetAngles(Angle(90, 0, 0))
        e:GetPhysicsObject():SetMass(50)
        local sd = { index = i, entity = e, group = groups[i],
                     localOffset = Vector(offsets[i][1], offsets[i][2], offsets[i][3]) }
        data.spikes[i] = sd
        data.spikeAnims[i] = "idle"
        SPIKE_REGISTRY[i] = e
        list[i] = sd
    end
    return list
end

-- The stub has no physics solver, so anything the chassis would drag along has
-- to be moved by hand by the scenario.
function anchorThink(veh, data, pos, stress)
    CURTIME = CURTIME + 0.05
    veh:SetPos(pos)
    if tobool(stress) then TIV.Anchor.StressAll(veh, data) else TIV.Anchor.UnstressAll(veh, data) end
    TIV.Anchor.UpdateAnchors(veh, data)
end

function springsOf(ent)
    local out = {}
    for _, c in ipairs(constraint.GetTable(ent)) do
        if c.__live and c.Type == "Elastic" then out[#out + 1] = c end
    end
    return out
end
`;

function bootLua(withWiremod) {
  const Lx = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(Lx);
  const load = (label, src) => {
    if (lauxlib.luaL_dostring(Lx, L(src)) !== lua.LUA_OK) throw new Error(label + ': ' + luastr(Lx, -1));
  };
  load('stub', stubSrc);
  if (withWiremod) {
    load('wiremod stub', `
      scripted_ents.__stored["gmod_wire_grabber"] = { Name = "gmod_wire_grabber" }
      WireLib = { TriggerOutput = function() end }
    `);
  }
  load('sh_anchor_config', fs.readFileSync(path.join(ROOT, 'tiv/config/sh_anchor_config.lua'), 'utf8'));
  load('sh_ground_config', fs.readFileSync(path.join(ROOT, 'tiv/ground/sh_ground_config.lua'), 'utf8'));
  load('sv_ground_pierce', fs.readFileSync(path.join(ROOT, 'tiv/ground/sv_ground_pierce.lua'), 'utf8'));
  load('config extras', CONFIG_EXTRAS);
  load('sv_wire_anchor', fs.readFileSync(path.join(ROOT, 'tiv/anchor/sv_wire_anchor.lua'), 'utf8'));
  load('sv_anchor', fs.readFileSync(path.join(ROOT, 'tiv/anchor/sv_anchor.lua'), 'utf8'));
  load('sv_loft', fs.readFileSync(path.join(ROOT, 'tiv/loft/sv_loft.lua'), 'utf8'));
  load('loft deps', LOFT_DEPS);
  load('helpers', HELPERS);
  return Lx;
}

let pass = 0, fail = 0;
function check(Lx, cond, msg) {
  if (cond) { pass++; console.log(`  ✓ ${msg}`); }
  else { fail++; console.log(`  ✖ FAIL: ${msg}`); }
}
function section(Lx, s) { console.log(`\n--- ${s}`); }
function wire(Lx) {
  lua.lua_pushcfunction(Lx, function () { check(Lx, lua.lua_toboolean(Lx, 1), luastr(Lx, 2)); return 0; });
  lua.lua_setglobal(Lx, L('check'));
  lua.lua_pushcfunction(Lx, function () { section(Lx, luastr(Lx, 1)); return 0; });
  lua.lua_setglobal(Lx, L('section'));
}
function run(Lx, label, src) {
  if (lauxlib.luaL_dostring(Lx, L(src)) !== lua.LUA_OK) {
    fail++;
    console.log(`  ✖ ${label}: ${luastr(Lx, -1)}`);
  }
}

// ------------------------------------------------------------------ no Wiremod
const L1 = bootLua(false); wire(L1);
run(L1, 'S1 deploy', `
  section("S1: deploy without Wiremod -> ballsockets, no grabbers, world embeds")
  check(TIV.WireAnchor.IsAvailable() == false, "Wiremod must NOT be detected")
  local veh = makeVehicle()
  local data = { state = "deploying_spikes", constraints = {}, spikes = {}, spikeAnims = {} }
  local spikes = makeSpikes(veh, data)
  for i, sd in ipairs(spikes) do TIV.Anchor.PlantSingle(veh, data, sd) end
  TIV.Anchor.AttachAll(veh, data)
  check(countType(data, "groundweld") == 0, "no rigid world welds")
  check(countType(data, "ballsocket") == 6, "6 ballsocket holds, got " .. countType(data, "ballsocket"))
  local perSpike = countType(data, "embed") / 6
  check(perSpike == TIV.GroundSettingCvar("Grips", 3),
      "each spike carries one soil grip per configured grip (" .. countType(data, "embed") .. " total)")
  check(countType(data, "grabber") == 0, "no grabbers without Wiremod")
  local h
  for _, c in ipairs(data.constraints) do
    if c.type == "ballsocket" and IsValid(c.constraint) then h = c.constraint end
  end
  check(h ~= nil and h.forcelimit == 0, "holds are unbreakable while grounded")
  GLOBAL_DATA, GLOBAL_VEH, GLOBAL_SPIKES = data, veh, spikes
`);

run(L1, 'S2 stress', `
  section("S2: lofting start -> all holds re-cut at 50000, still live")
  local data, veh = GLOBAL_DATA, GLOBAL_VEH
  check(TIV.Anchor.StressAll(veh, data) == 6, "StressAll re-cuts 6 holds")
  check(TIV.Anchor.StressAll(veh, data) == 0, "second StressAll is a no-op")
  local wrong = 0
  for _, c in ipairs(data.constraints) do
    if c.type == "ballsocket" and IsValid(c.constraint) and c.constraint.forcelimit ~= 50000 then wrong = wrong + 1 end
  end
  check(wrong == 0, "all holds at 50000 (" .. wrong .. " wrong)")
  check(countType(data, "ballsocket") == 6, "no hold was dropped by stressing")
  TIV.Anchor.UnstressAll(veh, data)
  check(TIV.Anchor.IsStressed(data) == false, "unstressed again")
  check(countType(data, "ballsocket") == 6, "no hold dropped by unstressing")
`);

run(L1, 'S3 directional', `
  section("S3: rear lifted -> rear spikes tear out, front holds")
  local data, veh = GLOBAL_DATA, GLOBAL_VEH
  TIV.Anchor.StressAll(veh, data)
  local before = TIV.Anchor.LiveGroundAnchorCount(data)
  CURTIME = CURTIME + 5
  local base = {}
  for _, sd in ipairs(data.spikes) do base[sd.index] = sd.entity:GetPos() end
  for i = 1, 40 do
    for _, sd in ipairs(data.spikes) do
      local rear = (sd.group == "rear") and 1.0 or 0.0
      sd.entity:SetPos(base[sd.index] + Vector(0, 0, i * 8 * rear))
    end
    anchorThink(veh, data, Vector(100, 100, 50 + i * 8), true)
  end
  check(TIV.Anchor.LiveGroundAnchorCount(data) < before,
      "rear spikes lose ground anchoring (" .. before .. " -> " .. TIV.Anchor.LiveGroundAnchorCount(data) .. ")")
  local slipped, frontTorn = 0, 0
  for _, sd in ipairs(data.spikes) do
    if sd.slipped then
      slipped = slipped + 1
      if sd.group ~= "rear" then frontTorn = frontTorn + 1 end
    end
  end
  check(slipped == 2, "exactly the two rear spikes tore out (" .. slipped .. ")")
  check(frontTorn == 0, "mid/front spikes kept their ground (" .. frontTorn .. " lost)")
  check(countType(data, "ballsocket") == 6, "all 6 chassis holds survive tear-out")
`);

run(L1, 'S4 integrity', `
  section("S4: CheckIntegrity / LiveGroundAnchorCount / ReportLines")
  local data, veh = GLOBAL_DATA, GLOBAL_VEH
  local ok = TIV.Anchor.CheckIntegrity(veh, data)
  local ground = TIV.Anchor.LiveGroundAnchorCount(data)
  check(ok == (ground > 0), "CheckIntegrity agrees with LiveGroundAnchorCount (" .. tostring(ok) .. " vs " .. ground .. ")")
  local lines = TIV.Anchor.ReportLines(veh, data)
  check(type(lines) == "table" and #lines > 0, "ReportLines produces output (" .. #lines .. " lines)")
  local counts = TIV.Anchor.GetCounts(data)
  check(counts.total >= counts.holds, "total >= holds")
`);

// -------------------------------------------------------------------- Wiremod
const L2 = bootLua(true); wire(L2);
run(L2, 'S5 wiremod', `
  section("S5: Wiremod present -> grabbers used, ballsockets as fallback")
  check(TIV.WireAnchor.IsAvailable() == true, "Wiremod detected")
  local veh = makeVehicle()
  local data = { state = "deploying_spikes", constraints = {}, spikes = {}, spikeAnims = {} }
  local spikes = makeSpikes(veh, data)
  for i, sd in ipairs(spikes) do TIV.Anchor.PlantSingle(veh, data, sd) end
  TIV.Anchor.AttachAll(veh, data)
  check(countType(data, "grabber") == 6, "6 grabber holds, got " .. countType(data, "grabber"))
  check(countType(data, "ballsocket") == 0, "no ballsockets when grabbers work")
  local bad = 0
  for _, c in ipairs(data.constraints) do
    if c.type == "grabber" then
      if not IsValid(c.constraint) or not IsValid(c.grabber) or not IsValid(c.grabber.WeldEntity) then bad = bad + 1 end
    end
  end
  check(bad == 0, "every grabber actually welded to its spike (" .. bad .. " unwelded)")
  TIV.Anchor.StressAll(veh, data)
  local wrong = 0
  for _, c in ipairs(data.constraints) do
    if c.type == "grabber" and IsValid(c.grabber) and c.grabber.WeldStrength ~= 50000 then wrong = wrong + 1 end
  end
  check(wrong == 0, "grabber weld strength raised to 50000 (" .. wrong .. " wrong)")
  TIV.Anchor.DetachAll(veh, data)
  check(countType(data, "grabber") == 0, "DetachAll removed grabber bodies")
  scripted_ents.__stored["gmod_wire_grabber"] = nil
  TIV.WireAnchor.InvalidateCache()
  check(TIV.WireAnchor.IsAvailable() == false, "Wiremod removal falls back cleanly")
  local v2 = makeVehicle()
  local d2 = { state = "deploying_spikes", constraints = {}, spikes = {}, spikeAnims = {} }
  local s2 = makeSpikes(v2, d2)
  for i, sd in ipairs(s2) do TIV.Anchor.PlantSingle(v2, d2, sd) end
  TIV.Anchor.AttachAll(v2, d2)
  check(countType(d2, "ballsocket") == 6, "falls back to ballsockets")
`);

// ----------------------------------------------------------------------- loft
const L3 = bootLua(false); wire(L3);
run(L3, 'S6 loft', `
  section("S6: lofting happens through the anchors, never by scripting")
  local veh = makeVehicle()
  local data = { state = "anchored", constraints = {}, spikes = {}, spikeAnims = {} }
  local spikes = makeSpikes(veh, data)
  for i, sd in ipairs(spikes) do TIV.Anchor.PlantSingle(veh, data, sd) end
  TIV.Anchor.AttachAll(veh, data)
  TIV.Anchor.StressAll(veh, data)
  TIV.Deploy.Vehicles[veh:EntIndex()] = data
  local think = timer.__timers["TIV_LoftThink"]
  check(think ~= nil, "loft think timer registered")

  local p0 = veh:GetPos()
  WIND_MPH = 260
  for i = 1, 20 do CURTIME = CURTIME + 0.05; think.fn() end
  check(veh:GetPos() == p0, "vehicle position never scripted")
  check(veh:GetPhysicsObject():IsMotionEnabled() == true, "motion stays on while ground anchors remain")
  check(TIV.Anchor.LiveGroundAnchorCount(data) > 0, "still anchored at 260 mph while embeds hold")

  for _, sd in ipairs(data.spikes) do TIV.Anchor.ReleaseEmbeds(veh, data, sd.index) end
  check(TIV.Anchor.LiveGroundAnchorCount(data) == 0, "ground anchors cleared")
  think.fn()
  check(data.state == "lofted", "lofts once no ground anchor remains (state=" .. tostring(data.state) .. ")")
  check(veh:GetPhysicsObject():IsMotionEnabled() == true, "lofted vehicle still a live physics body")
  check(veh:GetPhysicsObject():IsGravityEnabled() == true, "lofted vehicle still has gravity")
`);

// ------------------------------------------------------- anchor hold geometry
const L4 = bootLua(false); wire(L4);
run(L4, 'S8 hold flags', `
  section("S8: holds pin position, spikes stay put until held, airbags survive")
  local veh = makeVehicle()
  local data = { state = "deploying_spikes", constraints = {}, spikes = {}, spikeAnims = {} }
  local spikes = makeSpikes(veh, data)

  for _, sd in ipairs(spikes) do TIV.Anchor.PlantSingle(veh, data, sd) end
  local frozenAtPlant = 0
  for _, sd in ipairs(spikes) do
    if sd.entity:GetPhysicsObject():IsMotionEnabled() == false then frozenAtPlant = frozenAtPlant + 1 end
  end
  check(frozenAtPlant == 6, "all 6 spikes frozen until their hold is cut (" .. frozenAtPlant .. "/6)")

  TIV.Anchor.AttachAll(veh, data)
  local liveAfterHold = 0
  for _, sd in ipairs(spikes) do
    if sd.entity:GetPhysicsObject():IsMotionEnabled() == true then liveAfterHold = liveAfterHold + 1 end
  end
  check(liveAfterHold == 6, "all 6 spikes live once held (" .. liveAfterHold .. "/6)")

  local freeMovement, noFriction, wideLimit, checked = 0, 0, 0, 0
  for _, c in ipairs(data.constraints) do
    if c.type == "ballsocket" and IsValid(c.constraint) then
      checked = checked + 1
      if c.constraint.onlyrotation ~= 0 then freeMovement = freeMovement + 1 end
      if (c.constraint.xfric or 0) <= 0 then noFriction = noFriction + 1 end
      if math.abs(c.constraint.xmax or 0) > 15 then wideLimit = wideLimit + 1 end
    end
  end
  check(checked == 6, "6 holds inspected, got " .. checked)
  check(freeMovement == 0, "no hold uses onlyRotation/free movement (" .. freeMovement .. " do)")
  check(noFriction == 0, "every gimbal has rotational friction (" .. noFriction .. " have none)")
  check(wideLimit == 0, "pivot limit stays tight (" .. wideLimit .. " too wide)")

  TIV.Anchor.StressAll(veh, data)
  local freeAfter = 0
  for _, c in ipairs(data.constraints) do
    if c.type == "ballsocket" and IsValid(c.constraint) and c.constraint.onlyrotation ~= 0 then freeAfter = freeAfter + 1 end
  end
  check(freeAfter == 0, "re-cut holds also pin position (" .. freeAfter .. " free)")

  TIV.Anchor.StartPullDown(veh, data, 10)
  local before = countType(data, "elastic")
  check(before > 0, "precondition: airbag springs exist")
  if not tobool(TIV.AnchorSetting("KeepAirbagsWhileAnchored", true)) then
    TIV.Anchor.ReleaseCoveredSprings(veh, data)
  end
  check(countType(data, "elastic") == before, "airbags NOT removed while anchored (" .. before .. " -> " .. countType(data, "elastic") .. ")")

  scripted_ents.__stored["gmod_wire_grabber"] = { Name = "gmod_wire_grabber" }
  WireLib = { TriggerOutput = function() end }
  TIV.WireAnchor.InvalidateCache()
  local v2 = makeVehicle()
  local d2 = { state = "deploying_spikes", constraints = {}, spikes = {}, spikeAnims = {} }
  local s2 = makeSpikes(v2, d2)
  for _, sd in ipairs(s2) do TIV.Anchor.PlantSingle(v2, d2, sd) end
  TIV.Anchor.AttachAll(v2, d2)
  local live2 = 0
  for _, sd in ipairs(s2) do if sd.entity:GetPhysicsObject():IsMotionEnabled() then live2 = live2 + 1 end end
  check(live2 == 6, "grabber path also releases the spikes once held (" .. live2 .. "/6)")
  check(countType(d2, "grabber") == 6, "grabber path produces 6 grabber holds")

  check(TIV.AnchorSetting("EmbedDamping", 0) >= 1200, "soil damping near critical (got " .. tostring(TIV.AnchorSetting("EmbedDamping", 0)) .. ")")
  check(TIV.AnchorSetting("SpikePivotLimit", 99) <= 12, "pivot limit tightened (got " .. tostring(TIV.AnchorSetting("SpikePivotLimit", 99)) .. ")")
  check(TIV.AnchorSetting("SpikeMass", 0) >= 30, "spike mass raised (got " .. tostring(TIV.AnchorSetting("SpikeMass", 0)) .. ")")
`);

// ------------------------------------------------- spike soil grip (lever arm)
const L5 = bootLua(false); wire(L5);
run(L5, 'S9 spike soil grip', `
  section("S9: spike soil anchors grip the shaft, so they can resist rotation")
  local veh = makeVehicle()
  local data = { state = "deploying_spikes", constraints = {}, spikes = {}, spikeAnims = {} }
  local spikes = makeSpikes(veh, data)
  for _, sd in ipairs(spikes) do TIV.Anchor.PlantSingle(veh, data, sd) end

  local atPivot, spread, checkedSpikes, buried = 0, 0, 0, 0
  for _, sd in ipairs(data.spikes) do
    local mine = {}
    for _, c in ipairs(data.constraints) do
      if c.type == "embed" and IsValid(c.constraint) and c.constraint.Ent1 == sd.entity then
        mine[#mine + 1] = c.constraint
      end
    end
    checkedSpikes = checkedSpikes + 1
    -- A spring attached at the spike's own origin has zero lever arm about the
    -- pivot the chassis hold pins, so it can never resist rotation.
    for _, el in ipairs(mine) do
      if el.LPos1:Length() < 0.01 then atPivot = atPivot + 1 end
    end
    local depths, allDeep = {}, true
    for _, el in ipairs(mine) do depths[#depths + 1] = el.LPos1.x end
    table.sort(depths)
    if #depths >= 2 and (depths[#depths] - depths[1]) >= 6 then spread = spread + 1 end
    for _, el in ipairs(mine) do
      if (el.LPos2 - sd.entity:GetPos()):Dot(sd.entity:GetAngles():Forward()) <= 0 then allDeep = false end
    end
    if allDeep and #mine > 0 then buried = buried + 1 end
  end
  check(checkedSpikes == 6, "6 spikes inspected, got " .. checkedSpikes)
  check(atPivot == 0, "no soil anchor sits at the pivot (" .. atPivot .. " do) -- that is why they rotated")
  check(spread == 6, "grips are spread along the shaft on all 6 spikes (" .. spread .. "/6)")
  check(buried == 6, "every grip is buried down the shaft (" .. buried .. "/6)")
`);

// ------------------------------------------------------- ground pierce system
const L6 = bootLua(false); wire(L6);
run(L6, 'S10 pierce a standalone prop', `
  section("S10: TIV.Ground.Pierce embeds a plain prop and grips the buried shaft")
  local prop = makeProp(300, 300, 60)
  local handle = TIV.Ground.Pierce(prop, { depth = 18, tag = "test-drum" })
  check(handle ~= nil, "Pierce returned a handle")
  check(TIV.Ground.Count() == 1, "one active pierce registered")

  local live, total = TIV.Ground.Grips(handle)
  check(live == 3 and total == 3, "3 grips cut (got " .. live .. "/" .. total .. ")")

  local springs = springsOf(prop)
  check(#springs == 3, "3 live springs on the prop, got " .. #springs)

  -- The one and only reposition: origin driven to surface + depth.
  check(math.abs(prop:GetPos().z + 18) < 0.01,
      "prop driven 18 u past the surface along the down axis (z=" .. prop:GetPos().z .. ")")

  -- Never welded to the world, never frozen.
  local welds = 0
  for _, c in ipairs(constraint.GetTable(prop)) do if c.__live and c.Type == "weld" then welds = welds + 1 end end
  check(welds == 0, "no rigid world weld (" .. welds .. ")")
  check(prop:GetPhysicsObject():IsMotionEnabled() == true, "prop is a live body, not frozen")
  check(prop:GetPhysicsObject():IsGravityEnabled() == true, "prop keeps gravity")

  -- Grips spread along the shaft, none at the pivot.
  local atPivot, depths = 0, {}
  for _, s in ipairs(springs) do
    if s.LPos1:Length() < 0.01 then atPivot = atPivot + 1 end
    depths[#depths + 1] = s.LPos1.x
  end
  table.sort(depths)
  check(atPivot == 0, "no grip attached at the prop's origin (" .. atPivot .. " are)")
  check(depths[1] > 0, "shallowest grip is below the origin (" .. depths[1] .. " u)")
  check((depths[#depths] - depths[1]) >= 2 * TIV.GroundSettingCvar("GripSpacing", 7) - 0.5,
      "grips span the configured spacing (" .. depths[1] .. " .. " .. depths[#depths] .. ")")

  -- Anchors alternate sides so each spring has a real rest length.
  local restLens = {}
  for _, s in ipairs(springs) do
    restLens[#restLens + 1] = (prop:LocalToWorld(s.LPos1) - s.LPos2):Length()
  end
  local allRest = true
  for _, r in ipairs(restLens) do
    if math.abs(r - TIV.GroundSettingCvar("LateralOffset", 7)) > 0.01 then allRest = false end
  end
  check(allRest, "every spring is at its rest length at pierce time")

  check(TIV.Ground.IsHolding(prop) == true, "IsHolding reports the prop held")
  check(TIV.Ground.ForEntity(prop) == handle, "ForEntity finds the handle from the prop")
`);

run(L6, 'S11 progressive failure', `
  section("S11: a pulled prop loses its grips from the top down, then tears out")
  local prop = makeProp(400, 400, 60)
  local torn = 0
  local lostOrder = {}
  local handle = TIV.Ground.Pierce(prop, {
    depth = 18, tag = "pull-test",
    onTearOut  = function() torn = torn + 1 end,
    onGripLost = function(_, _, idx) lostOrder[#lostOrder + 1] = idx end,
  })
  TIV.Ground.SetStressed(handle, true)
  CURTIME = CURTIME + 5   -- past SettleTime

  local origin = prop:GetPos()
  local seen, monotonic = {}, true
  local prev = 3
  for pull = 0, 14 do
    prop:SetPos(origin + Vector(0, 0, pull))   -- axis points down, so +z is pull-out
    TIV.Ground.Update(handle)
    local live = TIV.Ground.Grips(handle)
    seen[live] = true
    if live > prev then monotonic = false end
    prev = live
  end

  check(monotonic, "grips are only ever lost, never regained")
  local distinct = 0
  for _ in pairs(seen) do distinct = distinct + 1 end
  check(distinct >= 3, "failure is progressive, not a single snap (" .. distinct .. " distinct grip counts)")
  check(TIV.Ground.Grips(handle) == 0, "all grips gone at full pull")
  check(torn == 1, "onTearOut fired exactly once (got " .. torn .. ")")
  check(#lostOrder == 3, "onGripLost fired per grip (got " .. #lostOrder .. ")")
  check(lostOrder[1] == 1 and lostOrder[2] == 2 and lostOrder[3] == 3,
      "grips failed shallowest first (" .. table.concat(lostOrder, ",") .. ")")
  check(handle.torn == true, "handle is marked torn")
  check(TIV.Ground.Load(handle) > 0.9, "load reads saturated (" .. string.format("%.2f", TIV.Ground.Load(handle)) .. ")")
`);

run(L6, 'S12 spikes use the shared geometry', `
  section("S12: the interceptor's spikes take their grip geometry from TIV.Ground")
  check(tobool(TIV.GroundSetting("UseForSpikes", 1)) == true, "UseForSpikes is on by default")

  local veh = makeVehicle()
  local data = { state = "deploying_spikes", constraints = {}, spikes = {}, spikeAnims = {} }
  local spikes = makeSpikes(veh, data)
  for _, sd in ipairs(spikes) do TIV.Anchor.PlantSingle(veh, data, sd) end

  -- What the shared geometry says the first spike should have.
  local expected = TIV.Ground.GripPoints(spikes[1].entity, {
    axis      = spikes[1].entity:GetAngles():Forward(),
    lateral   = TIV.Config.Anchor.LateralEmbedOffset,
    firstGrip = TIV.Config.Anchor.SoilAnchorDepth,
    spacing   = TIV.Config.Anchor.SoilGripLength * 0.5,
  })
  check(#expected == 3, "shared geometry yields 3 grips (got " .. #expected .. ")")

  local actual = {}
  for _, c in ipairs(data.constraints) do
    if c.type == "embed" and IsValid(c.constraint) and c.constraint.Ent1 == spikes[1].entity then
      actual[#actual + 1] = c.constraint
    end
  end
  check(#actual == #expected, "the spike got exactly the shared grip count (" .. #actual .. " vs " .. #expected .. ")")

  local mismatch = 0
  for i = 1, #expected do
    if (actual[i].LPos1 - expected[i].localPos):Length() > 0.001 then mismatch = mismatch + 1 end
    if (actual[i].LPos2 - expected[i].point):Length() > 0.001 then mismatch = mismatch + 1 end
  end
  check(mismatch == 0, "every grip matches TIV.Ground.GripPoints exactly (" .. mismatch .. " differ)")

  -- And turning it off must fall back, not break.
  TIV.Config.Ground.UseForSpikes = 0
  local v2 = makeVehicle()
  local d2 = { state = "deploying_spikes", constraints = {}, spikes = {}, spikeAnims = {} }
  local s2 = makeSpikes(v2, d2)
  for _, sd in ipairs(s2) do TIV.Anchor.PlantSingle(v2, d2, sd) end
  check(countType(d2, "embed") == 12, "UseForSpikes=0 falls back to the 2-point geometry (got " .. countType(d2, "embed") .. ")")
  TIV.Config.Ground.UseForSpikes = 1
`);

run(L6, 'S13 robustness', `
  section("S13: refusal, idempotency, release and the constraint budget")

  -- No physics object -> refuse rather than raise on a NULL physobj.
  local bare = ents.Create("prop_physics")
  bare:SetPos(Vector(500, 500, 60))
  check(TIV.Ground.Pierce(bare, {}) == nil, "refuses an entity with no physics object")

  -- Re-piercing must not stack grips.
  local prop = makeProp(600, 600, 60)
  local h1 = TIV.Ground.Pierce(prop, { depth = 12 })
  local h2 = TIV.Ground.Pierce(prop, { depth = 12 })
  check(h1 ~= nil and h2 ~= nil, "both pierce calls succeeded")
  check(h1 ~= h2, "the second call produced a fresh handle")
  check(#springsOf(prop) == 3, "re-piercing did not stack grips (" .. #springsOf(prop) .. " springs)")

  -- Release actually removes them.
  local removed = TIV.Ground.Release(prop)
  check(removed == 3, "Release removed 3 grips (got " .. removed .. ")")
  check(#springsOf(prop) == 0, "no springs left on the prop")
  check(TIV.Ground.IsHolding(prop) == false, "IsHolding is false after release")
  check(TIV.Ground.Release(prop) == 0, "releasing twice is a no-op")

  -- Constraint budget.
  local busy = makeProp(700, 700, 60)
  local dummy = makeProp(701, 700, 60)
  for i = 1, 70 do constraint.Weld(busy, dummy, 0, 0, 0, 0) end
  check(TIV.Ground.Pierce(busy, { depth = 12 }) == nil, "refuses when the constraint budget is exhausted")

  -- Reporting must not error and must describe what is live.
  local lines = TIV.Ground.ReportLines()
  check(type(lines) == "table" and #lines >= 1, "ReportLines returns output (" .. #lines .. " lines)")

  -- The module is switchable.
  TIV.Config.Ground.Enabled = 0
  check(TIV.Ground.Pierce(makeProp(800, 800, 60), {}) == nil, "Enabled=0 makes Pierce refuse")
  TIV.Config.Ground.Enabled = 1
`);

console.log(`\n>>> ${pass} checks, ${fail} failures`);
process.exit(fail ? 1 : 0);
