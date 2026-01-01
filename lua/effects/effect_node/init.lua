local ignoreDepth = CreateClientConVar("cl_nodegraph_tool_ignorez",0,true)
local fullBright = CreateClientConVar("cl_nodegraph_tool_fullbright",1,true)
local plainNodes = CreateClientConVar("cl_nodegraph_tool_plain_nodes",0,true)

local nodeTypeColors = {
	[2] = {255, 255, 0},
	[3] = {255, 255, 0},
	[4] = {24, 189, 157},
	[5] = {224, 128, 8},
	[6] = {224, 128, 8},
	[7] = {255, 255, 255}
}
local debugWhiteMat = Material("models/debug/debugwhite")
local redColor = Color(255,0,0,255)
local whiteColor = Color(255,255,255,255)

function EFFECT:Init(data)
	local type = data:GetMagnitude() || 2
	self.EffectName = "effect_node"
	self:SetType(type)
end

local nodeTypes = {
	-- Normal types
	[2] = "models/editor/ground_node.mdl",
	[3] = "models/editor/air_node.mdl",
	[4] = "models/editor/climb_node.mdl",

	-- Hint types
	[5] = "models/editor/ground_node_hint.mdl",
	[6] = "models/editor/air_node_hint.mdl",
	[7] = "models/editor/node_hint.mdl"
}

function EFFECT:SetType(type)
	self.m_type = type
	self:SetModel(nodeTypes[type] || nodeTypes[2])
end

function EFFECT:GetType() return self.m_type end

function EFFECT:SetNode(node,nodeID) self.m_node = node; self.m_nodeID = nodeID end

function EFFECT:GetNode() return self.m_node,self.m_nodeID end

function EFFECT:OnRemove()
end

function EFFECT:Think()
	local node = self:GetNode()
	if(node) then self:SetPos(node.pos) end
	return !self.m_bRemove
end

function EFFECT:Render()
	local plain = plainNodes:GetBool()
	local bright = fullBright:GetBool()
	local ignoreZ = ignoreDepth:GetBool()
	local nodeType = self:GetType() or 2

	if ignoreZ then cam.IgnoreZ(true) end
	if self.DrawLinks then self:DrawLinks() end
	if bright then render.SuppressEngineLighting(true) end

	if not self.DrawMassRem then
		local curColor = self:GetColor()
		local isSelected = curColor.r == 255 and curColor.g == 0 and curColor.b == 0 and curColor.a == 255
		if plain then
			local col = nodeTypeColors[nodeType] or {255,255,255}
			if isSelected then
				if curColor.r ~= 255 or curColor.g ~= 0 or curColor.b ~= 0 then
					self:SetColor(redColor)
				end
			else
				if curColor.r ~= col[1] or curColor.g ~= col[2] or curColor.b ~= col[3] then
					self:SetColor(Color(col[1], col[2], col[3], 255))
				end
			end
			render.MaterialOverride(debugWhiteMat)
		elseif not isSelected then
			if curColor.r ~= 255 or curColor.g ~= 255 or curColor.b ~= 255 or curColor.a ~= 255 then
				self:SetColor(whiteColor)
			end
		end

		self:DrawModel()

		if plain then
			render.MaterialOverride(nil)
		end
	end

	if bright then render.SuppressEngineLighting(false) end
	if ignoreZ then cam.IgnoreZ(false) end
	if self.DrawMassRem then self:DrawMassRem() end
end

function EFFECT:ClearLinks() self.m_tbLinks = {} end

function EFFECT:AddLink(node) table.insert(self.m_tbLinks,node) end