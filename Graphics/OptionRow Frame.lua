local t = Def.ActorFrame{};

-- a row
t[#t+1] = Def.Quad {
	OnCommand=cmd(zoomto,SCREEN_WIDTH*0.85,SCREEN_HEIGHT*0.0625;);
};

-- black quad behind the title
t[#t+1] = Def.Quad {
	OnCommand=cmd(x, -SCREEN_CENTER_X/1.4275; zoomto,SCREEN_WIDTH*WideScale(0.22,0.15),SCREEN_HEIGHT*0.0625; diffuse, Color.Black; diffusealpha,0.25);
};

return t;