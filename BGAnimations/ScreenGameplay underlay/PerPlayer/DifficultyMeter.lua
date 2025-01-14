local player = ...

local _x = _screen.cx + (player==PLAYER_1 and -1 or 1) * SL_WideScale(292.5, 342.5)
local _y = 56

if SL.Global.GameMode=="DDR" then
	_x = 25
	_y = _screen.h - 47
end

return Def.ActorFrame{
	InitCommand=function(self)
		self:xy(_x, _y)
	end,


	-- colored background for player's chart's difficulty meter
	Def.Quad{
		InitCommand=function(self)
			self:zoomto(30, 30)
		end,
		OnCommand=function(self)
			local currentSteps = GAMESTATE:GetCurrentSteps(player)
			if currentSteps then
				local currentDifficulty = currentSteps:GetDifficulty()
				self:diffuse(DifficultyColor(currentDifficulty))
			end
		end
	},

	-- player's chart's difficulty meter
	LoadFont("Common Bold")..{
		InitCommand=function(self)
			self:diffuse( Color.Black )
			self:zoom( 0.4 )
		end,
		CurrentSongChangedMessageCommand=function(self) self:queuecommand("Begin") end,
		BeginCommand=function(self)
			local steps = GAMESTATE:GetCurrentSteps(player)
			local meter = steps:GetMeter()

			if meter then
				self:settext(meter)
			end
		end
	}
}