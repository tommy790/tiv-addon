-- ============================================================================
-- TIV INSTRUMENTS SERVER
-- Reindented for clarity. Wind is per-vehicle (TIV.Wind.GetSpeed(veh)).
-- Streams live flight telemetry and tactical Doppler radar path data.
-- ============================================================================

TIV.Instruments = TIV.Instruments or {}

util.AddNetworkString("TIV_InstrumentData")
util.AddNetworkString("TIV_RadarPathData")

local UNITS_TO_MPH = 0.0568182  -- 1 source unit/sec ~= 0.0568182 MPH

timer.Create("TIV_InstrumentUpdate", TIV.Config.InstrumentUpdateRate, 0, function()
    -- Cache packets per vehicle so 2 occupants don't recompute.
    local packets = {}

    for _, ply in ipairs(player.GetAll()) do
        local veh = (TIV.ResolveVehicle and TIV.ResolveVehicle(ply)) or ply:GetVehicle()
        if IsValid(veh) and TIV.Deploy.IsJeep(veh) then
            local packet = packets[veh]
            if not packet then
                local data     = TIV.Deploy.GetState(veh)
                local phys     = veh:GetPhysicsObject()
                local speed    = 0
                local altitude = veh:GetPos().z
                local velZ     = 0

                if IsValid(phys) then
                    local vel = phys:GetVelocity()
                    speed = vel:Length() * UNITS_TO_MPH
                    velZ  = vel.z * UNITS_TO_MPH  -- now consistent MPH
                end

                local activeConstraints = 0
                for _, c in ipairs(data.constraints or {}) do
                    if IsValid(c.constraint) and c.type == "ballsocket" then
                        activeConstraints = activeConstraints + 1
                    end
                end

                local windSpeed = TIV.Wind.GetSpeed(veh)
                local windDir   = TIV.Wind.GetDirection(veh)
                -- Only meaningful while anchored; saves player confusion.
                local stress    = (data.state == "anchored")
                    and TIV.Loft.CalculateStress(windSpeed) or 0

                packet = {
                    windSpeed         = windSpeed,
                    windDir           = windDir,
                    vehicleSpeed      = speed,
                    altitude          = altitude,
                    state             = data.state,
                    activeConstraints = activeConstraints,
                    totalSpikes       = TIV.Spikes.GetCount(data),
                    stress            = stress,
                    spikeState        = TIV.Spikes.GetState(data),
                    verticalVelocity  = velZ,
                }
                packets[veh] = packet
            end

            net.Start("TIV_InstrumentData")
                net.WriteFloat(packet.windSpeed)
                net.WriteVector(packet.windDir)
                net.WriteFloat(packet.vehicleSpeed)
                net.WriteFloat(packet.altitude)
                net.WriteString(packet.state)
                net.WriteUInt(packet.activeConstraints, 8)
                net.WriteUInt(packet.totalSpikes, 8)
                net.WriteFloat(packet.stress)
                net.WriteString(packet.spikeState)
                net.WriteFloat(packet.verticalVelocity)
            net.Send(ply)
        end
    end
end)

-- ============================================================================
-- TACTICAL DOPPLER RADAR & PATH PREDICTION STREAM
-- Streams real-time tornado tracking, core/side bounds, and predicted path
-- waypoints to in-cabin dashboard screens and client HUDs.
-- ============================================================================
timer.Create("TIV_RadarPathUpdate", 0.35, 0, function()
    local cachedRadar = {}

    for _, ply in ipairs(player.GetAll()) do
        local veh = (TIV.ResolveVehicle and TIV.ResolveVehicle(ply)) or ply:GetVehicle()
        if IsValid(veh) and TIV.Deploy.IsJeep(veh) then
            local tInfo = cachedRadar[veh]
            if tInfo == nil then
                tInfo = TIV.Wind and TIV.Wind.GetNearestActiveTornado and TIV.Wind.GetNearestActiveTornado(veh:GetPos()) or false
                cachedRadar[veh] = tInfo
            end

            net.Start("TIV_RadarPathData")
                net.WriteEntity(veh)
                if tInfo and istable(tInfo) then
                    net.WriteBool(true)
                    net.WriteVector(tInfo.pos)
                    net.WriteVector(tInfo.heading)
                    net.WriteFloat(tInfo.speedMPH or 0)
                    net.WriteFloat(tInfo.coreRadius or 600)
                    net.WriteFloat(tInfo.outerRadius or 3500)
                    net.WriteFloat(tInfo.dist or 0)
                    net.WriteFloat(tInfo.bearing or 0)
                    net.WriteFloat(tInfo.eta or 0)
                    net.WriteString(tInfo.impactType or "receding")

                    local waypoints = tInfo.waypoints or {}
                    local wpCount = math.min(#waypoints, 16)
                    net.WriteUInt(wpCount, 5)
                    for i = 1, wpCount do
                        net.WriteVector(waypoints[i].pos or Vector(0, 0, 0))
                        net.WriteUInt(math.Clamp(math.Round(waypoints[i].time or (i * 4)), 0, 255), 8)
                    end

                    -- Circulation telemetry for the Doppler signature. Appended
                    -- after the waypoints so the existing payload order is
                    -- unchanged, and still sent on the same 0.35 s timer -- the
                    -- signature is interpolated client-side, never per frame.
                    --
                    -- Rotation direction is a signed byte because there is no
                    -- neutral spelling of "clockwise": -1/0/+1 carries
                    -- anticyclonic / unknown / cyclonic without inventing a
                    -- direction for the unknown case.
                    net.WriteBool(tInfo.touchingGround == true)
                    net.WriteInt(math.Clamp(math.Round(tInfo.rotationDirection or 0), -1, 1), 8)
                    net.WriteFloat(math.Clamp(tInfo.rotationSpeed or 0, 0, 400))
                else
                    net.WriteBool(false)
                end
            net.Send(ply)
        end
    end
end)

print("[TIV] Instruments server loaded")
