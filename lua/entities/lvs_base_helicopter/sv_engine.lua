
function ENT:CalcThrottle()
	if not self:GetEngineActive() then

		if self:GetThrottle() ~= 0 then self:SetThrottle( 0 ) end

		return
	end

	local Delta = FrameTime()

	local Cur = self:GetThrottle()
	local New = self._StopEngine and 0 or 1

	if self:IsDestroyed() then New = 0 end

	if Cur == New and New == 0 then self:TurnOffEngine() return end

	self:SetThrottle( Cur + math.Clamp(New - Cur, -self.ThrottleRateDown * Delta, self.ThrottleRateUp * Delta) )
end

function ENT:HandleStart()
	local Driver = self:GetDriver()

	if IsValid( Driver ) then
		local KeyReload = Driver:lvsKeyDown( "ENGINE" )

		if self.OldKeyReload ~= KeyReload then
			self.OldKeyReload = KeyReload

			if KeyReload then
				self:ToggleEngine()
			end
		end
	end

	self:CalcThrottle()

	-- Update environmental effects to make flying more dynamic
	self:UpdateEnvironmentalEffects()
end

function ENT:ToggleEngine()
	if self:GetEngineActive() and not self._StopEngine then
		self:StopEngine()
	else
		self:StartEngine()
	end
end

function ENT:StartEngine()
	if not self:IsEngineStartAllowed() then return end
	if self._EngineDestroyed then return end

	if self:GetEngineActive() then
		self._StopEngine = nil

		return
	end

	self:PhysWake()

	self:SetEngineActive( true )
	self:OnEngineActiveChanged( true )

	self._StopEngine = nil
end

function ENT:StopEngine()
	if self._StopEngine then return end

	self._StopEngine = true
	self:OnEngineActiveChanged( false )

	if self:WaterLevel() >= self.WaterLevelAutoStop then
		self:TurnOffEngine()
	end
end

function ENT:TurnOffEngine()
	if not self:GetEngineActive() then return end

	self:SetEngineActive( false )

	self._StopEngine = nil
end

-- Function to simulate environmental effects on the helicopter
function ENT:UpdateEnvironmentalEffects()
	if not self:GetEngineActive() then return end

	-- Initialize persistent wind state
	self.WindDirection = self.WindDirection or VectorRand():GetNormalized()
	self.WindStrength = self.WindStrength or 0

	-- Update wind every so often
	if (self.NextWindUpdate or 0) < CurTime() then
		self.NextWindUpdate = CurTime() + math.random(10, 20)

		-- Create a slightly changing wind direction
		self.WindDirection = self.WindDirection or VectorRand():GetNormalized()
		local targetDir = VectorRand():GetNormalized()
		self.WindDirection = LerpVector(0.2, self.WindDirection, targetDir)

		-- Calculate wind strength based on world position (higher = windier)
		local altitude = math.max(self:GetPos().z, 10)  -- Use altitude for wind calculation
		self.WindStrength = math.Clamp(altitude / 10000, 0, 1) * math.Rand(0.5, 1.5)
	end

	-- Wind gusts (short-lived torque bursts)
	if self.EnableWind then
		self._gustActive = self._gustActive or false
		if not self._gustActive and (self._nextGust or 0) < CurTime() then
			self._gustActive = true
			local minI = self.WindGustIntervalMin or 4
			local maxI = self.WindGustIntervalMax or 10
			self._nextGust = CurTime() + math.random(minI, maxI)

			-- gust parameters
			local minD = self.WindGustDurationMin or 0.8
			local maxD = self.WindGustDurationMax or 2.0
			self._gustEnd = CurTime() + math.random(minD * 100, maxD * 100) * 0.01
			self._gustDir = (self.WindDirection + VectorRand() * 0.2):GetNormalized()
			self._gustStrength = (self.WindStrength or 0.3) * math.Rand(0.6, 1.2)
		elseif self._gustActive and CurTime() >= (self._gustEnd or 0) then
			self._gustActive = false
		end
	end

	-- Turbulence occurs in bursts
	if (self.NextTurbulenceBurst or 0) < CurTime() then
		if math.random() > 0.7 then
			-- Create a turbulence burst
			self.NextTurbulenceBurst = CurTime() + math.random(5, 15)
			self.TurbulenceBurstIntensity = math.Rand(0.1, 0.6)
			self.TurbulenceBurstDuration = CurTime() + math.random(2, 6)
		else
			-- Small delay before checking again
			self.NextTurbulenceBurst = CurTime() + 1
			self.TurbulenceBurstIntensity = 0
		end
	end

	-- Apply active turbulence burst if it's still going
	if (self.TurbulenceBurstDuration or 0) > CurTime() then
		self.TurbulenceIntensity = math.Approach(
			self.TurbulenceIntensity or 0,
			self.TurbulenceBurstIntensity or 0,
			FrameTime() * 0.2
		)
	else
		-- Gradually reduce turbulence
		self.TurbulenceIntensity = math.max(0, (self.TurbulenceIntensity or 0) - FrameTime() * 0.1)
	end
end
