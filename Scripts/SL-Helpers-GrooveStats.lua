-- -----------------------------------------------------------------------
-- Returns an actor that can write a request, wait for its response, and then
-- perform some action. This actor will only wait for one response at a time.
-- If we make a new request while we are already waiting on a response, we
-- will cancel the current request and make a new one.
--
-- Usage:
-- af[#af+1] = RequestResponseActor(100, 0)
--
-- Which can then be triggered from within the OnCommand of the parent ActorFrame:
--
-- af.OnCommand=function(self)
--     self:playcommand("MakeRequest", {
--     endpoint="new-session.php?chartHashVersion="..SL.GrooveStats.ChartHashVersion,
--     method="GET",
--     timeout=10,
--     callback=NewSessionRequestProcessor,
--     args=self:GetParent()
-- })
-- end
--
-- (Alternatively, the OnCommand can be concatenated on to the returned actor itself.)

-- The params table passed to the playcommand can have the following keys (all optional):
--
-- endpoint: string, the endpoint at api.groovestats.com to send the request to.
-- method: string, the type of request to make.
--	       Valid values are GET, POST, PUT, PATCH, and DELETE.
-- body: string, the body for the request.
-- headers: table, a table containing key value pairs for the headers of the request.
-- timeout: number, the amount of time to wait for the request to complete in seconds.
-- callback: function, callback to process the response. It can take up to two
--       parameters:
--           data: The JSON response which has been converted back to a lua table
--           args: The provided args passed as is.
-- args: any, arguments that will be made accesible to the callback function. This
--       can of any type as long as the callback knows what to do with it.
--
-- x: The x position of the loading spinner.
-- y: The y position of the loading spinner.
RequestResponseActor = function(x, y)
	-- Sanitize the timeout value.
	local url_prefix = "https://api.groovestats.com/"

	return Def.ActorFrame{
		InitCommand=function(self)
			self.request_time = -1
			self.timeout = -1
			self.future = nil
			self:xy(x, y)
		end,
		MakeRequestCommand=function(self, params)
			if not params then return end

			-- Cancel any existing requests if we're waiting on one at the moment.
			if self.future then
				self.future:Cancel()
				self.future = nil
			end
			self:GetChild("Spinner"):visible(true)

			self.timeout = params.timeout or 60
			local endpoint = params.endpoint or ""
			local method = params.method
			local body = params.body
			local headers = params.headers

			-- Attempt to make the request
			self.future = NETWORK:HttpRequest{
				url=url_prefix..endpoint,
				method=method,
				body=body,
				headers=headers,
				connectTimeout=timeout,
				onResponse=function(response)
					self.future = nil
					if params.callback then
						params.callback(response, params.args)
					end
					self:GetChild("Spinner"):visible(false)
				end,
			}
			-- Keep track of when we started making the request
			self.request_time = GetTimeSinceStart()
			-- Start looping for the spinner.
			self:queuecommand("RequestLoop")
		end,
		RequestLoopCommand=function(self)
			local now = GetTimeSinceStart()
			local remaining_time = self.timeout - (now - self.request_time)
			self:playcommand("UpdateSpinner", {
				timeout=self.timeout,
				remaining_time=remaining_time
			})
			-- Only loop if the request is still on going.
			-- The callback always resets the future once its finished.
			if self.future then
				self:sleep(0.5):queuecommand("RequestLoop")
			end
		end,

		Def.ActorFrame{
			Name="Spinner",
			InitCommand=function(self)
				self:visible(false)
			end,
			Def.Sprite{
				Texture=THEME:GetPathG("", "LoadingSpinner 10x3.png"),
				Frames=Sprite.LinearFrames(30,1),
				InitCommand=function(self)
					self:zoom(0.15)
					self:diffuse(GetHexColor(SL.Global.ActiveColorIndex, true))
				end,
				VisualStyleSelectedMessageCommand=function(self)
					self:diffuse(GetHexColor(SL.Global.ActiveColorIndex, true))
				end
			},
			LoadFont("Common Normal")..{
				InitCommand=function(self)
					self:zoom(0.9)
					-- Leaderboard should be white since it's on a black background.
					self:diffuse(DarkUI() and name ~= "Leaderboard" and Color.Black or Color.White)
				end,
				UpdateSpinnerCommand=function(self, params)
					-- Only display the countdown after we've waiting for some amount of time.
					if params.timeout - params.remaining_time > 2 then
						self:visible(true)
					else
						self:visible(false)
					end
					if params.remaining_time > 1 then
						self:settext(math.floor(params.remaining_time))
					end
				end
			}
		},
	}
end

-- -----------------------------------------------------------------------
-- Sets the API key for a player if it's found in their profile.

ParseGrooveStatsIni = function(player)
	if not player then return "" end

	local profile_slot = {
		[PLAYER_1] = "ProfileSlot_Player1",
		[PLAYER_2] = "ProfileSlot_Player2"
	}
	
	if not profile_slot[player] then return "" end

	local dir = PROFILEMAN:GetProfileDir(profile_slot[player])
	local pn = ToEnumShortString(player)
	-- We require an explicit profile to be loaded.
	if not dir or #dir == 0 then return "" end

	local path = dir.. "GrooveStats.ini"

	if not FILEMAN:DoesFileExist(path) then
		-- The file doesn't exist. We will create it for this profile, and then just return.
		IniFile.WriteFile(path, {
			["GrooveStats"]={
				["ApiKey"]="",
				["IsPadPlayer"]=0,
			}
		})
	else
		local contents = IniFile.ReadFile(path)
		for k,v in pairs(contents["GrooveStats"]) do
			if k == "ApiKey" then
				if #v ~= 64 then
					-- Print the error only if the ApiKey is non-empty.
					if #v ~= 0 then
						SM(ToEnumShortString(player).." has invalid ApiKey length!")
					end
					SL[pn].ApiKey = ""
				else
					SL[pn].ApiKey = v
				end
			elseif k == "IsPadPlayer" then
				-- Must be explicitly set to 1.
				if v == 1 then
					SL[pn].IsPadPlayer = true
				else
					SL[pn].IsPadPlayer = false
				end
			end
		end
	end
end

-- -----------------------------------------------------------------------
-- The common conditions required to use the GrooveStats services.
-- Currently the conditions are:
--  - We initially got a GrooveStats conenction.
--  - We must be in the "dance" game mode (not "pump", etc)
--  - We must be in either ITG or FA+ mode.
--  - At least one Api Key must be available (this condition may be relaxed in the future)
--  - We must not be in course mode.
IsServiceAllowed = function(condition)
	return (condition and
		SL.GrooveStats.IsConnected and
		GAMESTATE:GetCurrentGame():GetName()=="dance" and
		(SL.Global.GameMode == "ITG" or SL.Global.GameMode == "FA+") and
		(SL.P1.ApiKey ~= "" or SL.P2.ApiKey ~= "") and
		not GAMESTATE:IsCourseMode())
end

-- -----------------------------------------------------------------------
-- ValidForGrooveStats.lua contains various checks requested by Archi
-- to determine whether the score should be permitted on GrooveStats
-- and returns a table of booleans, one per check, and also a bool
-- indicating whether all the checks were satisfied or not.
--
-- Obviously, this is trivial to circumvent and not meant to keep
-- malicious users out of GrooveStats. It is intended to prevent
-- well-intentioned-but-unaware players from accidentally submitting
-- invalid scores to GrooveStats.
ValidForGrooveStats = function(player)
	local pn = ToEnumShortString(player)
	local valid = {}

	-- ------------------------------------------
	-- First, check for modes not supported by GrooveStats.

	-- GrooveStats only supports dance for now (not pump, techno, etc.)
	valid[1] = GAMESTATE:GetCurrentGame():GetName() == "dance"

	-- GrooveStats does not support dance-solo (i.e. 6-panel dance like DDR Solo 4th Mix)
	-- https://en.wikipedia.org/wiki/Dance_Dance_Revolution_Solo
	valid[2] = GAMESTATE:GetCurrentStyle():GetName() ~= "solo"

	-- GrooveStats actually does rank Marathons from ITG1, ITG2, and ITG Home
	-- but there isn't QR support at this time.
	valid[3] = not GAMESTATE:IsCourseMode()

	-- GrooveStats was made with ITG settings in mind.
	-- FA+ is okay because it just halves ITG's TimingWindowW1 but keeps everything else the same.
	-- Casual (and Experimental, Demonic, etc.) uses different settings
	-- that are incompatible with GrooveStats ranking.
	valid[4] = (SL.Global.GameMode == "ITG" or SL.Global.GameMode == "FA+")

	-- ------------------------------------------
	-- Next, check global Preferences that would invalidate the score.

	-- TimingWindowScale and LifeDifficultyScale are a little confusing. Players can change these under
	-- Advanced Options in the operator menu on scales from [1 to Justice] and [1 to 7], respectively.
	--
	-- The OptionRow for TimingWindowScale offers [1, 2, 3, 4, 5, 6, 7, 8, Justice] as options
	-- and these map to [1.5, 1.33, 1.16, 1, 0.84, 0.66, 0.5, 0.33, 0.2] in Preferences.ini for internal use.
	--
	-- The OptionRow for LifeDifficultyScale offers [1, 2, 3, 4, 5, 6, 7] as options
	-- and these map to [1.6, 1.4, 1.2, 1, 0.8, 0.6, 0.4] in Preferences.ini for internal use.
	--
	-- I don't know the history here, but I suspect these preferences are holdovers from SM3.9 when
	-- themes were just visual skins and core mechanics like TimingWindows and Life scaling could only
	-- be handled by the SM engine.  Whatever the case, they're still exposed as options in the
	-- operator menu and players still play around with them, so we need to handle that here.
	--
	-- 4 (1, internally) is considered standard for ITG.
	-- GrooveStats expects players to have both these set to 4 (1, internally).
	--
	-- People can probably use some combination of LifeDifficultyScale,
	-- TimingWindowScale, and TimingWindowAdd to probably match up with ITG's windows, but that's a
	-- bit cumbersome to handle so just requre TimingWindowScale and LifeDifficultyScale these to be set
	-- to 4.
	valid[5] = PREFSMAN:GetPreference("TimingWindowScale") == 1
	valid[6] = PREFSMAN:GetPreference("LifeDifficultyScale") == 1

	-- Validate all other metrics.
	local ExpectedTWA = 0.0015
	local ExpectedWindows = {
		0.021500 + ExpectedTWA,  -- Fantastics
		0.043000 + ExpectedTWA,  -- Excellents
		0.102000 + ExpectedTWA,  -- Greats
		0.135000 + ExpectedTWA,  -- Decents
		0.180000 + ExpectedTWA,  -- Way Offs
		0.320000 + ExpectedTWA,  -- Holds
		0.070000 + ExpectedTWA,  -- Mines
		0.350000 + ExpectedTWA,  -- Rolls
	}
	local TimingWindows = { "W1", "W2", "W3", "W4", "W5", "Hold", "Mine", "Roll" }
	local ExpectedLife = {
		 0.008,  -- Fantastics
		 0.008,  -- Excellents
		 0.004,  -- Greats
		 0.000,  -- Decents
		-0.050,  -- Way Offs
		-0.100,  -- Miss
		-0.080,  -- Let Go
		 0.008,  -- Held
		-0.050,  -- Hit Mine
	}
	local ExpectedScoreWeight = {
		 5,  -- Fantastics
		 4,  -- Excellents
		 2,  -- Greats
		 0,  -- Decents
		-6,  -- Way Offs
		-12,  -- Miss
		 0,  -- Let Go
		 5,  -- Held
		-6,  -- Hit Mine
	}
	local LifeWindows = { "W1", "W2", "W3", "W4", "W5", "Miss", "LetGo", "Held", "HitMine" }

	-- Originally verify the ComboToRegainLife metrics.
	valid[7] = (PREFSMAN:GetPreference("RegenComboAfterMiss") == 5 and PREFSMAN:GetPreference("MaxRegenComboAfterMiss") == 10)

	local FloatEquals = function(a, b)
		return math.abs(a-b) < 0.0001
	end

	valid[7] = valid[7] and FloatEquals(THEME:GetMetric("LifeMeterBar", "InitialValue"), 0.5)
	valid[7] = valid[7] and PREFSMAN:GetPreference("HarshHotLifePenalty")

	-- And then verify the windows themselves.
	local TWA = PREFSMAN:GetPreference("TimingWindowAdd")
	if SL.Global.GameMode == "ITG" then
		for i, window in ipairs(TimingWindows) do
			-- Only check if the Timing Window is actually "enabled".
			if i > 5 or SL[pn].ActiveModifiers.TimingWindows[i] then
				valid[7] = valid[7] and FloatEquals(PREFSMAN:GetPreference("TimingWindowSeconds"..window) + TWA, ExpectedWindows[i])
			end
		end

		for i, window in ipairs(LifeWindows) do
			valid[7] = valid[7] and FloatEquals(THEME:GetMetric("LifeMeterBar", "LifePercentChange"..window), ExpectedLife[i])

			valid[7] = valid[7] and THEME:GetMetric("ScoreKeeperNormal", "PercentScoreWeight"..window) == ExpectedScoreWeight[i]
		end
	elseif SL.Global.GameMode == "FA+" then
		for i, window in ipairs(TimingWindows) do
			-- This handles the "offset" for the FA+ window, while also retaining the correct indices for Holds/Mines/Rolls
			-- i idx
			-- 1  * - FA+ (idx doesn't matter as we explicitly handle the i == 1 case)
			-- 2  1 - Fantastic
			-- 3  2 - Excellent
			-- 4  3 - Greats
			-- 5  4 - Decents
			-- 6  6 - Holds (notice how we skipped idx == 5, which would've been the Way Off window)
			-- 7  7 - Mines
			-- 8  8 - Rolls
			-- Only check if the Timing Window is actually "enabled".
			if i > 5 or SL[pn].ActiveModifiers.TimingWindows[i] then
				local idx = (i < 6 and i-1 or i)
				if i == 1 then
					-- For the FA+ fantastic, the first window can be anything as long as it's <= the actual fantastic window
					-- We could use FloatEquals here, but that's a 0.0001 margin of error for the equality case which I think 
					-- will be generally irrelevant.
					valid[7] = valid[7] and (PREFSMAN:GetPreference("TimingWindowSeconds"..window) + TWA <= ExpectedWindows[1])
				else
					valid[7] = valid[7] and FloatEquals(PREFSMAN:GetPreference("TimingWindowSeconds"..window) + TWA, ExpectedWindows[idx])
				end
			end
		end

		for i, window in ipairs(LifeWindows) do
			local idx = (i < 6 and i-1 or i)
			if i == 1 then
				valid[7] = valid[7] and FloatEquals(THEME:GetMetric("LifeMeterBar", "LifePercentChange"..window), ExpectedLife[1])
				valid[7] = valid[7] and THEME:GetMetric("ScoreKeeperNormal", "PercentScoreWeight"..window) == ExpectedScoreWeight[1]
			else
				valid[7] = valid[7] and FloatEquals(THEME:GetMetric("LifeMeterBar", "LifePercentChange"..window), ExpectedLife[idx])
				valid[7] = valid[7] and THEME:GetMetric("ScoreKeeperNormal", "PercentScoreWeight"..window) == ExpectedScoreWeight[idx]
			end
		end
	end

	-- Validate Rate Mod
	local rate = SL.Global.ActiveModifiers.MusicRate * 100
	valid[8] = 100 <= rate and rate <= 300


	-- ------------------------------------------
	-- Finally, check player-specific modifiers used during this song that would invalidate the score.

	-- get playeroptions so we can check mods the player used
	local po = GAMESTATE:GetPlayerState(player):GetPlayerOptions("ModsLevel_Preferred")


	-- score is invalid if notes were removed
	valid[9] = not (
		po:Little()  or po:NoHolds() or po:NoStretch()
		or po:NoHands() or po:NoJumps() or po:NoFakes()
		or po:NoLifts() or po:NoQuads() or po:NoRolls()
	)

	-- score is invalid if notes were added
	valid[10] = not (
		po:Wide() or po:Skippy() or po:Quick()
		or po:Echo() or po:BMRize() or po:Stomp()
		or po:Big()
	)

	-- only FailTypes "Immediate" and "ImmediateContinue" are valid for GrooveStats
	valid[11] = (po:FailSetting() == "FailType_Immediate" or po:FailSetting() == "FailType_ImmediateContinue")

	-- AutoPlay is not allowed
	valid[12] = not IsAutoplay(player)

	-- ------------------------------------------
	-- return the entire table so that we can let the player know which settings,
	-- if any, prevented their score from being valid for GrooveStats

	local allChecksValid = true
	for _, passed_check in ipairs(valid) do
		if not passed_check then allChecksValid = false break end
	end

	return valid, allChecksValid
end

-- -----------------------------------------------------------------------

CreateCommentString = function(player)
	local pn = ToEnumShortString(player)
	local pss = STATSMAN:GetCurStageStats():GetPlayerStageStats(player)

	local suffixes = {"w", "e", "g", "d", "wo"}

	local comment = SL.Global.GameMode == "FA+" and "FA+" or ""

	local rate = SL.Global.ActiveModifiers.MusicRate
	if rate ~= 1 then
		if #comment ~= 0 then
			comment = comment .. ", "
		end
		comment = comment..("%gx Rate"):format(rate)
	end

	-- Ignore the top window in all cases.
	for i=2, 6 do
		local idx = SL.Global.GameMode == "FA+" and i-1 or i
		local suffix = i == 6 and "m" or suffixes[idx]
		local tns = i == 6 and "TapNoteScore_Miss" or "TapNoteScore_W"..i
		
		local number = pss:GetTapNoteScores(tns)

		-- If the windows are disabled, then the number will be 0.
		if number ~= 0 then
			if #comment ~= 0 then
				comment = comment .. ", "
			end
			comment = comment..number..suffix
		end
	end

	local timingWindowOption = ""

	if SL.Global.GameMode == "ITG" then
		if not SL[pn].ActiveModifiers.TimingWindows[4] and not SL[pn].ActiveModifiers.TimingWindows[5] then
			timingWindowOption = "No Dec/WO"
		elseif not SL[pn].ActiveModifiers.TimingWindows[5] then
			timingWindowOption = "No WO"
		elseif not SL[pn].ActiveModifiers.TimingWindows[1] and not SL[pn].ActiveModifiers.TimingWindows[2] then
			timingWindowOption = "No Fan/Exc"
		end
	elseif SL.Global.GameMode == "FA+" then
		if not SL[pn].ActiveModifiers.TimingWindows[4] and not SL[pn].ActiveModifiers.TimingWindows[5] then
			timingWindowOption = "No Gre/Dec/WO"
		elseif not SL[pn].ActiveModifiers.TimingWindows[5] then
			timingWindowOption = "No Dec/WO"
		elseif not SL[pn].ActiveModifiers.TimingWindows[1] and not SL[pn].ActiveModifiers.TimingWindows[2] then
			-- Weird flex but okay
			timingWindowOption = "No Fan/WO"
		else
			-- Way Offs are always removed in FA+ mode.
			timingWindowOption = "No WO"
		end
	end

	if #timingWindowOption ~= 0 then
		if #comment ~= 0 then
			comment = comment .. ", "
		end
		comment = comment..timingWindowOption
	end

	local pn = ToEnumShortString(player)
	-- If a player CModded, then add that as well.
	if SL[pn].ActiveModifiers.SpeedModType == "C" then
		if #comment ~= 0 then
			comment = comment .. ", "
		end
		comment = comment.."C"..SL[pn].ActiveModifiers.SpeedMod
	end

	return comment
end

-- -----------------------------------------------------------------------

ParseGroovestatsDate = function(date)
	if not date or #date == 0 then return "" end

	-- Dates are formatted like:
	-- YYYY-MM-DD HH:MM:SS
	local year, month, day, hour, min, sec = date:match("([%d]+)-([%d]+)-([%d]+) ([%d]+):([%d]+):([%d]+)")
	local monthMap = {
		["01"] = "Jan",
		["02"] = "Feb",
		["03"] = "Mar",
		["04"] = "Apr",
		["05"] = "May",
		["06"] = "Jun",
		["07"] = "Jul",
		["08"] = "Aug",
		["09"] = "Sep",
		["10"] = "Oct",
		["11"] = "Nov",
		["12"] = "Dec",
	}

	return monthMap[month].." "..tonumber(day)..", "..year
end
