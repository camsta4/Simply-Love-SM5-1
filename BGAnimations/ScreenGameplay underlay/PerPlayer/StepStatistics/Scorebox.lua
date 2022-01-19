local player = ...
local pn = ToEnumShortString(player)
local n = player==PLAYER_1 and "1" or "2"
local IsUltraWide = (GetScreenAspectRatio() > 21/9)
local NoteFieldIsCentered = (GetNotefieldX(player) == _screen.cx)

local border = 5
local width = 162
local height = 80

local cur_style = 0
local num_styles = 2

local loop_seconds = 5
local transition_seconds = 1

local all_data = {}

-- Initialize the all_data object.
for i=1,num_styles do
	local data = {
		["has_data"]=false,
		["scores"]={}
	}
	local scores = data["scores"]
	for i=1,5 do
		scores[#scores+1] = {
			["rank"]="",
			["name"]="",
			["score"]="",
			["isSelf"]=false,
			["isRival"]=false,
			["isFail"]=false
		}
	end
	all_data[#all_data + 1] = data
end

-- Checks to see if any data is available.
local HasData = function(idx)
	return all_data[idx+1] and all_data[idx+1].has_data
end

local SetScoreData = function(data_idx, score_idx, rank, name, score, isSelf, isRival, isFail)
	all_data[data_idx].has_data = true

	local score_data = all_data[data_idx]["scores"][score_idx]
	score_data.rank = rank..((#rank > 0) and "." or "")
	score_data.name = name
	score_data.score = score
	score_data.isSelf = isSelf
	score_data.isRival = isRival
	score_data.isFail = isFail
end

local LeaderboardRequestProcessor = function(res, master)
	if res.error then
		local error = ToEnumShortString(res.error)
		local text = ""
		if error == "Timeout" then
			text = "Timed Out"
		elseif error ~= "Cancelled" then
			text = "Failed to Load 😞"
			SL.GrooveStats.Leaderboard = false
		end
		for i=1, 2 do
			local pn = "P"..i
			local leaderboard = master:GetChild(pn.."Leaderboard")
			for j=1, NumEntries do
				local entry = leaderboard:GetChild("LeaderboardEntry"..j)
				if j == 1 then
					SetEntryText("", text, "", "", entry)
				else
					-- Empty out the remaining rows.
					SetEntryText("", "", "", "", entry)
				end
			end
		end
		return
	end

	local playerStr = "player"..n
	local data = JsonDecode(res.body)

	-- First check to see if the leaderboard even exists.
	if data and data[playerStr] then
		-- These will get overwritten if we have any entries in the leaderboard below.
		if data[playerStr]["isRanked"] then
			SetScoreData(1, 1, "", "No Scores", "", false, false, false)
		else
			if not data[playerStr]["rpg"] or not data[playerStr]["rpg"]["rpgLeaderboard"] then
				SetScoreData(1, 1, "", "Chart Not Ranked", "", false, false, false)
			end
		end

		if data[playerStr]["gsLeaderboard"] then
			local numEntries = 0
			for entry in ivalues(data[playerStr]["gsLeaderboard"]) do
				numEntries = numEntries + 1
				SetScoreData(1, numEntries,
								tostring(entry["rank"]),
								entry["name"],
								string.format("%.2f", entry["score"]/100),
								entry["isSelf"],
								entry["isRival"],
								entry["isFail"])
			end
		end

		if data[playerStr]["rpg"] then
			local numEntries = 0
			SetScoreData(2, 1, "", "No Scores", "", false, false, false)

			if data[playerStr]["rpg"]["rpgLeaderboard"] then
				for entry in ivalues(data[playerStr]["rpg"]["rpgLeaderboard"]) do
					numEntries = numEntries + 1
					SetScoreData(2, numEntries,
									tostring(entry["rank"]),
									entry["name"],
									string.format("%.2f", entry["score"]/100),
									entry["isSelf"],
									entry["isRival"],
									entry["isFail"]
								)
				end
			end
		end
 	end
	master:queuecommand("Check")
end

local af = Def.ActorFrame{
	Name="ScoreBox"..pn,
	InitCommand=function(self)
		self:xy(70 * (player==PLAYER_1 and 1 or -1), -115)
		-- offset a bit more when NoteFieldIsCentered
		if NoteFieldIsCentered and IsUsingWideScreen() then
			self:addx( 2 * (player==PLAYER_1 and 1 or -1) )
		end

		-- ultrawide and both players joined
		if IsUltraWide and #GAMESTATE:GetHumanPlayers() > 1 then
			self:x(self:GetX() * -1)
		end
		self.isFirst = true
	end,
	CheckCommand=function(self)
		self:queuecommand("Loop")
	end,
	LoopCommand=function(self)
		if #all_data == 0 then return end

		local start = cur_style

		cur_style = (cur_style + 1) % num_styles
		while cur_style ~= start or self.isFirst do
			-- Make sure we have the next set of data.

			if HasData(cur_style) then
				-- If this is the first time we're looping, update the start variable
				-- since it may be different than the default
				if self.isFirst then
					start = cur_style
					self.isFirst = false
					-- Continue looping to figure out the next style.
				else
					break
				end
			end
			cur_style = (cur_style + 1) % num_styles
		end

		-- Loop only if there's something new to loop to.
		if start ~= cur_style then
			self:sleep(loop_seconds):queuecommand("Loop")
		end
	end,

	RequestResponseActor(0, 0)..{
		OnCommand=function(self)
			local sendRequest = false
			local headers = {}
			local query = {
				maxLeaderboardResults=5,
			}

			if SL[pn].ApiKey ~= "" then
				query["chartHashP"..n] = SL[pn].Streams.Hash
				headers["x-api-key-player-"..n] = SL[pn].ApiKey
				sendRequest = true
			end

			-- We technically will send two requests in ultrawide versus mode since
			-- both players will have their own individual scoreboxes.
			-- Should be fine though.
			if sendRequest then
				self:GetParent():GetChild("Name1"):settext("Loading...")
				self:playcommand("MakeRequest", {
					endpoint="player-leaderboards.php?"..NETWORK:EncodeQueryParameters(query),
					method="GET",
					headers=headers,
					timeout=10,
					callback=LeaderboardRequestProcessor,
					args=self:GetParent(),
				})
			end
		end
	},

	-- Outline
	Def.Quad{
		Name="Outline",
		InitCommand=function(self)
			self:diffuse(color("#007b85")):setsize(width + border, height + border)
		end,
		LoopCommand=function(self)
			if cur_style == 0 then
				self:linear(transition_seconds):diffuse(color("#007b85"))
			elseif cur_style == 1 then
				self:linear(transition_seconds):diffuse(color("#aa886b"))
			end
		end
	},
	-- Main body
	Def.Quad{
		Name="Background",
		InitCommand=function(self)
			self:diffuse(color("#000000")):setsize(width, height)
		end,
	},
	-- GrooveStats Logo
	Def.Sprite{
		Texture=THEME:GetPathG("", "GrooveStats.png"),
		Name="GrooveStatsLogo",
		InitCommand=function(self)
			self:zoom(0.8):diffusealpha(0.5)
		end,
		LoopCommand=function(self)
			if cur_style == 0 then
				self:sleep(transition_seconds/2):linear(transition_seconds/2):diffusealpha(0.5)
			elseif cur_style == 1 then
				self:linear(transition_seconds/2):diffusealpha(0)
			end
		end
	},
	-- SRPG Logo
	Def.Sprite{
		Texture=THEME:GetPathG("", "_VisualStyles/SRPG5/logo_small (doubleres).png"),
		Name="SRPG5Logo",
		InitCommand=function(self)
			self:diffusealpha(0.4):zoom(0.32):addy(3):diffusealpha(0)
		end,
		LoopCommand=function(self)
			if cur_style == 0 then
				self:sleep(transition_seconds/2):linear(transition_seconds/2):diffusealpha(0)
			elseif cur_style == 1 then
				self:linear(transition_seconds/2):diffusealpha(0.5)
			end
		end
	},

}

for i=1,5 do
	local y = -height/2 + 16 * i - 8
	local zoom = 0.87

	-- Rank 1 gets a crown.
	if i == 1 then
		af[#af+1] = Def.Sprite{
			Name="Rank"..i,
			Texture=THEME:GetPathG("", "crown.png"),
			InitCommand=function(self)
				self:zoom(0.09):xy(-width/2 + 14, y):diffusealpha(0)
			end,
			LoopCommand=function(self)
				self:linear(transition_seconds/2):diffusealpha(0):queuecommand("Set")
			end,
			SetCommand=function(self)
				local score = all_data[cur_style+1]["scores"][i]
				if score.rank ~= "" then
					self:linear(transition_seconds/2):diffusealpha(1)
				end
			end
		}
	else
		af[#af+1] = LoadFont("Common Normal")..{
			Name="Rank"..i,
			Text="",
			InitCommand=function(self)
				self:diffuse(Color.White):xy(-width/2 + 27, y):maxwidth(30):horizalign(right):zoom(zoom)
			end,
			LoopCommand=function(self)
				self:linear(transition_seconds/2):diffusealpha(0):queuecommand("Set")
			end,
			SetCommand=function(self)
				local score = all_data[cur_style+1]["scores"][i]
				local clr = Color.White
				if score.isSelf then
					clr = color("#a1ff94")
				elseif score.isRival then
					clr = color("#c29cff")
				end
				self:settext(score.rank)
				self:linear(transition_seconds/2):diffusealpha(1):diffuse(clr)
			end
		}
	end

	af[#af+1] = LoadFont("Common Normal")..{
		Name="Name"..i,
		Text="",
		InitCommand=function(self)
			self:diffuse(Color.White):xy(-width/2 + 30, y):maxwidth(100):horizalign(left):zoom(zoom)
		end,
		LoopCommand=function(self)
			self:linear(transition_seconds/2):diffusealpha(0):queuecommand("Set")
		end,
		SetCommand=function(self)
			local score = all_data[cur_style+1]["scores"][i]
			local clr = Color.White
			if score.isSelf then
				clr = color("#a1ff94")
			elseif score.isRival then
				clr = color("#c29cff")
			end
			self:settext(score.name)
			self:linear(transition_seconds/2):diffusealpha(1):diffuse(clr)
		end
	}

	af[#af+1] = LoadFont("Common Normal")..{
		Name="Score"..i,
		Text="",
		InitCommand=function(self)
			self:diffuse(Color.White):xy(-width/2 + 160, y):horizalign(right):zoom(zoom)
		end,
		LoopCommand=function(self)
			self:linear(transition_seconds/2):diffusealpha(0):queuecommand("Set")
		end,
		SetCommand=function(self)
			local score = all_data[cur_style+1]["scores"][i]
			local clr = Color.White
			if score.isFail then
				clr = Color.Red
			elseif score.isSelf then
				clr = color("#a1ff94")
			elseif score.isRival then
				clr = color("#c29cff")
			end
			self:settext(score.score)
			self:linear(transition_seconds/2):diffusealpha(1):diffuse(clr)
		end
	}
end
return af
