AddCSLuaFile( "shared.lua" )
AddCSLuaFile( "cl_init.lua" )
AddCSLuaFile( "cl_camera.lua" )
AddCSLuaFile( "sh_camera_eyetrace.lua" )
AddCSLuaFile( "cl_hud.lua" )
AddCSLuaFile( "cl_flyby.lua" )
include("shared.lua")
include("sv_ai.lua")
include("sv_mouseaim.lua")
include("sv_components.lua")
include("sv_engine.lua")
include("sv_vehiclespecific.lua")
include("sv_damage_extension.lua")
include("sh_camera_eyetrace.lua")

function ENT:OnCreateAI()
	self:StartEngine()
	self.COL_GROUP_OLD = self:GetCollisionGroup()
	self:SetCollisionGroup( COLLISION_GROUP_INTERACTIVE_DEBRIS )
end

function ENT:OnRemoveAI()
	self:StopEngine()
	self:SetCollisionGroup( self.COL_GROUP_OLD or COLLISION_GROUP_NONE )
end

function ENT:ApproachTargetAngle( TargetAngle, OverridePitch, OverrideYaw, OverrideRoll, FreeMovement, phys, deltatime )
	if not IsValid( phys ) then
		phys = self:GetPhysicsObject()
	end

	if not deltatime then
		deltatime = FrameTime()
	end

	-- Initialize previous values and PID integrators for smooth, stable control
	self.PrevPitch = self.PrevPitch or 0
	self.PrevYaw = self.PrevYaw or 0
	self.PrevRoll = self.PrevRoll or 0
	self.InterpFactor = self.InterpFactor or 0.2  -- Slightly lower for less overshoot

	-- PID integrators (clamped)
	self._iPitch = self._iPitch or 0
	self._iYaw   = self._iYaw   or 0
	self._iRoll  = self._iRoll  or 0

	local LocalAngles = self:WorldToLocalAngles( TargetAngle )

	local LocalAngPitch = LocalAngles.p
	local LocalAngYaw = LocalAngles.y
	local LocalAngRoll = LocalAngles.r

	-- forward vectors not needed for current PID approach

	local Ang = self:GetAngles()
	local AngVel = phys:GetAngleVelocity()

	-- Calculate adaptive interpolation factor based on angular velocity and angle differences
	local angVelMagnitude = AngVel:Length()

	-- Calculate angle differences for deadzone implementation
	local pitchDiff = math.abs(LocalAngPitch)
	local yawDiff = math.abs(LocalAngYaw)
	local rollDiff = math.abs(LocalAngRoll)
	local totalDiff = pitchDiff + yawDiff + rollDiff

	-- Create a deadzone to reduce bouncing when close to target
	local deadzoneThreshold = 2.0  -- degrees
	local nearTargetFactor = 1.0

	if totalDiff < deadzoneThreshold then
		-- Increase interpolation (slower response) when very close to target
		nearTargetFactor = math.max(0.2, totalDiff / deadzoneThreshold)
	end

	-- Adjust interpolation based on how close we are to target
	local adaptiveInterp = math.Clamp(1 - (angVelMagnitude / 360), 0.1, 0.8) * deltatime * 18
	-- Apply higher interpolation when near target to reduce bouncing
	adaptiveInterp = adaptiveInterp / nearTargetFactor

	-- Make angle approach stable; optionally add turbulence
	local stabilityFactor = self.StabilityFactor or 1
	local turbulenceEffect = (self.EnableTurbulence and self.TurbulenceIntensity or 0) / 4
	if turbulenceEffect > 0 then
		adaptiveInterp = adaptiveInterp * (1 - turbulenceEffect * 0.5)
	end

	-- Enhanced smoothing with reduced oscillation when near target
	local dampingFactor = math.max(0.5, math.min(totalDiff / 10, 1.0))  -- Stronger damping when near target

	-- Rate (D) terms derived from angular velocity, clamped for stability
	local SmoothPitch = math.Clamp(AngVel.y / 90, -0.5, 0.5) * stabilityFactor * dampingFactor
	local SmoothYaw   = math.Clamp(AngVel.z / 90, -0.5, 0.5) * stabilityFactor * dampingFactor

	local VelL = self:WorldToLocal(self:GetPos() + self:GetVelocity())

	-- More responsive pitch based on speed with interpolation (not used in PID path)

	-- Normalize errors to PID-friendly range
	local normPitchErr = math.Clamp(-LocalAngPitch / 20, -1, 1)
	local normYawErr   = math.Clamp(-LocalAngYaw   / 20, -1, 1)

	-- PID gains
	local gp = self.PIDPitch or { kp = 1, kd = 0.3, ki = 0, iLimit = 0.3 }
	local gy = self.PIDYaw   or { kp = 1, kd = 0.3, ki = 0, iLimit = 0.3 }

	-- Integrator update with clamp and decay
	local iDecay = math.max(0, 1 - deltatime * 4)
	self._iPitch = math.Clamp(self._iPitch * iDecay + normPitchErr * deltatime, -gp.iLimit, gp.iLimit)
	self._iYaw   = math.Clamp(self._iYaw   * iDecay + normYawErr   * deltatime, -gy.iLimit, gy.iLimit)

	local dPitch = -SmoothPitch  -- derivative opposes velocity
	local dYaw   = -SmoothYaw

	local targetPitch = math.Clamp(gp.kp * normPitchErr + gp.kd * dPitch + gp.ki * self._iPitch, -1, 1)
	local targetYaw   = math.Clamp(gy.kp * normYawErr   + gy.kd * dYaw   + gy.ki * self._iYaw,   -1, 1)

	-- Reduce input responsiveness when near target angle
	local pitchNearTarget = math.abs(LocalAngPitch) < 5.0
	local yawNearTarget = math.abs(LocalAngYaw) < 5.0

	-- Apply smooth interpolation between previous and current values
	-- Use stronger interpolation when near target to prevent oscillation
	local pitchInterp = pitchNearTarget and adaptiveInterp * 1.5 or adaptiveInterp
	local yawInterp = yawNearTarget and adaptiveInterp * 1.5 or adaptiveInterp

	local Pitch = Lerp(pitchInterp, self.PrevPitch, targetPitch)
	local Yaw = Lerp(yawInterp, self.PrevYaw, targetYaw)

	-- More dynamic roll with less oscillation when stable
	-- Roll uses PID on roll error plus coordination from yaw and lateral velocity
	local gr = self.PIDRoll or { kp = 1, kd = 0.3, ki = 0, iLimit = 0.3 }
	local normRollErr = math.Clamp(LocalAngRoll / 20, -1, 1)
	self._iRoll = math.Clamp(self._iRoll * iDecay + normRollErr * deltatime, -gr.iLimit, gr.iLimit)
	local dRoll = math.Clamp(AngVel.x / 90, -0.5, 0.5)
	local pidRoll = math.Clamp(gr.kp * normRollErr - gr.kd * dRoll + gr.ki * self._iRoll, -1, 1)

	local coordYaw = math.Clamp(targetYaw * 0.25, -0.35, 0.35)
	local coordLat = math.Clamp(VelL.y / 600, -0.35, 0.35)
	local targetRollFactor = math.Clamp(pidRoll + coordYaw + coordLat, -1, 1)

	-- Apply turbulence if active, but reduce effects when near target angle
	if turbulenceEffect > 0 then
		-- Scale turbulence effects based on how close we are to target
		local isPitchNearTarget = math.abs(LocalAngPitch) < 5.0
		local isYawNearTarget = math.abs(LocalAngYaw) < 5.0
		local isRollNearTarget = math.abs(LocalAngRoll) < 5.0

		-- Reduce turbulence when near target to prevent constant bouncing
		local pitchTurbScale = isPitchNearTarget and 0.5 or 1.0
		local yawTurbScale = isYawNearTarget and 0.5 or 1.0
		local rollTurbScale = isRollNearTarget and 0.5 or 1.0

		-- Add subtle randomness to control inputs based on turbulence
		Pitch = Pitch + (math.sin(CurTime() * 2.7) * turbulenceEffect * 0.15 * pitchTurbScale)
		Yaw = Yaw + (math.cos(CurTime() * 2.3) * turbulenceEffect / 10 * yawTurbScale)
		targetRollFactor = targetRollFactor + (math.sin(CurTime() * 1.9) * turbulenceEffect / 4 * rollTurbScale)
	end

	-- Check if we're very near target on all axes
	local isVeryStable = (math.abs(LocalAngPitch) < 3.0 and math.abs(LocalAngYaw) < 3.0 and math.abs(LocalAngRoll) < 3.0)

	-- Apply stronger interpolation when very stable to prevent micro-oscillations
	local rollInterp = isVeryStable and adaptiveInterp * 2.0 or adaptiveInterp
	local rollFactor = Lerp(rollInterp, self.PrevRoll, targetRollFactor)
	local Roll = rollFactor

	if OverrideRoll != 0 then
		-- More responsive roll override with smooth transition
		local targetRoll = math.Clamp(self:WorldToLocalAngles(Angle(Ang.p, Ang.y, OverrideRoll * 60)).r / 40, -1, 1)
		Roll = Lerp(adaptiveInterp * 1.5, self.PrevRoll, targetRoll)  -- Faster transition for overrides
	end

	-- Store values for next frame interpolation
	self.PrevPitch = Pitch
	self.PrevYaw = Yaw
	self.PrevRoll = Roll

	self.Roll = Roll

	if OverridePitch and OverridePitch != 0 then
		Pitch = OverridePitch
	end

	if OverrideYaw and OverrideYaw != 0 then
		Yaw = OverrideYaw
	end

	self:SetSteer(Vector(Roll, -Pitch, -Yaw))
end

function ENT:OnSkyCollide( data, PhysObj )

	local NewVelocity = self:VectorSubtractNormal( data.HitNormal, data.OurOldVelocity ) - data.HitNormal * 50

	PhysObj:SetVelocityInstantaneous( NewVelocity )
	PhysObj:SetAngleVelocityInstantaneous( data.OurOldAngularVelocity )

	return true
end

function ENT:PhysicsSimulate( phys, deltatime )
	if self:GetEngineActive() then phys:Wake() end

	local EntTable = self:GetTable()

	local WorldGravity = self:GetWorldGravity()
	local WorldUp = self:GetWorldUp()

	local Up = self:GetUp()
	local Left = -self:GetRight()

	local Mul = self:GetThrottle()
	local InputThrust = math.min( self:GetThrust() , 0 ) * EntTable.ThrustDown + math.max( self:GetThrust(), 0 ) * EntTable.ThrustUp

	-- Initialize turbulence variables if they don't exist
	self.TurbulenceTime = self.TurbulenceTime or 0
	self.TurbulenceIntensity = self.TurbulenceIntensity or 0
	self.OscillationX = self.OscillationX or 0
	self.OscillationY = self.OscillationY or 0
	self.WindDirection = self.WindDirection or VectorRand():GetNormalized()
	self.WindTimer = self.WindTimer or 0

	-- Update turbulence over time
	if self:GetEngineActive() and Mul > 0.1 and self.EnableTurbulence then
		self.TurbulenceTime = self.TurbulenceTime + deltatime

		-- Change wind direction gradually
		if self.WindTimer < CurTime() then
			self.WindTimer = CurTime() + math.random(5, 15)
			local targetDir = VectorRand():GetNormalized()
			self.WindDirection = LerpVector(0.2, self.WindDirection, targetDir)
		end

		-- Calculate turbulence based on speed and altitude
		local vel = phys:GetVelocity():Length()
		local altitude = math.max(self:GetPos().z, 10)  -- Higher altitude = more turbulence
		self.TurbulenceIntensity = math.Clamp((vel / 1000) / 2 +
			(math.sin(self.TurbulenceTime / 2) / 2 + 0.5) / 4 +
			math.min(altitude / 5000, 0.3), 0, 0.8) * Mul

		-- Apply oscillation for hover feel
		self.OscillationX = math.sin(self.TurbulenceTime) / 8 * self.TurbulenceIntensity
		self.OscillationY = math.cos(self.TurbulenceTime) / 4 * self.TurbulenceIntensity
	else
		self.TurbulenceIntensity = math.max(0, self.TurbulenceIntensity - deltatime / 2)
		self.OscillationX = 0
		self.OscillationY = 0
	end

	if self:HitGround() and InputThrust <= 0 then
		Mul = 0
		self.TurbulenceIntensity = 0
		self.OscillationX = 0
		self.OscillationY = 0
	end

	-- mouse aim needs to run at high speed.
	if self:GetAI() then
		self:CalcAIMove( phys, deltatime )
	else
		local client = self:GetDriver()
		if IsValid( client ) and client:lvsMouseAim() then
			self:PlayerMouseAim( client, phys, deltatime )
		end
	end

	local Steer = self:GetSteer()

	-- Apply turbulence to steering when appropriate
	if self.EnableTurbulence and self.TurbulenceIntensity > 0 and self:GetEngineActive() then
		-- Add wind-influenced turbulence to steering
		local windEffect = self.WindDirection * self.TurbulenceIntensity * 0.15
		Steer = Steer + Vector(
			self.OscillationX + windEffect.x / 10,  -- Roll turbulence
			self.OscillationY + windEffect.y / 10,  -- Pitch turbulence
			windEffect.z * 0.08                      -- Yaw turbulence
		)
	end

	local Vel = phys:GetVelocity()
	local VelL = phys:WorldToLocal( phys:GetPos() + Vel )
	local VelLength = Vel:Length()

	-- Use VelL for rotor stability simulation - lateral movement affects handling
	local lateralMovement = Vector(VelL.x, VelL.y, 0):Length()
	self.StabilityFactor = math.Clamp(1 - lateralMovement / 1000, 0.6, 1)

	local YawPull = (math.deg( math.acos( math.Clamp( WorldUp:Dot( Left ) ,-1,1) ) ) - 90) /  90

	-- Enhanced gravity yaw effect based on speed
	local speedFactor = math.min(VelLength / EntTable.MaxVelocity, 1) ^ 2
	local GravityYaw = math.abs(YawPull) ^ 1.25 * self:Sign(YawPull) * (WorldGravity / 100) * speedFactor

	-- Add more responsive controls at higher speeds
	local speedResponse = math.Clamp(VelLength / 500, 0, 1) / 4

	-- Apply mild oscillation during hover
	local hoverOscillation = 0
	if VelLength < 300 and self:GetEngineActive() and not self:HitGround() then
		hoverOscillation = math.sin(CurTime() * 1.5) * 0.03 * self:GetThrottle()
	end

	local Pitch = math.Clamp(Steer.y + hoverOscillation, -1, 1) * EntTable.TurnRatePitch * (1 + speedResponse)
	local Yaw = math.Clamp(Steer.z + GravityYaw * 0.15, -1, 1) * EntTable.TurnRateYaw * 45
	local Roll = math.Clamp(Steer.x, -1, 1) * 1.3 * EntTable.TurnRateRoll * (1 + speedResponse / 3)

	local FadeMul = (1 - math.max((45 - self:AngleBetweenNormal(WorldUp, Up)) / 45, 0)) ^ 2
	local ThrustMul = math.Clamp(1 - (VelLength / EntTable.MaxVelocity) * FadeMul, 0, 1)

	-- Apply steady environmental wind (linear) independent from turbulence if enabled
	local windInfluence = Vector(0,0,0)
	if self.EnableWind and self.WindDirection and self.WindStrength and self:GetEngineActive() then
		local windScale = (self.WindLinearScale or 120)
		local windVelOpposition = -Vel * 0.03 -- slight drag-like interaction with air mass
		windInfluence = (self.WindDirection * self.WindStrength * windScale + windVelOpposition) * Mul
	else
		-- fallback: minor turbulence-based influence if turbulence enabled
		windInfluence = (self.EnableTurbulence and self.WindDirection or Vector(0,0,0)) * (self.TurbulenceIntensity or 0) * 50 * Mul
	end

	local Thrust = self:LocalToWorldAngles(Angle(Pitch, 0, Roll)):Up() * (WorldGravity + InputThrust * 500 * ThrustMul) * Mul

	local Force, ForceAng = phys:CalculateForceOffset(Thrust, phys:LocalToWorld(phys:GetMassCenter()) + self:GetUp() * 1000)

	local ForceLinear = (Force - Vel * 0.2 * EntTable.ForceLinearDampingMultiplier + windInfluence) * Mul
	local ForceAngle = (ForceAng + (Vector(0, 0, Yaw) - phys:GetAngleVelocity() * 2.2 * EntTable.ForceAngleDampingMultiplier) * deltatime * 220) * Mul

	-- Add gust torque (environmental wind bursts)
	if self.EnableWind and self._gustActive then
		local gScale = (self.WindGustTorqueScale or 35)
		-- torque vector in local-ish frame; bias around roll/yaw to feel like blade slap
		local g = self._gustDir or self:GetRight()
		local torque = Vector(g.x * 0.6, g.y * 0.4, g.z * 0.8) * (self._gustStrength or 0.4) * gScale
		ForceAngle = ForceAngle + torque * Mul
	end

	-- Add slight turbulence to angle force
	if self.EnableTurbulence and self.TurbulenceIntensity > 0 then
		ForceAngle = ForceAngle + Vector(
			math.sin(self.TurbulenceTime * 2.3) * 5 * self.TurbulenceIntensity,
			math.cos(self.TurbulenceTime * 1.7) * 6 * self.TurbulenceIntensity,
			math.sin(self.TurbulenceTime * 1.3) * 4 * self.TurbulenceIntensity
		) * Mul
	end

	-- Subtle rotor/body shake torque for dynamic feel (does not destabilize much)
	if self.EnableBodyShake and self:GetEngineActive() and not self:HitGround() then
		local amp = (self.BodyShakeAmplitude or 0.6)
		local spd = (self.BodyShakeSpeed or 2.4)
		local throttle = self.GetThrustPercent and self:GetThrustPercent() or (self.GetThrottle and self:GetThrottle() or 0)
		local speedMul = math.Clamp(VelLength / (self.MaxVelocity or 2000), 0, 1)
		local a = amp * (0.6 * throttle + 0.4 * speedMul)
		if a > 0.001 then
			local t = CurTime() + (self:EntIndex() * 0.13)
			local shake = Vector(
				math.sin(t * 3.1 * spd) * 1.0,
				math.cos(t * 2.7 * spd) * 1.2,
				math.sin(t * 2.2 * spd + 1.3) * 0.8
			) * a
			ForceAngle = ForceAngle + shake
		end
	end

	if EntTable._SteerOverride then
		ForceAngle.z = (EntTable._SteerOverrideMove * math.max(self:GetThrust() * 2, 1) * 100 - phys:GetAngleVelocity().z) * Mul
	end

	return ForceAngle, ForceLinear, SIM_GLOBAL_ACCELERATION
end

function ENT:ApproachThrust( New, Delta )
	if not Delta then
		Delta = FrameTime()
	end

	local Cur = self:GetThrust()

	-- Calculate thrust adjustment factor based on stability
	local stabilityFactor = self.StabilityFactor or 1

	-- Make thrust changes more responsive but slightly less stable in turbulence
	local thrustResponseRate = self.ThrustRate * 2.5 * stabilityFactor

	-- Add slight random variations to thrust for more realistic feeling
	local thrustVariation = 0
	if self.EnableTurbulence and self.TurbulenceIntensity and self.TurbulenceIntensity > 0 then
		thrustVariation = (math.sin(CurTime() * 3.7) * 0.05) * self.TurbulenceIntensity
	end

	self:SetThrust( Cur + (New - Cur) * Delta * thrustResponseRate + thrustVariation * Delta )
end

function ENT:CalcThrust( KeyUp, KeyDown, Delta )
	if self:HitGround() and not KeyUp then
		self:ApproachThrust( -1, Delta )
		self.Roll = self:GetAngles().r

		return
	end

	local Up = KeyUp and 1 or 0
	local Down = KeyDown and -1 or 0

	self:ApproachThrust( Up + Down, Delta )
end

function ENT:CalcHover( InputLeft, InputRight, InputUp, InputDown, ThrustUp, ThrustDown, PhysObj, deltatime )
	if not IsValid( PhysObj ) then
		PhysObj = self:GetPhysicsObject()
	end

	-- Filter local velocity for smoother auto-level sensing
	local rawVelL = PhysObj:WorldToLocal( PhysObj:GetPos() + PhysObj:GetVelocity() )
	self._hoverVelL = self._hoverVelL or rawVelL
	local velFiltRate = (self.HoverVelFilterRate or 4.0)
	local velStep = math.Clamp(deltatime * velFiltRate, 0, 1)
	self._hoverVelL = self._hoverVelL + (rawVelL - self._hoverVelL) * velStep
	local VelL = self._hoverVelL
	local AngVel = PhysObj:GetAngleVelocity()

	local KeyLeft = InputLeft and 60 or 0
	local KeyRight = InputRight and 60 or 0
	local KeyPitchUp = InputUp and 60 or 0
	local KeyPitchDown = InputDown and 60 or 0

	local Pitch = KeyPitchDown - KeyPitchUp
	local Roll = KeyRight - KeyLeft

	-- Initialize hover oscillation variables if they don't exist
	self.HoverTimeX = (self.HoverTimeX or 0) + deltatime * 1.5
	self.HoverTimeY = (self.HoverTimeY or 0) + deltatime * 1.7

	-- Only apply auto-leveling corrections when no manual input is given
	if (Pitch + Roll) == 0 then
		-- More responsive auto-leveling with subtle oscillation for realism
		local hoverOscX = math.sin(self.HoverTimeX) * 1.5
		local hoverOscY = math.cos(self.HoverTimeY) * 1.3

		-- Calculate auto-leveling with enhanced response
	Pitch = math.Clamp(-VelL.x / 180, -1, 1) * 60 + hoverOscX
	Roll = math.Clamp(VelL.y / 230, -1, 1) * 60 + hoverOscY

	-- Apply turbulence if active
	if self.EnableTurbulence and self.TurbulenceIntensity and self.TurbulenceIntensity > 0 then
			local turbFactor = self.TurbulenceIntensity * 15
			Pitch = Pitch + (math.sin(CurTime() * 2.2) * turbFactor)
			Roll = Roll + (math.cos(CurTime() * 1.8) * turbFactor)
		end
	end

	local Ang = self:GetAngles()

	-- Calculate stability factor - lower when moving faster
	local stabilityFactor = self.StabilityFactor or 1

	-- Build target steer from requested corrections
	local targetSteer = self:GetSteer()
	targetSteer.x = math.Clamp( (Roll - Ang.r - AngVel.x * 0.8) * stabilityFactor, -1, 1)
	targetSteer.y = math.Clamp( (Pitch - Ang.p - AngVel.y * 0.8) * stabilityFactor, -1, 1)

	-- Rate-limit and smooth steer changes for hover
	local curSteer = self:GetSteer()
	local maxDelta = (self.HoverSteerMaxDelta or 1.2) * deltatime
	local lerpRate = math.Clamp(deltatime * (self.HoverSteerLerpRate or 10.0), 0, 1)

	local dx = math.Clamp(targetSteer.x - curSteer.x, -maxDelta, maxDelta)
	local dy = math.Clamp(targetSteer.y - curSteer.y, -maxDelta, maxDelta)
	local newSteerX = curSteer.x + dx
	local newSteerY = curSteer.y + dy

	-- Small lerp on top to remove residual jerk
	newSteerX = Lerp(lerpRate, curSteer.x, newSteerX)
	newSteerY = Lerp(lerpRate, curSteer.y, newSteerY)

	self:SetSteer( Vector(newSteerX, newSteerY, curSteer.z) )

	self.Roll = Ang.r

	-- In hover, manual thrust inputs are blended (limited) with auto altitude control instead of overriding it

	-- Enhanced auto-altitude control with filtering and slight oscillation
	local altitudeTarget = math.Clamp(-VelL.z / 100, -1, 1)

	-- Add slight oscillation for more natural feel
	if self.TurbulenceIntensity and self.TurbulenceIntensity > 0 then
		altitudeTarget = altitudeTarget + math.sin(CurTime() * 0.8) * 0.05 * self.TurbulenceIntensity
	end

	-- Add a tiny vertical integrator to smooth thrust settle in hover
	self._hoverAltI = (self._hoverAltI or 0) * math.max(0, 1 - deltatime * 2) + altitudeTarget * deltatime * 0.5
	local smoothAltCmd = math.Clamp(altitudeTarget + math.Clamp(self._hoverAltI, -0.2, 0.2), -1, 1)

	-- Blend limited user thrust input (e.g., 20%) into hover command
	local userCmd = 0
	if ThrustUp then userCmd = userCmd + 1 end
	if ThrustDown then userCmd = userCmd - 1 end
	local blend = math.Clamp(self.HoverUserThrustScale or 0.2, 0, 1)
	local finalCmd = math.Clamp(smoothAltCmd * (1 - blend) + userCmd * blend, -1, 1)

	-- Slow thrust response a bit during hover
	local oldRate = self.ThrustRate
	self.ThrustRate = (oldRate or 1) * (self.HoverThrustRateMul or 0.6)
	self:ApproachThrust(finalCmd, deltatime)
	self.ThrustRate = oldRate
end
