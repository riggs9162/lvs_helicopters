
ENT.Base = "lvs_base"

ENT.PrintName = "[LVS] Base Helicopter"
ENT.Author = "Luna"
ENT.Information = "Luna's Vehicle Script"
ENT.Category = "[LVS]"

ENT.Spawnable			= false
ENT.AdminSpawnable		= false

ENT.MaxVelocity = 2150

ENT.ThrustUp = 1
ENT.ThrustDown = 0.8
ENT.ThrustRate = 1

ENT.ThrottleRateUp = 0.2
ENT.ThrottleRateDown = 0.2

ENT.TurnRatePitch = 0.9
ENT.TurnRateYaw = 0.9
ENT.TurnRateRoll = 0.9

ENT.ForceLinearDampingMultiplier = 2.0

ENT.ForceAngleMultiplier = 1
ENT.ForceAngleDampingMultiplier = 2.5

-- Flight stability configuration
ENT.EnableTurbulence = false -- Gate turbulence/wind for a steadier, more realistic feel by default

-- PID gains for attitude control (normalized error space)
-- Error is angle (deg) normalized by 20deg, rate is deg/s normalized by 90deg/s
ENT.PIDPitch = { kp = 1.2, kd = 0.35, ki = 0.00, iLimit = 0.35 }
ENT.PIDYaw   = { kp = 0.9,  kd = 0.30, ki = 0.00, iLimit = 0.30 }
ENT.PIDRoll  = { kp = 1.2,  kd = 0.35, ki = 0.00, iLimit = 0.35 }

-- Environmental wind and body shake (physical) configuration
ENT.EnableWind = true                 -- steady wind influence and gust torques
ENT.WindLinearScale = 120             -- scales linear wind force
ENT.WindGustTorqueScale = 35          -- scales angular torque from gusts
ENT.WindGustIntervalMin = 4           -- seconds between gusts (min)
ENT.WindGustIntervalMax = 10          -- seconds between gusts (max)
ENT.WindGustDurationMin = 0.8         -- gust duration (min)
ENT.WindGustDurationMax = 2.0         -- gust duration (max)

ENT.EnableBodyShake = true            -- subtle rotor/body shake torque
ENT.BodyShakeAmplitude = 0.6          -- base amplitude (scaled by throttle/speed)
ENT.BodyShakeSpeed = 2.4              -- base speed of shake oscillation

-- Hover smoothing configuration
ENT.HoverVelFilterRate   = 4.0   -- how quickly local velocity used for hover auto-level filters (1/s)
ENT.HoverSteerLerpRate   = 10.0  -- steer smoothing rate (1/s)
ENT.HoverSteerMaxDelta   = 1.2   -- max steer change per second (normalized units)
ENT.HoverThrustRateMul   = 0.6   -- slow thrust response while hovering
ENT.HoverUserThrustScale = 0.2   -- fraction of user thrust input applied in hover (0.2 = 20%)

function ENT:SetupDataTables()
	self:CreateBaseDT()

	self:AddDT( "Vector", "Steer" )
	self:AddDT( "Vector", "AIAimVector" )
	self:AddDT( "Float", "Throttle" )
	self:AddDT( "Float", "NWThrust" )
end

function ENT:PlayerDirectInput( client, cmd )
	local Pod = self:GetDriverSeat()

	local Delta = FrameTime()

	local KeyLeft = client:lvsKeyDown( "-ROLL_HELI" )
	local KeyRight = client:lvsKeyDown( "+ROLL_HELI" )
	local KeyPitchUp = client:lvsKeyDown( "+PITCH_HELI" )
	local KeyPitchDown = client:lvsKeyDown( "-PITCH_HELI" )
	local KeyRollRight = client:lvsKeyDown( "+YAW_HELI" )
	local KeyRollLeft = client:lvsKeyDown( "-YAW_HELI" )

	local MouseX = cmd:GetMouseX()
	local MouseY = cmd:GetMouseY()

	if client:lvsKeyDown( "FREELOOK" ) and not Pod:GetThirdPersonMode() then
		MouseX = 0
		MouseY = 0
	else
		client:SetEyeAngles( Angle(0,90,0) )
	end

	local SensX, SensY, ReturnDelta = client:lvsMouseSensitivity()

	if KeyPitchDown then MouseY = (10 / SensY) * ReturnDelta end
	if KeyPitchUp then MouseY = -(10 / SensY) * ReturnDelta end
	if KeyRollRight or KeyRollLeft then
		local NewX = (KeyRollRight and 10 or 0) - (KeyRollLeft and 10 or 0)

		MouseX = (NewX / SensX) * ReturnDelta
	end

	local Input = Vector( MouseX * 0.4 * SensX, MouseY * SensY, 0 )

	local Cur = self:GetSteer()

	-- Initialize momentum variables if they don't exist
	self.MomentumX = self.MomentumX or 0
	self.MomentumY = self.MomentumY or 0
	self.MomentumZ = self.MomentumZ or 0

	-- Enhanced rate with momentum calculation
	local Rate = Delta * 3 * ReturnDelta

	-- Create natural dampening that varies based on current momentum
	local momentumDampX = 1 - math.min(math.abs(self.MomentumX) * 0.5, 0.7) -- Less responsive when already turning fast
	local momentumDampY = 1 - math.min(math.abs(self.MomentumY) * 0.5, 0.7)

	-- Apply natural return-to-center with easing
	local returnForceX = -Cur.x * Delta * 5 * ReturnDelta * momentumDampX
	local returnForceY = -Cur.y * Delta * 5 * ReturnDelta * momentumDampY

	local New = Vector(Cur.x, Cur.y, 0) + Vector(
		math.Clamp(returnForceX, -Rate, Rate),
		math.Clamp(returnForceY, -Rate, Rate),
		0
	)

	-- Apply input with easing based on current movement
	local Target = New + Input * Delta * 0.8

	-- Update momentum (with easing in and out)
	self.MomentumX = math.Approach(self.MomentumX, Target.x - Cur.x, Delta * 2)
	self.MomentumY = math.Approach(self.MomentumY, Target.y - Cur.y, Delta * 2)

	-- Apply momentum to create inertia in movements
	local Fx = math.Clamp(Target.x + self.MomentumX * 0.3, -1, 1)
	local Fy = math.Clamp(Target.y + self.MomentumY * 0.3, -1, 1)

	-- Create more gradual yaw response using momentum
	local TargetFz = (KeyLeft and 1 or 0) - (KeyRight and 1 or 0)

	-- Update yaw momentum
	self.MomentumZ = math.Approach(self.MomentumZ, TargetFz - Cur.z, Delta * 1.5)

	-- Apply momentum to yaw for more realistic turning
	local Fz = Cur.z + math.Clamp(TargetFz - Cur.z, -Rate * 3, Rate * 3) + self.MomentumZ * 0.15

	local F = Cur + (Vector( Fx, Fy, Fz ) - Cur) * math.min(Delta * 100,1)

	self:SetSteer( F )

	if CLIENT then return end

	if client:lvsKeyDown( "HELI_HOVER" ) then
		self:CalcHover( client:lvsKeyDown( "-YAW_HELI" ), client:lvsKeyDown( "+YAW_HELI" ), KeyPitchUp, KeyPitchDown, client:lvsKeyDown( "+THRUST_HELI" ), client:lvsKeyDown( "-THRUST_HELI" ) )

		self.ResetSteer = true

	else
		if self.ResetSteer then
			self.ResetSteer = nil

			self:SetSteer( Vector(0,0,0) )
		end

		self:CalcThrust( client:lvsKeyDown( "+THRUST_HELI" ), client:lvsKeyDown( "-THRUST_HELI" ) )
	end
end

function ENT:StartCommand( client, cmd )
	if self:GetDriver() != client then return end

	if SERVER then
		local KeyJump = client:lvsKeyDown( "VSPEC" )

		if self._lvsOldKeyJump != KeyJump then
			self._lvsOldKeyJump = KeyJump

			if KeyJump then
				self:ToggleVehicleSpecific()
			end
		end
	end

	if not client:lvsMouseAim() then
		self:PlayerDirectInput( client, cmd )
	end
end

function ENT:SetThrust( New )
	if self:GetEngineActive() then
		self:SetNWThrust( math.Clamp(New,-1,1) )
	else
		self:SetNWThrust( 0 )
	end
end

function ENT:GetThrust()
	return self:GetNWThrust()
end

function ENT:GetThrustPercent()
	return math.Clamp(0.5 * self:GetThrottle() + self:GetThrust() * 0.5,0,1)
end

function ENT:GetThrustStrenght()
	return (1 - (self:GetVelocity():Length() / self.MaxVelocity)) * self:GetThrustPercent()
end

function ENT:GetVehicleType()
	return "helicopter"
end