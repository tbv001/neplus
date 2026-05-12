local nodeTypes = {
	[1] = "models/editor/ground_node.mdl",
	[2] = "models/editor/air_node.mdl",
	[3] = "models/editor/climb_node.mdl",
	[4] = "models/editor/ground_node_hint.mdl",
	[5] = "models/editor/air_node_hint.mdl",
	[6] = "models/editor/node_hint.mdl",
}

local cl_node_type = CreateClientConVar("neplus_node_type", "1", false, false,
	"Selects the node type for neplus_effect (1-6)", 1, 6)

function EFFECT:Init(data)
	local typeIndex = data:GetMagnitude()
	if typeIndex == 0 then
		typeIndex = cl_node_type:GetInt()
	end

	local model = nodeTypes[typeIndex] or nodeTypes[2]
	self:SetModel(model)

	self.shouldRender = true
	self.highlight = false
	self.nodePos = data:GetOrigin()
end

function EFFECT:Think()
	return self.shouldRender
end

function EFFECT:Render()
	render.SuppressEngineLighting(true)
	if self.highlight then
		render.SetColorModulation(1, 0, 0)
	end
	self:SetPos(self.nodePos)
	self:DrawModel()
	render.SetColorModulation(1, 1, 1)
	render.SuppressEngineLighting(false)
end

concommand.Add("neplus_test_effect", function(ply, cmd, args)
	if not IsValid(ply) then
		return
	end

	local trace = ply:GetEyeTrace()
	local effectData = EffectData()
	effectData:SetOrigin(trace.HitPos)
	effectData:SetMagnitude(cl_node_type:GetInt())
	util.Effect("neplus_effect", effectData)
end)
