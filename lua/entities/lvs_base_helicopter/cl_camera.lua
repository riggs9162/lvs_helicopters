-- Third-person camera dynamic distance/FOV based on yaw offset
local cvar_tpcam_yaw_dist_enable = CreateClientConVar("lvs_heli_tpcam_yaw_dist_enable", "1", true, false)
local cvar_tpcam_yaw_dist_max    = CreateClientConVar("lvs_heli_tpcam_yaw_dist_max", "220", true, false)
-- (FOV-based adjustments removed; keep distance-only behavior)

-- Camera shake cvars (client)
local cvar_shake_enable  = CreateClientConVar("lvs_heli_shake_enable", "1", true, false)
local cvar_shake_amp     = CreateClientConVar("lvs_heli_shake_amp", "0.6", true, false)
local cvar_shake_speed   = CreateClientConVar("lvs_heli_shake_speed", "1.2", true, false)
local cvar_shake_fp_only = CreateClientConVar("lvs_heli_shake_fp_only", "1", true, false)
-- Camera alignment cvars (client)
local cvar_align_enable = CreateClientConVar("lvs_heli_align_enable", "1", true, false)
local cvar_align_factor = CreateClientConVar("lvs_heli_align_factor", "0.65", true, false)
local cvar_align_roll   = CreateClientConVar("lvs_heli_align_roll", "1", true, false)
local cvar_align_rate   = CreateClientConVar("lvs_heli_align_rate", "10", true, false)

-- Third-person camera smoothing (client)
local cvar_tpcam_lerp_enable = CreateClientConVar("lvs_heli_tpcam_lerp_enable", "1", true, false)
local cvar_tpcam_lerp_rate   = CreateClientConVar("lvs_heli_tpcam_lerp_rate", "12", true, false)
local cvar_tpcam_ang_lerp    = CreateClientConVar("lvs_heli_tpcam_ang_lerp", "1", true, false)
local cvar_tpcam_ang_rate    = CreateClientConVar("lvs_heli_tpcam_ang_rate", "10", true, false)
-- Third-person look-at bias toward the helicopter
local cvar_tpcam_look_enable = CreateClientConVar("lvs_heli_tpcam_look_enable", "1", true, false)
local cvar_tpcam_look_factor = CreateClientConVar("lvs_heli_tpcam_look_factor", "0.5", true, false)
local cvar_tpcam_look_up     = CreateClientConVar("lvs_heli_tpcam_look_up", "0", true, false)
local cvar_tpcam_look_fwd    = CreateClientConVar("lvs_heli_tpcam_look_fwd", "0", true, false)

ENT._lvsSmoothFreeLook = 0

-- Apply subtle procedural camera shake; modifies 'view' in place
function ENT:ApplyCameraShake(view, pod, isFirstPerson)
	if not cvar_shake_enable:GetBool() then return end
	if cvar_shake_fp_only:GetBool() and not isFirstPerson then return end
	self._shakeSeed = self._shakeSeed or self:EntIndex() * 0.37
	self._lastShakeAngles = self._lastShakeAngles or self:GetAngles()
	self._lastShakeTime = self._lastShakeTime or CurTime()

	local now = CurTime()
	local dt = math.max(now - self._lastShakeTime, 0.001)
	self._lastShakeTime = now

	-- Motion-based factors
	local vel = self:GetVelocity()
	local speed = vel:Length()
	local thrustPct = 0
	if self.GetThrustPercent then
		thrustPct = self:GetThrustPercent() or 0
	elseif self.GetThrottle then
		thrustPct = self:GetThrottle() or 0
	end

	-- Approx angular rate using angle delta (client-safe)
	local curAng = self:GetAngles()
	local dPitch = math.abs(curAng.p - self._lastShakeAngles.p)
	local dYaw   = math.abs(curAng.y - self._lastShakeAngles.y)
	local dRoll  = math.abs(curAng.r - self._lastShakeAngles.r)
	self._lastShakeAngles = Angle(curAng.p, curAng.y, curAng.r)
	local angRate = (dPitch + dYaw + dRoll) / dt

	-- Intensity model:
	-- base from thrust, add with speed, plus small contribution from angular changes
	local base = thrustPct * 0.6 + math.Clamp(speed / 2500, 0, 0.5) + math.Clamp(angRate / 360, 0, 0.3)
	local intensity = base * cvar_shake_amp:GetFloat()
	if intensity <= 0 then return end

	-- Frequency
	local w = 2.2 * cvar_shake_speed:GetFloat()
	local t = now + self._shakeSeed

	-- Low-frequency rumble + slightly higher-frequency blade jitter
	local lf = 0.7 * math.sin(t * w * 0.6) + 0.3 * math.cos(t * w * 0.43)
	local hf = 0.5 * math.sin(t * w * 1.7) + 0.5 * math.cos(t * w * 1.3)

	local shakeAngle = lf * 0.7 + hf * 0.3
	local shakePos   = lf * 0.5 + hf * 0.5

	-- Scale in first person a bit stronger, lighter in third person
	local fpMul = isFirstPerson and 1.0 or 0.6

	-- Reduce shake while zoomed for aiming (if pod is valid)
	local zoomMul = 1.0
	-- no zoom adjustment in third person for now

	-- Apply offsets (keep subtle)
	local a = intensity * fpMul * zoomMul
	if view.angles then
		view.angles.p = view.angles.p + shakeAngle * a * 0.8
		view.angles.y = view.angles.y + shakeAngle * a * 0.6
		if isFirstPerson then
			view.angles.r = (view.angles.r or 0) + shakeAngle * a * 0.4
		end
	end
	if view.origin then
		local up = self:GetUp()
		local right = self:GetRight()
		view.origin = view.origin + up * (shakePos * a * 1.2) + right * (shakePos * a * 0.8)
	end
end

-- Nudge the camera angles toward vehicle orientation for a more connected feel
function ENT:ApplyCameraAlign(view, pod, client, isFirstPerson)
	if not cvar_align_enable:GetBool() then return end
	if not view or not view.angles then return end
	if IsValid(client) and client:lvsKeyDown("FREELOOK") then return end

	local fac = math.Clamp(cvar_align_factor:GetFloat(), 0, 1)
	if fac <= 0 then return end

	-- Smooth vehicle attitude independently to avoid jitter
	local vehAng = self:GetAngles()
	if not cvar_align_roll:GetBool() then
		vehAng = Angle(vehAng.p, vehAng.y, 0)
	end

	self._camAlignAng = self._camAlignAng or Angle(vehAng.p, vehAng.y, vehAng.r)
	local rate = math.max(cvar_align_rate:GetFloat(), 0)
	local step = math.Clamp(RealFrameTime() * rate, 0, 1)
	self._camAlignAng = LerpAngle(step, self._camAlignAng, vehAng)

	-- Blend smoothed vehicle attitude into the current view
	view.angles = LerpAngle(fac, view.angles, self._camAlignAng)
end

function ENT:CalcViewDirectInput( client, pos, angles, fov, pod )
	local ViewPosL = pod:WorldToLocal( pos )

	local view = {}
	view.fov = 90
	view.drawviewer = true
	view.angles = self:GetAngles()

	local FreeLook = client:lvsKeyDown( "FREELOOK" )
	local Zoom = client:lvsKeyDown( "ZOOM" )

	if not pod:GetThirdPersonMode() then

		if FreeLook then
			view.angles = pod:LocalToWorldAngles( client:EyeAngles() )
		end

		local velL = self:WorldToLocal( self:GetPos() + self:GetVelocity() )

		local Dividor = math.abs( velL.x )
		local SideForce = math.Clamp( velL.y / Dividor, -1, 1)
		local UpForce = math.Clamp( velL.z / Dividor, -1, 1)

		local ViewPunch = Vector(0,math.Clamp(SideForce * 10,-1,1),math.Clamp(UpForce * 10,-1,1))
		if Zoom then
			ViewPunch = Vector(0,0,0)
		end

		pod._lerpPosOffset = pod._lerpPosOffset and pod._lerpPosOffset + (ViewPunch - pod._lerpPosOffset) * RealFrameTime() * 5 or Vector(0,0,0)
		pod._lerpPos = pos

		view.origin = pos + pod:GetForward() *  -pod._lerpPosOffset.y * 0.5 + pod:GetUp() *  pod._lerpPosOffset.z * 0.5
		view.angles.p = view.angles.p - pod._lerpPosOffset.z * 0.1
		view.angles.y = view.angles.y + pod._lerpPosOffset.y * 0.1
		-- Align 1st-person direct input toward vehicle to reduce drift/jitter
		self:ApplyCameraAlign(view, pod, client, true)
		view.drawviewer = false

		-- Fake shake (first-person)
		self:ApplyCameraShake(view, pod, true)

		return view
	end

	pod._lerpPos = pod._lerpPos or self:GetPos()

	local radius = 550
	radius = radius + radius * pod:GetCameraDistance()

	-- Dynamic camera distance based on yaw offset: bring the camera closer
	-- when the view is angled left/right. We no longer modify FOV here.
	local camYawOffset = math.abs(math.AngleDifference(view.angles.y, self:GetAngles().y))
	-- Use full 0..180 degree range so this works for the entire 360deg heading
	local yawFrac = math.Clamp(camYawOffset / 180, 0, 1) -- 0 = forward, 1 = 180deg (behind)
	if cvar_tpcam_yaw_dist_enable:GetBool() then
		-- Subtract distance when looking to the sides; clamp to a sensible minimum
		radius = math.max(100, radius - yawFrac * cvar_tpcam_yaw_dist_max:GetFloat())
	end

	if FreeLook then
		local velL = self:WorldToLocal( self:GetPos() + self:GetVelocity() )

		local SideForce = math.Clamp(velL.y / 10,-250,250)
		local UpForce = math.Clamp(velL.z / 10,-250,250)

		pod._lerpPosL = pod._lerpPosL and (pod._lerpPosL + (Vector(radius, SideForce,150 + radius * 0.1 + radius * pod:GetCameraHeight() + UpForce) - pod._lerpPosL) * RealFrameTime() * 12) or Vector(0,0,0)
		pod._lerpPos = self:LocalToWorld( pod._lerpPosL )

		view.origin = pod._lerpPos
		view.angles = self:LocalToWorldAngles( Angle(0,180,0) )
	else
		local TargetPos = self:LocalToWorld( Vector(500,0,150 + radius * 0.1 + radius * pod:GetCameraHeight()) )

		local Sub = TargetPos - pod._lerpPos
		local Dir = Sub:GetNormalized()
		-- local Dist = Sub:Length()

		local DesiredPos = TargetPos - self:GetForward() * (300 + radius) - Dir * 100

		pod._lerpPos = pod._lerpPos + (DesiredPos - pod._lerpPos) * RealFrameTime() * (Zoom and 30 or 12)
		pod._lerpPosL = self:WorldToLocal( pod._lerpPos )

		-- local vel = self:GetVelocity()

		view.origin = pod._lerpPos
		view.angles = self:GetAngles()
	end

	view.origin = view.origin + ViewPosL

	-- defer third-person angle smoothing until after alignment and look-at bias

	-- Align 3rd-person direct input toward vehicle orientation
	self:ApplyCameraAlign(view, pod, client, false)

	-- Slight look-at bias toward the helicopter (skip during freelook)
	if pod:GetThirdPersonMode() then
		if cvar_tpcam_look_enable:GetBool() and not FreeLook then
			local upOff = cvar_tpcam_look_up:GetFloat()
			local fwdOff = cvar_tpcam_look_fwd:GetFloat()
			local target = self:GetPos() + self:GetUp() * upOff + self:GetForward() * fwdOff
			local desiredAng = (target - view.origin):Angle()
			desiredAng.r = view.angles.r -- preserve current roll
			local lookFac = math.Clamp(cvar_tpcam_look_factor:GetFloat(), 0, 1)
			-- Increase look-at bias when we're not directly behind the vehicle.
			-- yawFrac is 0 when aligned, 1 when directly behind. We want more
			-- bias as we move from back (1) toward sides/front (0), so scale
			-- by (1 - yawFrac).
			local dynamicLook = lookFac * (1 - (yawFrac or 0))
			view.angles = LerpAngle(dynamicLook, view.angles, desiredAng)
		end

		-- Optional angle smoothing for third-person angles
		if cvar_tpcam_ang_lerp:GetBool() then
			self._tpCamAng = self._tpCamAng or Angle(view.angles.p, view.angles.y, view.angles.r)
			local stepAng = math.Clamp(RealFrameTime() * math.max(cvar_tpcam_ang_rate:GetFloat(), 0), 0, 1)
			self._tpCamAng = LerpAngle(stepAng, self._tpCamAng, view.angles)
			view.angles = Angle(self._tpCamAng.p, self._tpCamAng.y, self._tpCamAng.r)
		end
	end

	-- Fake shake (third-person)
	self:ApplyCameraShake(view, pod, false)

	return view
end

function ENT:CalcViewMouseAim( client, pos, angles, fov, pod )
	local cvarFocus = math.Clamp( LVS.cvarCamFocus:GetFloat() , -1, 1 )

	self._lvsSmoothFreeLook = self._lvsSmoothFreeLook + ((client:lvsKeyDown( "FREELOOK" ) and 0 or 1) - self._lvsSmoothFreeLook) * RealFrameTime() * 10

	local view = {}
	view.origin = pos
	view.fov = 90
	view.drawviewer = true
	view.angles = (self:GetForward() * (1 + cvarFocus) * self._lvsSmoothFreeLook * 0.8 + client:EyeAngles():Forward() * math.max(1 - cvarFocus, 1 - self._lvsSmoothFreeLook)):Angle()

	if cvarFocus >= 1 then
		view.angles = LerpAngle( self._lvsSmoothFreeLook, client:EyeAngles(), self:GetAngles() )
	else
		-- Respect roll lock preference
		if view.angles and not cvar_align_roll:GetBool() then
			view.angles.r = 0
		end
	end

	if not pod:GetThirdPersonMode() then
		-- Align 1st-person view toward vehicle attitude
		self:ApplyCameraAlign(view, pod, client, true)
		view.drawviewer = false
		-- Fake shake (first-person)
		self:ApplyCameraShake(view, pod, true)
		return view
	end

	local radius = 512
	radius = radius + radius * pod:GetCameraDistance()

	-- Dynamic camera distance based on yaw offset: bring the camera closer
	-- when the view is angled left/right. We no longer modify FOV here.
	local camYawOffset = math.abs(math.AngleDifference(view.angles.y, self:GetAngles().y))
	-- Use full 0..180 degree range so this works for the entire 360deg heading
	local yawFrac = math.Clamp(camYawOffset / 180, 0, 1)
	if cvar_tpcam_yaw_dist_enable:GetBool() then
		radius = math.max(100, radius - yawFrac * cvar_tpcam_yaw_dist_max:GetFloat())
	end

	local TargetOrigin = view.origin - view.angles:Forward() * radius  + view.angles:Up() * (radius * 0.2 + radius * pod:GetCameraHeight())
	local WallOffset = 4

	local tr = util.TraceHull( {
		start = view.origin,
		endpos = TargetOrigin,
		filter = function( e )
			local c = e:GetClass()
			local collide = not c:StartWith( "prop_physics" ) and not c:StartWith( "prop_dynamic" ) and not c:StartWith( "prop_ragdoll" ) and not e:IsVehicle() and not c:StartWith( "gmod_" ) and not c:StartWith( "lvs_" ) and not c:StartWith( "player" ) and not e.LVS

			return collide
		end,
		mins = Vector( -WallOffset, -WallOffset, -WallOffset ),
		maxs = Vector( WallOffset, WallOffset, WallOffset ),
	} )

	local desiredOrigin = tr.HitPos

	if tr.Hit and not tr.StartSolid then
		desiredOrigin = desiredOrigin + tr.HitNormal * WallOffset
	end

	-- Smooth third-person camera origin if enabled
	if cvar_tpcam_lerp_enable:GetBool() then
		self._tpCamPos = self._tpCamPos or desiredOrigin
		local step = math.Clamp(RealFrameTime() * math.max(cvar_tpcam_lerp_rate:GetFloat(), 0), 0, 1)
		self._tpCamPos = self._tpCamPos + (desiredOrigin - self._tpCamPos) * step
		view.origin = self._tpCamPos
	else
		view.origin = desiredOrigin
	end

	-- angle smoothing and look-at will be applied after alignment below

	-- Align 3rd-person view toward vehicle attitude
	self:ApplyCameraAlign(view, pod, client, false)

	-- Slight look-at bias toward the helicopter (skip during freelook)
	local FreeLook = client:lvsKeyDown( "FREELOOK" )
	if cvar_tpcam_look_enable:GetBool() and not FreeLook then
		local upOff = cvar_tpcam_look_up:GetFloat()
		local fwdOff = cvar_tpcam_look_fwd:GetFloat()
		local target = self:GetPos() + self:GetUp() * upOff + self:GetForward() * fwdOff
		local desiredAng = (target - view.origin):Angle()
		desiredAng.r = view.angles.r -- preserve current roll
		local lookFac = math.Clamp(cvar_tpcam_look_factor:GetFloat(), 0, 1)
		local dynamicLook = lookFac * (1 - (yawFrac or 0))
		view.angles = LerpAngle(dynamicLook, view.angles, desiredAng)
	end

	-- Optional angle smoothing for third-person angles
	if cvar_tpcam_ang_lerp:GetBool() then
		self._tpCamAng = self._tpCamAng or Angle(view.angles.p, view.angles.y, view.angles.r)
		local stepAng = math.Clamp(RealFrameTime() * math.max(cvar_tpcam_ang_rate:GetFloat(), 0), 0, 1)
		self._tpCamAng = LerpAngle(stepAng, self._tpCamAng, view.angles)
		view.angles = Angle(self._tpCamAng.p, self._tpCamAng.y, self._tpCamAng.r)
	end

	-- Fake shake (third-person)
	self:ApplyCameraShake(view, pod, false)
	return view
end

function ENT:CalcViewOverride( client, pos, angles, fov, pod )
	return pos, angles, fov
end

function ENT:CalcViewDriver( client, pos, angles, fov, pod )
	if pod:GetThirdPersonMode() then
		pos = self:WorldSpaceCenter()
	end

	if client:lvsMouseAim() then
		return self:CalcViewMouseAim( client, pos, angles, fov, pod )
	else
		return self:CalcViewDirectInput( client, pos, angles, fov, pod )
	end
end

function ENT:CalcViewPassenger( client, pos, angles, fov, pod )
	return LVS:CalcView( self, client, pos, angles, fov, pod )
end

function ENT:LVSCalcView( client, original_pos, original_angles, original_fov, pod )
	local pos, angles, fov = self:CalcViewOverride( client, original_pos, original_angles, original_fov, pod )

	if self:GetDriverSeat() == pod then
		return self:CalcViewDriver( client, pos, angles, fov, pod )
	else
		return self:CalcViewPassenger( client, pos, angles, fov, pod )
	end
end