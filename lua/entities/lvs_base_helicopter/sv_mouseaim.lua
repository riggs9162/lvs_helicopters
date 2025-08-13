
function ENT:PlayerMouseAim( ply, phys, deltatime )
	local Pod = self:GetDriverSeat()

	local PitchUp = ply:lvsKeyDown( "+PITCH_HELI" )
	local PitchDown = ply:lvsKeyDown( "-PITCH_HELI" )
	local YawRight = ply:lvsKeyDown( "+YAW_HELI" )
	local YawLeft = ply:lvsKeyDown( "-YAW_HELI" )
	local RollRight = ply:lvsKeyDown( "+ROLL_HELI" )
	local RollLeft = ply:lvsKeyDown( "-ROLL_HELI" )

	local FreeLook = ply:lvsKeyDown( "FREELOOK" )

	-- Initialize turn rate limiter if not exists
	self.YawTurnRate = self.YawTurnRate or 0
	self.MaxYawRate = 0.04 -- Maximum allowed turn rate per frame

	local EyeAngles = Pod:WorldToLocalAngles( ply:EyeAngles() )

	if FreeLook then
		if isangle( self.StoredEyeAngles ) then
			EyeAngles = self.StoredEyeAngles
		end
	else
		self.StoredEyeAngles = EyeAngles
	end

	-- Simple direct controls
	local OverridePitch = 0
	local OverrideYaw = 0
	local OverrideRoll = (RollRight and 1 or 0) - (RollLeft and 1 or 0)

	if PitchUp or PitchDown then
		EyeAngles = self:GetAngles()
		self.StoredEyeAngles = Angle(EyeAngles.p, EyeAngles.y, 0)
		OverridePitch = (PitchUp and 1 or 0) - (PitchDown and 1 or 0)
	end

	-- Handle yaw controls more conservatively to prevent unexpected behavior
	-- Only use direct input with reduced strength and no angle changes
	if YawRight or YawLeft then
		-- Keep existing angle, don't change to vehicle angle (key difference)
		OverrideYaw = ((YawRight and 1 or 0) - (YawLeft and 1 or 0)) * 0.7  -- Reduced strength for better control
	end

	-- Remove all drift for now to eliminate possible causes of instability

	-- When turning, we need to be extra careful with the eye angles
	-- If yaw controls are being used, use current helicopter angles as the base
	if (YawLeft or YawRight) and not FreeLook then
		local currentAngle = self:GetAngles()
		-- Maintain some eye control for pitch but use vehicle's current yaw angle
		local safeAngle = Angle(EyeAngles.p, currentAngle.y, EyeAngles.r)
		self:ApproachTargetAngle( safeAngle, OverridePitch, OverrideYaw, OverrideRoll, FreeLook, phys, deltatime )
	else
		-- Normal control for non-turning situations
		self:ApproachTargetAngle( EyeAngles, OverridePitch, OverrideYaw, OverrideRoll, FreeLook, phys, deltatime )
	end

	if ply:lvsKeyDown( "HELI_HOVER" ) then
		self:CalcHover( RollLeft, RollRight, PitchUp, PitchDown, ply:lvsKeyDown( "+THRUST_HELI" ), ply:lvsKeyDown( "-THRUST_HELI" ), phys, deltatime )

		self.ResetSteer = true
	else
		if self.ResetSteer then
			self.ResetSteer = nil

			self:SetSteer( Vector(0,0,0) )
		end

		self:CalcThrust( ply:lvsKeyDown( "+THRUST_HELI" ), ply:lvsKeyDown( "-THRUST_HELI" ), deltatime )
	end
end
