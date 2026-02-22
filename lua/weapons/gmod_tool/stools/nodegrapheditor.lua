local NODE_TYPE_GROUND = 2
local NODE_TYPE_AIR = 3
local NODE_TYPE_CLIMB = 4
local NODE_TYPE_WATER = 5
local NODE_TYPE_HINT = 7
local AI_NODE_ZONE_UNKNOWN = 0
local AI_NODE_ZONE_SOLO = 1
local AI_NODE_ZONE_UNIVERSAL = 3
local AI_NODE_FIRST_ZONE = 4
local MAX_NODES = 8192

local Grid = {}
Grid.__index = Grid
local floor = math.floor

function Grid:New(cellSize)
    local grid = setmetatable({}, Grid)
    grid.cellSize = cellSize or 1024
    grid.invCellSize = 1 / grid.cellSize
    grid.cells = {}
    return grid
end

function Grid:GetCellCoords(pos)
    local s = self.invCellSize
    return floor(pos.x * s), floor(pos.y * s), floor(pos.z * s)
end

function Grid:_ensureCell3D(x, y, z)
    local cx = self.cells[x]
    if cx == nil then
        cx = {}
        self.cells[x] = cx
    end
    local cy = cx[y]
    if cy == nil then
        cy = {}
        cx[y] = cy
    end
    local cz = cy[z]
    if cz == nil then
        cz = {}
        cy[z] = cz
    end
    return cz, cy, cx
end

function Grid:Insert(nodeID, node)
    if not node then return end
    local pos = node.pos
    if not pos then return end

    local x, y, z = self:GetCellCoords(pos)
    local cz = self:_ensureCell3D(x, y, z)
    cz[nodeID] = true

    node.cx, node.cy, node.cz = x, y, z
end

function Grid:Remove(nodeID, node)
    if not node then return end
    local x, y, z = node.cx, node.cy, node.cz
    if x == nil then
        node.cx, node.cy, node.cz = nil, nil, nil
        return
    end

    local cells = self.cells
    local cx = cells[x]
    if not cx then
        node.cx, node.cy, node.cz = nil, nil, nil
        return
    end
    local cy = cx[y]
    if not cy then
        node.cx, node.cy, node.cz = nil, nil, nil
        return
    end
    local cz = cy[z]
    if cz then
        cz[nodeID] = nil
        if next(cz) == nil then
            cy[z] = nil
            if next(cy) == nil then
                cx[y] = nil
                if next(cx) == nil then
                    cells[x] = nil
                end
            end
        end
    end

    node.cx, node.cy, node.cz = nil, nil, nil
end

function Grid:Query(pos, radius, nodes)
	if not pos or not radius or radius <= 0 or not nodes then return {} end
    local result = {}

    local radiusSqr = radius * radius
    local invSize = self.invCellSize

    local minX = floor((pos.x - radius) * invSize)
    local minY = floor((pos.y - radius) * invSize)
    local minZ = floor((pos.z - radius) * invSize)

    local maxX = floor((pos.x + radius) * invSize)
    local maxY = floor((pos.y + radius) * invSize)
    local maxZ = floor((pos.z + radius) * invSize)

    local cells = self.cells
    local pX, pY, pZ = pos.x, pos.y, pos.z

    for x = minX, maxX do
        local cx = cells[x]
        if cx then
            for y = minY, maxY do
                local cy = cx[y]
                if cy then
                    for z = minZ, maxZ do
                        local cz = cy[z]
                        if cz then
                            for nodeID in pairs(cz) do
                                local n = nodes[nodeID]
                                if n then
                                    local np = n.pos
                                    if np then
                                        local dx = np.x - pX
                                        local dy = np.y - pY
                                        local dz = np.z - pZ
                                        if (dx*dx + dy*dy + dz*dz) <= radiusSqr then
                                            result[nodeID] = n
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return result
end

function Grid:Build(nodes)
	if not nodes then return end
    self:Clear()
    for id, node in pairs(nodes) do
        self:Insert(id, node)
    end
end

function Grid:Clear()
    self.cells = {}
end

if SERVER then
	util.AddNetworkString("nodegraph_gen_server")
	util.AddNetworkString("nodegraph_gen_client")
	util.AddNetworkString("nodegraph_cleareffects_client")
	util.AddNetworkString("nodegraph_get_hint_server")
	util.AddNetworkString("nodegraph_get_hint_client")
	util.AddNetworkString("nodegraph_getmapversion_server")
	util.AddNetworkString("nodegraph_getmapversion_client")

	local hintData = {}
	hook.Add("EntityKeyValue", "NEPlusGetAllNodeHints", function(ent, key, value)
		local cls = ent:GetClass()
		if cls ~= "info_hint" and cls ~= "info_node_hint" and cls ~= "info_node_air_hint" then return end
	
		ent._hint = ent._hint or {ID = (cls == "info_hint" and ent:EntIndex() or nil)}
	
		if key == "nodeid" then
			ent._hint.ID = tostring(value)
		elseif key == "origin" then
			ent._hint.Position = value
		elseif key == "hinttype" then
			ent._hint.HintType = value
		end
	
		if ent._hint.ID and ent._hint.Position and ent._hint.HintType then
			table.insert(hintData, {
				NodeID     = ent._hint.ID,
				Position   = ent._hint.Position,
				HintType   = ent._hint.HintType,
				IsInfoHint = (cls == "info_hint")
			})
			ent._hint = nil
		end
	end)

	hook.Add("PlayerDeath", "NEPlusPlayerDeath", function(ply, infl, att)
		net.Start("nodegraph_cleareffects_client")
		net.Send(ply)
	end)

	local function getAllNavAreas(genSettings, ply)
		local eligibleNavAreas = {}
		local eligibleNavAreaIds = {}
		local minimalAreaSize = genSettings.NavAreaSize
		local crouchEnabled = genSettings.CrouchAreas
		local jumpEnabled = genSettings.JumpAreas
		local waterEnabled = genSettings.WaterAreas
		local jumpLinksEnabled = genSettings.GenJumpLinks
	
		local function isAreaEligible(navArea)
			if navArea:HasAttributes(NAV_MESH_INVALID) or navArea:IsBlocked() then
				return false
			end

			if not crouchEnabled then
				if navArea:HasAttributes(NAV_MESH_CROUCH) then
					return false
				end
			end

			if not jumpEnabled then
				if navArea:HasAttributes(NAV_MESH_JUMP) then
					return false
				end
			end
	
			if not waterEnabled and navArea:IsUnderwater() then
				return false
			end
	
			local areaSize = navArea:GetSizeX() * navArea:GetSizeY()
			if areaSize < minimalAreaSize then
				return false
			end
	
			return true
		end
	
		local allNavAreas = navmesh.GetAllNavAreas()
		for i = 1, #allNavAreas do
			local navArea = allNavAreas[i]
			if isAreaEligible(navArea) then
				local areaData = {
					id = navArea:GetID(),
					pos = navArea:GetCenter(),
					adjacents = {},
					jumps = {}
				}
				
				table.insert(eligibleNavAreas, areaData)
				eligibleNavAreaIds[navArea:GetID()] = true
			end
		end
	
		for i = 1, #eligibleNavAreas do
			local areaData = eligibleNavAreas[i]
			local navArea = navmesh.GetNavAreaByID(areaData.id)
			if not navArea then continue end
	
			for _, adjacentArea in pairs(navArea:GetAdjacentAreas()) do
				local adjacentId = adjacentArea:GetID()
				
				if eligibleNavAreaIds[adjacentId] then
					local heightChange = math.abs(navArea:ComputeAdjacentConnectionHeightChange(adjacentArea))
					
					if heightChange <= 18 then
						table.insert(areaData.adjacents, adjacentId)
					else
						if jumpLinksEnabled then
							table.insert(areaData.jumps, adjacentId)
						end
					end
				end
			end
		end
	
		local finalAreas = {}
		local usedAreaIds = {}
		local remainingAreas = {}

		for i = 1, #eligibleNavAreas do
			local areaData = eligibleNavAreas[i]
			if #areaData.adjacents > 0 or (jumpLinksEnabled and #areaData.jumps > 0) then
				if #finalAreas < MAX_NODES then
					table.insert(finalAreas, areaData)
					usedAreaIds[areaData.id] = true
				else
					table.insert(remainingAreas, areaData)
				end
			end
		end
		
		local finalAreasChanged = true
		while finalAreasChanged and #remainingAreas > 0 do
			finalAreasChanged = false
			
			for i = #finalAreas, 1, -1 do
				local areaData = finalAreas[i]
				local connectedAdjacents = 0
				local connectedJumps = 0
				
				for j = 1, #areaData.adjacents do
					local adjId = areaData.adjacents[j]
					if usedAreaIds[adjId] then
						connectedAdjacents = connectedAdjacents + 1
					end
				end
				
				if jumpLinksEnabled then
					for j = 1, #areaData.jumps do
						local jumpId = areaData.jumps[j]
						if usedAreaIds[jumpId] then
							connectedJumps = connectedJumps + 1
						end
					end
				end
				
				if connectedAdjacents == 0 and (not jumpLinksEnabled or connectedJumps == 0) then
					for j = 1, #remainingAreas do
						local remainingArea = remainingAreas[j]
						local replacementConnectedAdjacents = 0
						local replacementConnectedJumps = 0
						
						for k = 1, #remainingArea.adjacents do
							local adjId = remainingArea.adjacents[k]
							if usedAreaIds[adjId] then
								replacementConnectedAdjacents = replacementConnectedAdjacents + 1
							end
						end
						
						if jumpLinksEnabled then
							for k = 1, #remainingArea.jumps do
								local jumpId = remainingArea.jumps[k]
								if usedAreaIds[jumpId] then
									replacementConnectedJumps = replacementConnectedJumps + 1
								end
							end
						end
						
						if replacementConnectedAdjacents > 0 or (jumpLinksEnabled and replacementConnectedJumps > 0) then
							usedAreaIds[areaData.id] = nil
							table.remove(finalAreas, i)
							
							table.insert(finalAreas, remainingArea)
							usedAreaIds[remainingArea.id] = true
							
							table.remove(remainingAreas, j)
							
							finalAreasChanged = true
							break
						end
					end
					
					if not finalAreasChanged then
						usedAreaIds[areaData.id] = nil
						table.remove(finalAreas, i)
						finalAreasChanged = true
					end
				end
			end
		end
	
		return finalAreas
	end

	local chunkSize = 60000
    net.Receive("nodegraph_gen_server", function(length, player)
		local plyEntity = net.ReadEntity()
        if not IsValid(plyEntity) then return end

		local genSettings = net.ReadTable()
		if not genSettings then return end
		
		local posTable = getAllNavAreas(genSettings, plyEntity) or {}
		local json = util.TableToJSON(posTable)
		local compressed = util.Compress(json)
		
		-- Sending data in chunks due to limited amount of data we can send.
		local totalChunks = math.ceil(#compressed / chunkSize)
		for i = 1, totalChunks do
			local startPos = (i-1) * chunkSize + 1
			local endPos = math.min(i * chunkSize, #compressed)
			local chunkData = string.sub(compressed, startPos, endPos)
			
			timer.Simple(i * 0.1, function()
				if not IsValid(plyEntity) then return end
				
				net.Start("nodegraph_gen_client")
				net.WriteUInt(totalChunks, 16)
				net.WriteUInt(i, 16)
				net.WriteUInt(#compressed, 32)
				net.WriteUInt(#chunkData, 32)
				net.WriteData(chunkData, #chunkData)
				net.Send(plyEntity)
			end)
		end
	end)

    net.Receive("nodegraph_get_hint_server", function(length, player)
		local plyEntity = net.ReadEntity()
        if not IsValid(plyEntity) then return end

		-- Compress just in case the data is too large to be sent.
		local compressedHintData = util.Compress(util.TableToJSON(hintData, false))
		net.Start("nodegraph_get_hint_client")
		net.WriteData(compressedHintData)
		net.Send(plyEntity)
	end)

    net.Receive("nodegraph_getmapversion_server", function(length, player)
		local plyEntity = net.ReadEntity()
        if not IsValid(plyEntity) then return end

		local mapVersion = game.GetMapVersion()
		net.Start("nodegraph_getmapversion_client")
		net.WriteUInt(mapVersion, 32)
		net.Send(plyEntity)
	end)
end

function nodegraph_get_map_nodeable()
	local path = "maps/graphs/" .. game.GetMap() .. ".ain"
	if file.Exists(path, "BSP") then
		return false
	end
	return true
end

function nodegraph_test_recreate_node()
	local path2 = "maps/graphs/"..game.GetMap()..".ain"
	local F2 = file.Open(path2, "rb", "GAME")
	local version1 = 0
	local size1 = 0
	if F2 then
		F2:ReadLong()
		version1 = F2:ReadLong()
		size1 = F2:ReadLong()
		F2:Close()		
	else
		return false
	end
	
	local version2 = 0
	local size2 = 0
	path2 = "nodegraph/"..game.GetMap()..".txt"
	F2 = file.Open(path2, "rb", "DATA")
	if F2 then
		F2:ReadLong()
		version2 = F2:ReadLong()
		size2 = F2:ReadLong()
		F2:Close()		
	else
		return false
	end
	return version1~=version2 or size1 ~= size2
end

function nodegraph_create_nodeable_map()
	local bspPath = "maps/" .. game.GetMap() .. ".bsp"
	local inFile = file.Open(bspPath, "rb", "GAME")
	if not inFile then
		return false
	end
	
	if not file.IsDir("nodegraph", "DATA") then
		file.CreateDir("nodegraph")
	end

	local savePath = "nodegraph/" .. game.GetMap() .. ".bsp"
	local outFile = file.Open(savePath .. ".dat", "wb", "DATA")
	if not outFile then
		inFile:Close()
		return false
	end
	
	local searchStr = game.GetMap() .. ".ain"
	local replaceStr = game.GetMap() .. ".aix"
	local searchLen  = #searchStr
	local chunkSize  = 1024 * 64 -- 64 KB
	local buffer = ""
	local iterations = 0

	-- Read the BSP in chunks and replace any buffer data that matches the search string.
	while (not inFile:EndOfFile()) do
		local chunk = inFile:Read(chunkSize)
		if not chunk or chunk == "" then break end

		local data = buffer .. chunk
		local writeLen = #data - (searchLen - 1)
		if writeLen > 0 then
			local toWrite = string.sub(data, 1, writeLen)
			toWrite = string.Replace(toWrite, searchStr, replaceStr)
			outFile:Write(toWrite)
			buffer = string.sub(data, writeLen + 1)
		else
			buffer = data
		end
		iterations = iterations + 1
		-- Free up the memory after 10 iterations.
		if iterations % 10 == 0 then
			collectgarbage("step")
		end
	end

	-- Write any remaining buffer data.
	if #buffer > 0 then
		outFile:Write(string.Replace(buffer, searchStr, replaceStr))
	end

	inFile:Close()
	outFile:Close()
	return true
end

function sv_opendoor(a)
	local x = ents.FindByClass(a)
	for k,v in pairs(x) do
		v:Fire("open")
	end
end

function sv_breakbrush()

	if game.GetMap()=="pl_thundermountain" then
	else	

	local x = ents.FindByClass("func_brush")
	for k,v in pairs(x) do
		v:Fire("break")
		v:Fire("disable")
		if string.find(v:GetName(),"door") then
			v:Remove()
		end
	end
	end
	RunConsoleCommand("ent_remove_all", "func_door")
	RunConsoleCommand("ent_remove_all", "func_door_rotating")
	RunConsoleCommand("ent_remove_all", "prop_door")
	RunConsoleCommand("ent_remove_all", "prop_door_rotating")
	RunConsoleCommand("ent_remove_all", "func_breakable")
	if game.GetMap()=="pl_millstone_event" then 
		RunConsoleCommand("ent_remove_all", "func_brush")
	end
	
	local x = ents.FindByClass("prop_dynamic")
	for k,v in pairs(x) do
		local nm = v:GetName()
		if string.find(nm,"door") or string.find(nm,"barrier") or nm=="cap2_signs_back_props" then
			v:Remove()
		end
	end
end

function sv_testdoor()
	sv_opendoor("func_door")
	sv_opendoor("func_door_rotating")
	sv_opendoor("prop_door")
	sv_opendoor("prop_door_rotating")
	timer.Simple( 2, function() sv_breakbrush() end )
end

function cl_testdoor()
    if(CLIENT) then
        net.Start("clear_door_call")
        net.SendToServer()
    end
end

if(SERVER) then
    util.AddNetworkString("clear_door_call")
    net.Receive("clear_door_call",
        function(len, ply)
            if not IsValid(ply) then return end
			if not ply:IsAdmin() then return end
            sv_testdoor()
        end)
end

function IsNodeBetween(a_pos, b_pos, c_pos, threshold)
    local ax, ay, az = a_pos.x, a_pos.y, a_pos.z
    local bx, by, bz = b_pos.x, b_pos.y, b_pos.z
    local cx, cy, cz = c_pos.x, c_pos.y, c_pos.z

    local acx = cx - ax
    local acy = cy - ay
	local acz = cz - az

    local ac_len_sqr = acx * acx + acy * acy + acz * acz
    if ac_len_sqr == 0 then
        return false
    end

    local abx = bx - ax
    local aby = by - ay
	local abz = bz - az

    local t = (abx * acx + aby * acy + abz * acz) / ac_len_sqr
    if t < 0 or t > 1 then
        return false
    end

    local px = ax + t * acx
    local py = ay + t * acy
	local pz = az + t * acz

    local dx = bx - px
    local dy = by - py
	local dz = bz - pz

    local dist_sqr = dx * dx + dy * dy + dz * dz

	-- Assuming threshold is already squared.
    return dist_sqr <= threshold
end

function CalculateYaw(startPos, endPos)
    local direction = endPos - startPos
    local yawRadians = math.atan2(direction.y, direction.x)
    local yawDegrees = math.deg(yawRadians)
    yawDegrees = yawDegrees % 360
    return yawDegrees
end

TOOL.Category = "Map"
TOOL.Name = "Nodegraph Editor+"

if(CLIENT) then
	local cl_tool_object = nil
	local nodeGrid

	TOOL.Information = {
		{ name = "left" },
		{ name = "right" },
		{ name = "radiusrem", icon = "gui/lmb.png", icon2 = "gui/r.png" },
		{ name = "editlink", icon = "gui/lmb.png", icon2 = "gui/e.png" },
		{ name = "assignhint", icon = "gui/rmb.png", icon2 = "gui/e.png" },
		{ name = "info_scrollmassrem" }
	}

	language.Add("tool.nodegrapheditor.name","Nodegraph Editor+")
	language.Add("tool.nodegrapheditor.desc","A comprehensive tool to modify a map's nodegraph")
	language.Add("tool.nodegrapheditor.left","Place/remove a node at your crosshair")
	language.Add("tool.nodegrapheditor.right","Place a node at your position")
	language.Add("tool.nodegrapheditor.radiusrem","Remove nodes in radius")
	language.Add("tool.nodegrapheditor.editlink","Link editing mode for selected node")
	language.Add("tool.nodegrapheditor.assignhint","Assign hint to selected node")
	language.Add("tool.nodegrapheditor.info_scrollmassrem","Scroll while holding reload key to change mass remove radius")

	if(game.SinglePlayer()) then
		net.Receive("wrench_t_call",
			function(len)
			local tool = net.ReadString()
			local fc = net.ReadUInt(5)
			
			if(fc == 2) then 
				if cl_tool_object and cl_tool_object:IsValid() then
				cl_tool_object:Holster()
				return
				end
			end
			
			local wep = LocalPlayer():GetActiveWeapon()
			if(!wep:IsValid() || wep:GetClass() != "gmod_tool" || wep:GetMode() != tool) then return end
			local tool = wep:GetToolObject()
			local args = {}
			if(fc <= 1) then
				local StartPos = Vector(net.ReadDouble(),net.ReadDouble(),net.ReadDouble())
				local HitPos = Vector(net.ReadDouble(),net.ReadDouble(),net.ReadDouble())
				args[1] = {
					StartPos = StartPos,
					HitPos = HitPos,
					Normal = (HitPos -StartPos):GetNormal()
				}
			end
			if(fc == 0) then fc = "LeftClick"
			elseif(fc == 1) then fc = "RightClick"
			elseif(fc == 2) then fc = "Holster"
			elseif(fc == 3) then fc = "ScreenClick"
			elseif(fc == 4) then fc = "Deploy" end
			tool[fc](tool,unpack(args))
		end)
	end
else
	if(game.SinglePlayer()) then util.AddNetworkString("wrench_t_call") end
	AddCSLuaFile("effects/effect_node/init.lua") // TODO: Remove this once garry fixes includes
	if(game.SinglePlayer()) then // Most TOOL functions don't get called on the client in game.SinglePlayer, so we'll do it ourselves.
		function TOOL:CallOnClient(...)
			local fc = ...
			net.Start("wrench_t_call")
				net.WriteString(self:GetMode())
				net.WriteUInt(fc,5)
				if(fc <= 1) then
					local tr = select(2,...)
					for i = 1,3 do net.WriteDouble(tr.StartPos[i]) end
					for i = 1,3 do net.WriteDouble(tr.HitPos[i]) end
				end
			net.Send(self:GetOwner())
		end
	end
end

local _R = debug.getregistry()
if(CLIENT) then
	language.Add("undone_node","Undone Node")
	local function GetTool()
		local wep = LocalPlayer():GetActiveWeapon()
		if(!wep:IsValid() || wep:GetClass() != "gmod_tool" || wep:GetMode() != "nodegrapheditor") then return end
		return wep:GetToolObject()
	end
	local cvNotificationSave = CreateClientConVar("~cl_nodegraph_tool_notification_save",0,true)
	local function ShowFirstTimeNotification()
		local bNotification = cvNotificationSave:GetInt() == 2
		local w
		local pnl
		if(!bNotification) then
			RunConsoleCommand("~cl_nodegraph_tool_notification_save","2")
			w = 500
			pnl = vgui.Create("DFrame")
			pnl:SetTitle("Nodegraph Editor+ - First Time Notification")
			pnl:SizeToContents()
			pnl:MakePopup()
		end

		local y = 40
		local function AddLine(line)
			MsgN(line)
			if(bNotification) then return end
			local l = vgui.Create("DLabel",pnl)
			l:SetText(line)
			l:SetPos(20,y)
			l:SizeToContents()
			
			y = y +l:GetTall()
		end
		AddLine("This message will only show up once, it will only be printed in the console in the future!")
		AddLine("The nodegraph has been saved as '" .. game.GetMap() .. ".txt' in 'garrysmod/data/nodegraph/'.")
		AddLine("Due to limitations regarding file writing in lua, you will have to rename it to '" .. game.GetMap() .. ".ain'")
		AddLine("and move it to 'garrysmod/maps/graphs/' yourself. If this directory doesn't exist, create it. This")
		AddLine("needs to be done every time you change the nodegraph.")
		AddLine("Make sure to change the file extension by renaming the file. Opening it in a text-editor and saving")
		AddLine("it as '" .. game.GetMap() .. ".ain' will corrupt the nodegraph!")
		AddLine("")
		AddLine("Once you have done this, the game will use the new nodegraph the next time you load the map.")
		AddLine("You can use the modified nodegraph on any server, this addon isn't required for it to work.")
		if(bNotification) then return end
		local h = y +60
		local x,yPnl = ScrW() *0.5 -w *0.5,ScrH() *0.5 -h *0.5
		pnl:SetSize(w,h)
		pnl:SetPos(x,yPnl)

		local p = vgui.Create("DButton",pnl)
		p:SetText("OK")
		p.DoClick = function() pnl:Close() end
		p:SetPos(w *0.5 -p:GetWide() *0.5,y +20)
	end
	local bWarned
	local function ShowMapWarning()
		if(bWarned) then return end
		bWarned = true
		
		if nodegraph_test_recreate_node() then
			notification.AddLegacy("You can reload the .txt nodegraph in the tool menu to update it.",0,8)
			notification.AddLegacy("The nodegraph file in 'data/nodegraph/' differs from the map's nodegraph.",1,8)
		end
		
		if(nodegraph_get_map_nodeable()) then return end
		local w = 500
		local pnl = vgui.Create("DFrame")
		pnl:SetTitle("Nodegraph Editor+ - Map is Unnodeable")
		pnl:SizeToContents()
		pnl:MakePopup()

		local y = 40
		local function AddLine(line)
			local l = vgui.Create("DLabel",pnl)
			l:SetText(line)
			l:SetPos(20,y)
			l:SizeToContents()
			
			y = y +l:GetTall()
		end
		AddLine("This map is not currently nodeable because an .ain file is packed inside the BSP.")
		AddLine("To make changes to the nodegraph, you need to create a nodeable version of the map first.")
		AddLine("You can make the map nodeable using the 'Create Nodeable Map' feature in the tool menu.")
		local h = y +60
		local x,yPnl = ScrW() *0.5 -w *0.5,ScrH() *0.5 -h *0.5
		pnl:SetSize(w,h)
		pnl:SetPos(x,yPnl)

		local p = vgui.Create("DButton",pnl)
		p:SetText("OK")
		p.DoClick = function() pnl:Close() end
		p:SetPos(w *0.5 -p:GetWide() *0.5,y +20)
	end
	local cvDist = CreateClientConVar("cl_nodegraph_tool_draw_distance",1500,true)
	local cvDistAirNode = CreateClientConVar("cl_nodegraph_tool_airnode_distance",250,true)
	local cvDistHintNode = CreateClientConVar("cl_nodegraph_tool_hintnode_distance",250,true)
	local cvH = CreateClientConVar("cl_nodegraph_tool_node_z",16,true)
	local cvAirNodeHeightOffset = CreateClientConVar("cl_nodegraph_tool_node_air_z",64,false)
	local cvAirNodeHeightOffsetEnable = CreateClientConVar("cl_nodegraph_tool_node_air_z_enable",0,true)
	local cvHGrndNodeGen = CreateClientConVar("cl_nodegraph_tool_gen_ground_node_z",16,false)
	local cvDZ = CreateClientConVar("cl_nodegraph_tool_node_dz",18,false)
	local cvDX = CreateClientConVar("cl_nodegraph_tool_node_dx",20,false)
	local cvHint = CreateClientConVar("cl_nodegraph_tool_node_hint",0,false)
	local cvDistLink = CreateClientConVar("cl_nodegraph_tool_max_link_distance",720,true)
	local cvDistLinkGrndNodeGen = CreateClientConVar("cl_nodegraph_tool_gen_ground_link_distance",720,false)
	local cvDistLinkAirNodeGen = CreateClientConVar("cl_nodegraph_tool_gen_air_link_distance",720,false)
	local cvDistLinkJmpLinkGen = CreateClientConVar("cl_nodegraph_tool_gen_jump_link_distance",720,false)
	local cvDrawGround = CreateClientConVar("cl_nodegraph_tool_nodes_draw_ground",1,true)
	local cvDrawAir = CreateClientConVar("cl_nodegraph_tool_nodes_draw_air",1,true)
	local cvDrawClimb = CreateClientConVar("cl_nodegraph_tool_nodes_draw_climb",1,true)
	local cvDrawHint = CreateClientConVar("cl_nodegraph_tool_nodes_draw_hint",1,true)
	local cvRenderUsingPlayerPos = CreateClientConVar("cl_nodegraph_tool_render_using_player_pos",0,true)
	local cvCreateType = CreateClientConVar("cl_nodegraph_tool_node_type",NODE_TYPE_GROUND,false)
	local cvVis = CreateClientConVar("cl_nodegraph_tool_check_visibility",1,true)
	local cvDrawPreview = CreateClientConVar("cl_nodegraph_tool_draw_preview",1,true)
	local cvSnap = CreateClientConVar("cl_nodegraph_tool_snap",0,true)
	local cvYaw = CreateClientConVar("cl_nodegraph_tool_yaw",0,false)
	local cvShowYaw = CreateClientConVar("cl_nodegraph_tool_nodes_show_yaw",1,true)
	local cvAutoYaw = CreateClientConVar("cl_nodegraph_tool_yaw_auto",1,true)
	local cvStepCheck = CreateClientConVar("cl_nodegraph_tool_stepcheck_enable",1,true)
	local cvStepCheckGrndNodeGen = CreateClientConVar("cl_nodegraph_tool_gen_ground_stepcheck_enable",1,false)
	local cvNodeProjection = CreateClientConVar("cl_nodegraph_tool_nodeproj_enable",1,true)
	local cvNodeProjGrndNodeGen = CreateClientConVar("cl_nodegraph_tool_gen_ground_nodeproj_enable",1,false)
	local cvNodeProjAirNodeGen = CreateClientConVar("cl_nodegraph_tool_gen_air_nodeproj_enable",1,false)
	local cvJumpLink = CreateClientConVar("cl_nodegraph_tool_jump_link",0,false)
	local cvNodeRadius = CreateClientConVar("cl_nodegraph_tool_nodeproj_radius",900,false) -- 30 squared
	local cvPlaceNodeOnGround = CreateClientConVar("cl_nodegraph_tool_place_node_on_ground",0,true)
	local cvPNOGOffset = CreateClientConVar("cl_nodegraph_tool_place_node_on_ground_offset",0,true)
	local cvPNOGHull = CreateClientConVar("cl_nodegraph_tool_place_node_on_ground_hull",1,true)
	local cvThinkDelay = CreateClientConVar("cl_nodegraph_tool_think_delay",0.05,true)
	local cvUndoableNodes = CreateClientConVar("cl_nodegraph_tool_undoable_nodes",1,true)
	local cvTraceHull = CreateClientConVar("cl_nodegraph_tool_use_tracehull",0,true)
	local cvShowNormalLinks = CreateClientConVar("cl_nodegraph_tool_show_normal_links",1,true)
	local cvShowJumpLinks = CreateClientConVar("cl_nodegraph_tool_show_jump_links",1,true)
	local cvShowFlyLinks = CreateClientConVar("cl_nodegraph_tool_show_fly_links",1,true)
	local cvShowClimbLinks = CreateClientConVar("cl_nodegraph_tool_show_climb_links",1,true)
	local cvDontSelDiffNode = CreateClientConVar("cl_nodegraph_tool_dont_select_diff_node_type",1,true)
	local cvMinJumpHeight = CreateClientConVar("cl_nodegraph_tool_gen_jump_min_height",72,false)
	local cvJumpGenTraceHull = CreateClientConVar("cl_nodegraph_tool_gen_jump_tracehull",1,false)
	local cvAirGenTraceHull = CreateClientConVar("cl_nodegraph_tool_gen_air_link_tracehull",1,false)
	local cvGrndGenTraceHull = CreateClientConVar("cl_nodegraph_tool_gen_ground_link_tracehull",0,false)
	local cvAirGenStriderNode = CreateClientConVar("cl_nodegraph_tool_gen_air_strider_node",0,false)
	local cvAirGenHeight = CreateClientConVar("cl_nodegraph_tool_gen_air_height",64,false)
	local cvAirGenGrndLinks = CreateClientConVar("cl_nodegraph_tool_gen_air_ground_links",1,false)
	local cvPlainLinks = CreateClientConVar("cl_nodegraph_tool_plain_links",1,true)
	local cvGrndGenNavAreaSize = CreateClientConVar("cl_nodegraph_tool_gen_ground_navareasize",3000,false)
	local cvGrndGenWater = CreateClientConVar("cl_nodegraph_tool_gen_ground_allow_water",0,false)
	local cvGrndGenCrouch = CreateClientConVar("cl_nodegraph_tool_gen_ground_allow_crouch",0,false)
	local cvGrndGenJump = CreateClientConVar("cl_nodegraph_tool_gen_ground_allow_jump",0,false)
	local cvGrndGenJumpLinks = CreateClientConVar("cl_nodegraph_tool_gen_ground_jump_links",1,false)
	local cvGrndGenNavLinks = CreateClientConVar("cl_nodegraph_tool_gen_ground_navlinks",1,false)
	local cvGrndGenHintJumps = CreateClientConVar("cl_nodegraph_tool_gen_ground_jump_hints",0,false)
	local cvJumpGenHintJumps = CreateClientConVar("cl_nodegraph_tool_gen_jump_hints",0,false)
	local cvGrndGenKLZ = CreateClientConVar("cl_nodegraph_tool_gen_ground_onlykeeplargestzone",0,false)
	local cvAirGenKLZ = CreateClientConVar("cl_nodegraph_tool_gen_air_onlykeeplargestzone",0,false)
	local cvGrndGenGridStep = CreateClientConVar("cl_nodegraph_tool_gen_grid_step",256,false)
	local cvGrndGenGridRangeEnabled = CreateClientConVar("cl_nodegraph_tool_gen_grid_range_enabled",0,false)
	local cvGrndGenGridRange = CreateClientConVar("cl_nodegraph_tool_gen_grid_range",2048,false)
	local cvGrndGenGridRemNodes = CreateClientConVar("cl_nodegraph_tool_gen_grid_removenodes",1,false)
	local cvGrndGenGridWater = CreateClientConVar("cl_nodegraph_tool_gen_grid_allowwater",0,false)
	local cvGrndGenGridOffset = CreateClientConVar("cl_nodegraph_tool_gen_grid_height_offset",16,false)

	-- Zone related utilities
	local cvSelectedZones = CreateClientConVar("cl_nodegraph_tool_selectedzones","",false)
	local cvSZGround = CreateClientConVar("cl_nodegraph_tool_selectedzones_ground",1,false)
	local cvSZAir = CreateClientConVar("cl_nodegraph_tool_selectedzones_air",1,false)
	local cvSZClimb = CreateClientConVar("cl_nodegraph_tool_selectedzones_climb",1,false)
	local cvSZHint = CreateClientConVar("cl_nodegraph_tool_selectedzones_hint",0,false)

	-- Mass remove
	local cvMassRemUsePlyrPos = CreateClientConVar("cl_nodegraph_tool_massrem_useplyrpos",0,true)
	local cvMassRemRadius = CreateClientConVar("cl_nodegraph_tool_massrem_radius",128,true)
	local cvMassRemGrndNds = CreateClientConVar("cl_nodegraph_tool_massrem_grndnds",1,true)
	local cvMassRemAirNds = CreateClientConVar("cl_nodegraph_tool_massrem_airnds",1,true)
	local cvMassRemClimbNds = CreateClientConVar("cl_nodegraph_tool_massrem_climbnds",1,true)
	local cvMassRemHintNds = CreateClientConVar("cl_nodegraph_tool_massrem_hintnds",1,true)

	-- Hull types
	local cvHullView = CreateClientConVar("cl_nodegraph_tool_hulltype_view", 1, true)
	local cvHullAuto = CreateClientConVar("cl_nodegraph_tool_hulltype_auto", 0, true)
	local cvHull1 = CreateClientConVar("cl_nodegraph_tool_hulltype_1", 1, false)
	local cvHull2 = CreateClientConVar("cl_nodegraph_tool_hulltype_2", 1, false)
	local cvHull3 = CreateClientConVar("cl_nodegraph_tool_hulltype_3", 1, false)
	local cvHull4 = CreateClientConVar("cl_nodegraph_tool_hulltype_4", 1, false)
	local cvHull5 = CreateClientConVar("cl_nodegraph_tool_hulltype_5", 1, false)
	local cvHull6 = CreateClientConVar("cl_nodegraph_tool_hulltype_6", 1, false)
	local cvHull7 = CreateClientConVar("cl_nodegraph_tool_hulltype_7", 1, false)
	local cvHull8 = CreateClientConVar("cl_nodegraph_tool_hulltype_8", 1, false)
	local cvHull9 = CreateClientConVar("cl_nodegraph_tool_hulltype_9", 1, false)
	local cvHull10 = CreateClientConVar("cl_nodegraph_tool_hulltype_10", 1, false)

	local HULL_TYPES = {
		[1]  = { mins = Vector(-13, -13, 0),   maxs = Vector(13, 13, 72)  }, -- HUMAN_HULL
		[2]  = { mins = Vector(-20, -20, -20), maxs = Vector(20, 20, 20)  }, -- SMALL_CENTERED_HULL
		[3]  = { mins = Vector(-15, -15, 0),   maxs = Vector(15, 15, 72)  }, -- WIDE_HUMAN_HULL
		[4]  = { mins = Vector(-12, -12, 0),   maxs = Vector(12, 12, 24)  }, -- TINY_HULL
		[5]  = { mins = Vector(-35, -35, 0),   maxs = Vector(35, 35, 32)  }, -- WIDE_SHORT_HULL
		[6]  = { mins = Vector(-16, -16, 0),   maxs = Vector(16, 16, 64)  }, -- MEDIUM_HULL
		[7]  = { mins = Vector(-8, -8, -4),    maxs = Vector(8, 8, 4)     }, -- TINY_CENTERED_HULL
		[8]  = { mins = Vector(-40, -40, 0),   maxs = Vector(40, 40, 100) }, -- LARGE_HULL
		[9]  = { mins = Vector(-38, -38, -38), maxs = Vector(38, 38, 38)  }, -- LARGE_CENTERED_HULL
		[10] = { mins = Vector(-18, -18, 0),   maxs = Vector(18, 18, 100) }  -- MEDIUM_TALL_HULL
	}

	local TraceMask = MASK_NPCWORLDSTATIC

	local matArrow = Material("widgets/arrow.png","nocull translucent vertexalpha smooth mips")
	local szArrow = 20
	local colArrow = Color(255,0,0,255)
	local colArrowSelected = Color(0,255,0,255)
	cvars.AddChangeCallback("cl_nodegraph_tool_yaw",function(cvar,prev,new)
		local tm = CurTime()
		local hk = "nodegrapheditor_renderyawarrow"
		local yaw = tonumber(new)
		if(cvShowYaw:GetBool()) then return end
		hook.Add("RenderScreenspaceEffects",hk,function()
			local tool = GetTool()
			if(tool && !cvShowYaw:GetBool()) then
				local a = math.min((1 -(((CurTime() -1) -tm) /2)) *255,255)
				if(a < 0) then hook.Remove("RenderScreenspaceEffects",hk)
				else
					local pos = tool:GetPreviewOrigin()
					cam.Start3D(EyePos(),EyeAngles())
						colArrow.a = a
						pos = pos +Vector(0,0,30)
						local dir = Angle(0,yaw,0):Forward()
						render.SetMaterial(matArrow)
						render.DepthRange(0,0.01)
						cam.IgnoreZ(true)
						render.DrawBeam(pos,pos +dir *szArrow,6,1,0,colArrow)
						cam.IgnoreZ(false)
					cam.End3D()
				end
			else hook.Remove("RenderScreenspaceEffects",hk) end
		end)
	end)
	local nodegraph
	local nodes,links,lookup
	function TOOL:BuildNodeGrid()
		if not nodeGrid then
			nodeGrid = Grid:New()
		end
		nodeGrid:Build(nodes)
	end
	function TOOL:Deploy()
		self.m_deployed = true
	end
	function TOOL:LeftClick(tr)
		if self.m_bWaitingForGridStart then
			self:GenerateGridNodes(tr.HitPos)
			self.m_bWaitingForGridStart = false
			notification.AddLegacy("Grid generation finished.", 0, 5)
			return true
		end
		if self:GetOwner():KeyDown(IN_RELOAD) then
			local radius = cvMassRemRadius:GetInt()
			local radiusSqr = radius * radius
			local origin = self:GetMassRemOrigin()
			local removed = 0
			for id, node in pairs(nodes) do
				local nodeType = node.type
				local enabled =
					(nodeType == NODE_TYPE_GROUND and cvMassRemGrndNds:GetBool()) or
					(nodeType == NODE_TYPE_AIR and cvMassRemAirNds:GetBool()) or
					(nodeType == NODE_TYPE_CLIMB and cvMassRemClimbNds:GetBool()) or
					(nodeType == NODE_TYPE_HINT and cvMassRemHintNds:GetBool())
				if enabled and node.pos:DistToSqr(origin) <= radiusSqr and self:IsNodeTypeVisible(nodeType) then
					self:RemoveEffect(id)
					nodeGrid:Remove(id, node)
					nodegraph:RemoveNode(id)
					removed = removed + 1
				end
			end
			if removed > 0 then
				local numNodes = nodegraph:CountNodes(nodes)
				notification.AddLegacy("Removed " .. removed .. " nodes within " .. radius .. " units.",0,8)
			end
		else
			if(self.m_selected) then
				if(self:GetOwner():KeyDown(IN_DUCK) || self:GetOwner():KeyDown(IN_USE)) then
					if(self.m_bKeepSelection) then
						local nodeTrace,nodeTraceID = self:GetTraceNode()
						local nodeSelected = nodes[self.m_selected]
						if(nodeTrace == nodeSelected) then self:RemoveLinks(self.m_selected)
						elseif(self:HasLink(self.m_selected,nodeTraceID)) then self:RemoveLink(self.m_selected,nodeTraceID)
						else
							if cvJumpLink:GetBool() then
								self:AddLink(self.m_selected,nodeTraceID,2)
							else
								self:AddLink(self.m_selected,nodeTraceID)
							end
						end
					else self:SolidifySelection() end
				else self:RemoveNode(self.m_selected) end
			else self:CreateNode(self:GetPreviewOrigin()) end
		end
		return true
	end
	function TOOL:RightClick(tr)
		if self.m_selected then
			if(self:GetOwner():KeyDown(IN_DUCK) || self:GetOwner():KeyDown(IN_USE)) then
				local nodeSelected = nodes[self.m_selected]
				nodeSelected.hint = cvHint:GetInt()
				notification.AddLegacy("Assigned hint info of selected node to " .. nodeSelected.hint .. ".",0,8)
				self:ClearEffects()
			end
		else
			self:CreateNode(self:GetOwner():GetPos() +self:GetOwner():OBBCenter())
		end
		return true
	end
	function TOOL:CreateNode(pos)
		local createType = cvCreateType:GetInt()
		local h = cvH:GetInt()
		local pl = self:GetOwner()
		local pos2 = pos
		if createType == NODE_TYPE_GROUND then
			pos2[3] = pos2[3] + h
		end
		if createType == NODE_TYPE_AIR and cvAirNodeHeightOffsetEnable:GetBool() then
			pos2[3] = self:GetAirNodeHeightOffset(pos2)
		end
		local info = cvHint:GetInt()
		local nodeID = nodegraph:AddNode(pos2, createType, cvYaw:GetInt(), 0, info)
		if not nodeID then
			notification.AddLegacy("You can't place any additional nodes.", 1, 8)
			return
		end
		nodeGrid:Insert(nodeID, nodes[nodeID])
		local numNodes = nodegraph:CountNodes(nodes)
		local distMin = math.min(cvDist:GetInt(), cvDistLink:GetInt())
    	local nodeRadius = cvNodeRadius:GetInt()
		local nearbyNodes = nodeGrid:Query(pos, distMin, nodes)
		local nodesToClean = {}
		for otherNodeID, node in pairs(nearbyNodes) do
			if otherNodeID ~= nodeID then
				if self:IsNodeTypeVisible(node.type) then
					if node.type == createType and createType ~= NODE_TYPE_CLIMB and createType ~= NODE_TYPE_HINT then
						if node.type ~= NODE_TYPE_AIR and createType ~= NODE_TYPE_AIR then
							if self:IsLineClear(pos, node.pos) then
								if cvNodeProjection:GetBool() then
									local obstructed = false
									local midPoint = pos + (node.pos - pos) * 0.5
                                    local checkRadius = (pos - midPoint):Length() + nodeRadius
									local obstructionCandidates = nodeGrid:Query(midPoint, checkRadius, nodes)
									for k, nodeB in pairs(obstructionCandidates) do
										if k ~= otherNodeID and k ~= nodeID and nodeB.type == createType then
                                            if IsNodeBetween(pos, nodeB.pos, node.pos, nodeRadius) then
												obstructed = true
												break
											end
										end
									end
									if not obstructed then
										self:AddLink(nodeID, otherNodeID)
										table.insert(nodesToClean, otherNodeID)
									end
								else
									self:AddLink(nodeID, otherNodeID)
								end
							end
						else
							if self:IsLineClear(pos, node.pos, false, cvTraceHull:GetBool() and 2 or 0) then
								if cvNodeProjection:GetBool() then
									local obstructed = false
									local midPoint = pos + (node.pos - pos) * 0.5
                                    local checkRadius = (pos - midPoint):Length() + nodeRadius
									local obstructionCandidates = nodeGrid:Query(midPoint, checkRadius, nodes)
									for k, nodeB in pairs(obstructionCandidates) do
										if k ~= otherNodeID and k ~= nodeID and nodeB.type == createType then
                                            if IsNodeBetween(pos, nodeB.pos, node.pos, nodeRadius) then
												obstructed = true
												break
											end
										end
									end
									if not obstructed then
										self:AddLink(nodeID, otherNodeID)
										table.insert(nodesToClean, otherNodeID)
									end
								else
									self:AddLink(nodeID, otherNodeID)
								end
							end
						end
					end
				end
			end
		end
		if table.Count(nodesToClean) > 0 then
			self:CleanNodegraphLinks(nodesToClean)
		end
		if cvPlaceNodeOnGround:GetBool() then
			local curNode = nodes[nodeID]
			if curNode.type == NODE_TYPE_GROUND then
				local startPos = curNode.pos
				local count = 0
				local succeed = false
				if cvPNOGHull:GetBool() then
					while count < 16 do
						local trace = util.TraceHull({
								start = startPos,
								endpos = startPos,
								mins = Vector(-16, -16, 0),
								maxs = Vector(16, 16, 8),
								mask = TraceMask,
								filter = pl
							})

						if not trace.StartSolid then
							break
						end

						count = count + 1
						startPos = startPos + Vector(0, 0, 1)
					end
					local finalTrace = util.TraceHull({
						start = startPos,
						endpos = startPos,
						mins = Vector(-16, -16, 0),
						maxs = Vector(16, 16, 8),
						mask = TraceMask,
						filter = pl
					})
					if not finalTrace.StartSolid then
						succeed = true
					end
					if succeed then
						local endPos = startPos - Vector(0, 0, 10000)
						local trace = util.TraceHull({
								start = startPos,
								endpos = endPos,
								mins = Vector(-16, -16, 0),
								maxs = Vector(16, 16, 8),
								mask = TraceMask,
								filter = pl
							})
						if trace.Hit then
							curNode.pos = trace.HitPos + Vector(0, 0, cvPNOGOffset:GetInt())
						end
					end
				else
					while bit.band(util.PointContents(startPos), CONTENTS_SOLID) ~= 0 and count < 16 do
						count = count + 1
						startPos = startPos + Vector(0, 0, 1)
					end
					if bit.band(util.PointContents(startPos), CONTENTS_SOLID) == 0 then
						succeed = true
					end
					if succeed then
						local endPos = startPos - Vector(0, 0, 10000)
						local trace = util.TraceLine({
								start = startPos,
								endpos = endPos,
								mask = TraceMask,
								filter = pl
							})
						if trace.Hit then
							curNode.pos = trace.HitPos + Vector(0, 0, cvPNOGOffset:GetInt())
						end
					end
				end
			end
		end
		if cvUndoableNodes:GetBool() then
			net.Start("sv_nodegrapheditor_undo_node") // Sending it to the server and then back to the client. Dumb, but no other way.
				net.WriteUInt(nodeID,14)
			net.SendToServer()
		end
		if((numNodes == 7950 || numNodes == 8000 || numNodes == 8150) and createType ~= NODE_TYPE_HINT) then notification.AddLegacy("You are close to the node limit (" .. numNodes .. "/" .. MAX_NODES .. ").",0,8)
		elseif(numNodes == MAX_NODES and createType ~= NODE_TYPE_HINT) then notification.AddLegacy("You have reached the node limit.",0,8) end
	end
	function TOOL:CreateNodeGen(pos, nodetype, hint)
		if not nodetype then
			nodetype = NODE_TYPE_GROUND
		end
		local h = cvHGrndNodeGen:GetInt()
		local pos2 = pos
		if nodetype == NODE_TYPE_GROUND then pos2[3]=pos2[3]+h end
		local nodeID = nodegraph:AddNode(pos2, nodetype, cvYaw:GetInt(), 0, hint or 0)
		if not nodeID then
			return nil
		end
		--[[
		if cvUndoableNodes:GetBool() then
			net.Start("sv_nodegrapheditor_undo_node") // Sending it to the server and then back to the client. Dumb, but no other way.
				net.WriteUInt(nodeID,14)
			net.SendToServer()
		end
		]]
		return nodeID
	end
	function TOOL:RemoveUnlinkedNodes(nodeType)
		local count = 0
		for id, node in pairs(nodes) do
			if not node.link or table.Count(node.link) <= 0 then
				if nodeType and node.type ~= nodeType then continue end
				if node.type == NODE_TYPE_HINT then continue end
				nodeGrid:Remove(id, node)
				nodegraph:RemoveNode(id)
				count = count + 1
			end
		end
		self:BuildNodeGrid()
		self:ClearEffects()
		return count
	end
	local expectedChunks
	local totalSize
	local receivedChunks = {}
	net.Receive("nodegraph_gen_client", function(length)
		local totalChunks = net.ReadUInt(16)
		local chunkIndex = net.ReadUInt(16)
		local fullSize = net.ReadUInt(32)
		local chunkSize = net.ReadUInt(32)
		local chunkData = net.ReadData(chunkSize)
		
		if chunkIndex == 1 then
			expectedChunks = totalChunks
			totalSize = fullSize
			receivedChunks = {}
		end
		
		receivedChunks[chunkIndex] = chunkData
		
		local allChunksReceived = true
		for i = 1, expectedChunks do
			if not receivedChunks[i] then
				allChunksReceived = false
				break
			end
		end
		
		if allChunksReceived then
			local combinedData = ""
			for i = 1, expectedChunks do
				combinedData = combinedData .. receivedChunks[i]
			end
			
			local json = util.Decompress(combinedData)
			local posTable = util.JSONToTable(json)

			receivedChunks = {}
			
			local tool = GetTool()
			local numNodes

			if not tool then 
				return
			end

			if not posTable or #posTable <= 0 then 
				notification.AddLegacy("No Navmesh found. Please generate one first before using.",0,8)
				return
			end

			for id, node in pairs(nodes) do
				if node.type == NODE_TYPE_GROUND then
					nodegraph:RemoveNode(id)
				end
			end
		
			local generatedCount = 0
			local areaIDToNodeID = {}
			local nodeList = {}
			local nodesToClean = {}
			for i = 1, #posTable do
				local areaData = posTable[i]
				numNodes = nodegraph:CountNodes(nodes)
				if numNodes >= MAX_NODES then break end
				local nodeID = tool:CreateNodeGen(areaData.pos)
				if nodeID then
					areaIDToNodeID[areaData.id] = nodeID
					table.insert(nodeList, { nodeID = nodeID, pos = areaData.pos })
					table.insert(nodesToClean, nodeID)
					generatedCount = generatedCount + 1
				else
					print("Failed to create node for area ID:", areaData.id)
				end
			end
			tool:BuildNodeGrid()
			if cvGrndGenNavLinks:GetBool() then
				for i = 1, #posTable do
					local areaData = posTable[i]
					local srcNodeID = areaIDToNodeID[areaData.id]
					if srcNodeID then
						for j = 1, #areaData.adjacents do
							local adjAreaID = areaData.adjacents[j]
							local destNodeID = areaIDToNodeID[adjAreaID]
							if destNodeID then
								tool:AddLink(srcNodeID, destNodeID)
							end
						end
					end
				end
			end
			if cvGrndGenJumpLinks:GetBool() then
				for i = 1, #posTable do
					local areaData = posTable[i]
					local srcNodeID = areaIDToNodeID[areaData.id]
					if srcNodeID then
						for j = 1, #areaData.jumps do
							local adjAreaID = areaData.jumps[j]
							local destNodeID = areaIDToNodeID[adjAreaID]
							if destNodeID then
								tool:AddLink(srcNodeID, destNodeID, 2)
								if cvGrndGenHintJumps:GetBool() then
									local srcNode = nodes[srcNodeID]
									local destNode = nodes[destNodeID]
									if srcNode and destNode then
										srcNode.hint = 901
										destNode.hint = 901
									end
								end
							end
						end
					end
				end
			end
			if cvDistLinkGrndNodeGen:GetInt() > 0 then
				local distMin = math.min(cvDist:GetInt(), cvDistLinkGrndNodeGen:GetInt())
				local nodeRadius = cvNodeRadius:GetInt()
				for i = 1, #nodeList do
					local nodeA = nodeList[i]
					local neighborCandidates = nodeGrid:Query(nodeA.pos, distMin, nodes)
					for otherID, otherNode in pairs(neighborCandidates) do
						if otherID ~= nodeA.nodeID and otherNode.type == NODE_TYPE_GROUND then
							if not tool:HasLink(nodeA.nodeID, otherID) then
								if tool:IsLineClear(nodeA.pos, otherNode.pos, cvStepCheckGrndNodeGen:GetBool(), cvGrndGenTraceHull:GetInt()) then
									tool:AddLink(nodeA.nodeID, otherID)
								end
							end
						end
					end
				end
			end

			if not table.IsEmpty(nodesToClean) and cvNodeProjGrndNodeGen:GetBool() then
				tool:CleanNodegraphLinks(nodesToClean)
			end

			if cvPlaceNodeOnGround:GetBool() then
				tool:PlaceAllNodesToGround()
			end

			if cvGrndGenKLZ:GetBool() then
				local klzCount = tool:OnlyKeepLargestZone(true, false)
				generatedCount = generatedCount - klzCount
			end

			local removedUnlinked = tool:RemoveUnlinkedNodes(NODE_TYPE_GROUND)
			generatedCount = generatedCount - removedUnlinked

			tool:BuildNodeGrid()
			tool:BuildZone()
			tool:ClearEffects()
		
			if generatedCount > 0 then
				notification.AddLegacy("Successfully generated " .. generatedCount .. " Ground Nodes.",0,8)
			else
				notification.AddLegacy("Failed to generate Ground Nodes.",0,8)
			end
		end
	end)
	net.Receive("nodegraph_cleareffects_client", function(length)
		for _, v in ents.Iterator() do
			if v:GetClass() == "class CLuaEffect" and v.EffectName == "effect_node" then
				if IsValid(v) then
					v:Remove()
				end
			end
		end
		-- The tool no longer exists when the player died in singleplayer.
		local tool = GetTool()
		if not tool then return end
		tool:ClearEffects()
	end)
	local hintData = {}
	net.Receive("nodegraph_get_hint_client", function(length)
		local data = net.ReadData(length)
    	local decompressed = util.Decompress(data)
    	hintData = util.JSONToTable(decompressed)
	end)
	local updatedMapVersion
	net.Receive("nodegraph_getmapversion_client", function(length)
		updatedMapVersion = net.ReadUInt(32)
	end)
	function TOOL:GetBuiltInHints()
		net.Start("nodegraph_get_hint_server")
		net.WriteEntity(self:GetOwner())
		net.SendToServer()
	end
	function TOOL:GetMapVersion()
		net.Start("nodegraph_getmapversion_server")
		net.WriteEntity(self:GetOwner())
		net.SendToServer()
	end
	function TOOL:GenerateNodes()
		local conVars = {
			NavAreaSize = cvGrndGenNavAreaSize:GetInt(),
			WaterAreas = cvGrndGenWater:GetBool(),
			CrouchAreas = cvGrndGenCrouch:GetBool(),
			JumpAreas = cvGrndGenJump:GetBool(),
			GenJumpLinks = cvGrndGenJumpLinks:GetBool()
		}
		net.Start("nodegraph_gen_server")
		net.WriteEntity(self:GetOwner())
		net.WriteTable(conVars)
		net.SendToServer()
	end
	function TOOL:GenerateAirNodes()
		local groundData = {}
		local nodesToClean = {}
		local count = 0
		local distMin = math.min(cvDist:GetInt(), cvDistLinkAirNodeGen:GetInt())
		local nodeRadius = cvNodeRadius:GetInt()
		local pl = self:GetOwner()
		
		for id, node in pairs(nodes) do
			if node.type == NODE_TYPE_AIR then
				nodegraph:RemoveNode(id)
			end
	
			if node.type == NODE_TYPE_GROUND then
				local validPos
				local startPos = node.pos
				local endPos = startPos - Vector(0, 0, 10000)
				local attempts = 0
				while attempts < 16 do
					local trace = util.TraceHull({
						start = startPos,
						endpos = startPos,
						mins = Vector(-16, -16, 0),
						maxs = Vector(16, 16, 8),
						mask = TraceMask,
						filter = pl
					})
				
					if not trace.StartSolid then
						break
					end
				
					startPos = startPos + Vector(0, 0, 1)
					attempts = attempts + 1
				end
				local finalTrace = util.TraceHull({
					start = startPos,
					endpos = startPos,
					mins = Vector(-16, -16, 0),
					maxs = Vector(16, 16, 8),
					mask = TraceMask,
					filter = pl
				})
				if finalTrace.StartSolid then
					continue
				end
				local endPos = startPos - Vector(0, 0, 10000)
				local trace = util.TraceHull({
					start = startPos,
					endpos = endPos,
					mins = Vector(-16, -16, 0),
					maxs = Vector(16, 16, 8),
					mask = TraceMask,
					filter = pl
				})
				if trace.Hit then
					validPos = trace.HitPos
				else
					validPos = node.pos
				end

				table.insert(groundData, { pos = validPos, parentID = id, links = node.link })
			end
		end
		
		local parentToAir = {}
		
		for _, data in pairs(groundData) do
			local startPos = data.pos
			local endPos = startPos + Vector(0, 0, cvAirGenHeight:GetInt())
			local firstTrace = util.TraceLine({
				start = startPos,
				endpos = endPos + Vector(0, 0, 64), -- They must have at least 64 units of empty space above them to be valid.
				mask = TraceMask,
				filter = pl
			})
			if firstTrace.Hit then continue end
			local validPos = endPos
			if validPos then
				local numNodes = nodegraph:CountNodes(nodes)
				if numNodes >= MAX_NODES then
					notification.AddLegacy("Reached the maximum node limit. Can't generate more Air Nodes.",0,8)
					break
				end
				local airNode = self:CreateNodeGen(validPos, NODE_TYPE_AIR, cvAirGenStriderNode:GetBool() and 904 or 0)
				if airNode then
					nodes[airNode].parentGround = data.parentID
					parentToAir[data.parentID] = airNode
					table.insert(nodesToClean, airNode)
					count = count + 1
				end
			end
		end
		
		if cvAirGenGrndLinks:GetBool() then
			for _, data in pairs(groundData) do
				local parentID = data.parentID
				local airNodeID = parentToAir[parentID]
				if airNodeID then
					for _, link in pairs(data.links) do
						if link.move and not table.HasValue(link.move, 1) then continue end
						local otherGround = nil
						if link.src and link.src ~= nodes[parentID] then
							otherGround = link.src
						elseif link.dest and link.dest ~= nodes[parentID] then
							otherGround = link.dest
						end
						if otherGround then
							local otherID = nil
							for id, n in pairs(nodes) do
								if n == otherGround then
									otherID = id
									break
								end
							end
							if otherID and parentToAir[otherID] then
								self:AddLink(airNodeID, parentToAir[otherID], 4)
							end
						end
					end
				end
			end
		end
		
		if cvDistLinkAirNodeGen:GetInt() > 0 then
			self:BuildNodeGrid()
			for _, airNodeID in pairs(parentToAir) do
				local validPos = nodes[airNodeID].pos
				local neighborCandidates = nodeGrid:Query(validPos, distMin, nodes)
				for otherID, otherNode in pairs(neighborCandidates) do
					if otherID ~= airNodeID and otherNode.type == NODE_TYPE_AIR then
						if self:IsLineClear(validPos, otherNode.pos, false, cvAirGenTraceHull:GetBool() and 2 or 0) then
							self:AddLink(airNodeID, otherID, 4)
						end
					end
				end
			end
		end

		if not table.IsEmpty(nodesToClean) and cvNodeProjAirNodeGen:GetBool() then
			self:CleanNodegraphLinks(nodesToClean)
		end

		if cvAirGenKLZ:GetBool() then
			local klzCount = self:OnlyKeepLargestZone(false, true)
			count = count - klzCount
		end

		local removedNodes = self:RemoveUnlinkedNodes(NODE_TYPE_AIR)
		count = count - removedNodes
		
		if count > 0 then
			notification.AddLegacy("Successfully generated " .. count .. " Air Nodes.",0,8)
		else
			notification.AddLegacy("Failed to generate Air Nodes. Either no Ground Nodes found, or no space for Air Nodes.",1,8)
		end
		self:BuildNodeGrid()
		self:BuildZone()
	end
	function TOOL:GenerateJumpLinks()
		local distMinLinear = math.min(cvDist:GetInt(), cvDistLinkJmpLinkGen:GetInt())
		local distMin = distMinLinear * distMinLinear
		local pl = self:GetOwner()
		self:RemoveLinksWithType(2)
		self:BuildNodeGrid()
		for a1, nodea in pairs(nodes) do
			if nodea.type ~= NODE_TYPE_GROUND then continue end
			local neighborCandidates = nodeGrid:Query(nodea.pos, distMinLinear, nodes)
			for b1, nodeb in pairs(neighborCandidates) do
				if b1 ~= a1 and nodeb and nodeb.type == NODE_TYPE_GROUND then
					local d = nodea.pos:DistToSqr(nodeb.pos)
					if d <= distMin then
						local deltaZ = nodeb.pos[3] - nodea.pos[3]
						if not self:HasLink(a1, b1) and deltaZ < -cvMinJumpHeight:GetInt() then
							local traceStart = nodea.pos + Vector(0, 0, 3)
							local traceEnd = Vector(nodeb.pos.x, nodeb.pos.y, nodea.pos.z)
							local traceResult
							local trace
							if cvJumpGenTraceHull:GetBool() then
								trace = {
									start = traceStart,
									endpos = traceEnd,
									mins = Vector(-13, -13, 0),
									maxs = Vector(13, 13, 69),
									mask = TraceMask,
									filter = pl
								}
								traceResult = util.TraceHull(trace)
							else
								trace = {
									start = traceStart,
									endpos = traceEnd,
									mask = TraceMask,
									filter = pl
								}
								traceResult = util.TraceLine(trace)
							end
							if not traceResult.Hit then
								trace.start = Vector(nodeb.pos.x, nodeb.pos.y, nodea.pos.z)
								trace.endpos = nodeb.pos + Vector(0, 0, 3)
								local finalTraceResult
								if cvJumpGenTraceHull:GetBool() then
									finalTraceResult = util.TraceHull(trace)
								else
									finalTraceResult = util.TraceLine(trace)
								end
								if not finalTraceResult.Hit then
									self:AddLink(a1, b1, 2)
									if cvJumpGenHintJumps:GetBool() then
										local srcNode = nodes[a1]
										local destNode = nodes[b1]
										if srcNode and destNode then
											srcNode.hint = 901
											destNode.hint = 901
										end
									end
								end
							end
						end
					end
				end
			end
		end
		self:BuildZone()
	end
	function TOOL:GenerateGridNodes(startPos)
		local step = cvGrndGenGridStep:GetInt()
		local range = cvGrndGenGridRange:GetInt()
		local useRange = cvGrndGenGridRangeEnabled:GetBool()
		local allowWater = cvGrndGenGridWater:GetBool()
		local hOffset = cvGrndGenGridOffset:GetInt()
		local count = 0
		local pl = self:GetOwner()
		local createdNodes = {}

		startPos.x = math.Round(startPos.x / step) * step
		startPos.y = math.Round(startPos.y / step) * step
		startPos.z = math.Round(startPos.z / step) * step

		local minX, maxX, minY, maxY, minZ, maxZ
		local rangeSqr = range * range

		if useRange then
			minX, maxX = startPos.x - range, startPos.x + range
			minY, maxY = startPos.y - range, startPos.y + range
			minZ, maxZ = startPos.z - range, startPos.z + range
		else
			local mins, maxs = game.GetWorld():GetModelBounds()
			minX = startPos.x - math.ceil((startPos.x - mins.x) / step) * step
			minY = startPos.y - math.ceil((startPos.y - mins.y) / step) * step
			minZ = startPos.z - math.ceil((startPos.z - mins.z) / step) * step
			maxX, maxY, maxZ = maxs.x, maxs.y, maxs.z
		end

		local candidates = {}

		if cvGrndGenGridRemNodes:GetBool() then
			for id, node in pairs(nodes) do
				if node.type == NODE_TYPE_GROUND then
					nodegraph:RemoveNode(id)
				end
			end
		end

		for x = minX, maxX, step do
			for y = minY, maxY, step do
				local dx = x - startPos.x
				local dy = y - startPos.y
				if useRange and (dx * dx + dy * dy) > rangeSqr then
					continue
				end
				for z = minZ, maxZ, step do
					table.insert(candidates, Vector(x, y, z))
				end
			end
		end

		table.sort(candidates, function(a, b)
			return a:DistToSqr(startPos) < b:DistToSqr(startPos)
		end)

		for _ = 1, #candidates do
			local pos = candidates[_]
			if nodegraph:CountNodes(nodes) >= MAX_NODES then
				notification.AddLegacy("Reached node limit. Stopped generation.", 1, 8)
				break
			end

			local aboveOffset = Vector(0, 0, 0)
			local aboveCheckTr = util.TraceLine({
				start = pos,
				endpos = pos + Vector(0, 0, 128),
				mask = TraceMask,
				filter = pl
			})

			if aboveCheckTr.Hit then
				aboveOffset.z = aboveCheckTr.HitPos.z - pos.z
			else
				aboveOffset.z = 128
			end

			local placeCheckTr = util.TraceLine({
				start = pos + aboveOffset,
				endpos = pos - Vector(0, 0, step * 1.5 + 128),
				mask = TraceMask,
				filter = pl
			})

			if placeCheckTr.Hit and not placeCheckTr.StartSolid and placeCheckTr.HitNormal.z >= 0.70710678 then

				if not allowWater then
					local contents = util.PointContents(placeCheckTr.HitPos)
					if bit.band(contents, CONTENTS_WATER) ~= 0 then
						continue
					end
				end

				local solidCheckTr = util.TraceHull({
					start = placeCheckTr.HitPos + Vector(0, 0, 10),
					endpos = placeCheckTr.HitPos + Vector(0, 0, 10),
					mins = Vector(-13, -13, 0),
					maxs = Vector(13, 13, 62),
					mask = TraceMask,
					filter = pl
				})

				if solidCheckTr.StartSolid then
					continue
				end

				local nearby = nodeGrid:Query(placeCheckTr.HitPos, 50, nodes)
				if table.Count(nearby) == 0 then
					local nodeGenerated = nodegraph:AddNode(placeCheckTr.HitPos + Vector(0, 0, hOffset), NODE_TYPE_GROUND, 0, 0, 0)
					if nodeGenerated then
						nodeGrid:Insert(nodeGenerated, nodes[nodeGenerated])
						table.insert(createdNodes, nodeGenerated)
						count = count + 1
					end
				end
			end

			candidates[_] = nil
		end

		if count > 0 then
			self:BuildNodeGrid()
			for i = 1, #createdNodes do
				local nodeID = createdNodes[i]
				local node = nodes[nodeID]
				if not node then continue end

				local nearby = nodeGrid:Query(node.pos, step * 1.5, nodes)
				for otherID, otherNode in pairs(nearby) do
					if otherID ~= nodeID and otherNode.type == NODE_TYPE_GROUND then
						if not self:HasLink(nodeID, otherID) then
							if self:IsLineClear(node.pos, otherNode.pos, true, 0) then
								self:AddLink(nodeID, otherID)
							end
						end
					end
				end
			end
		end

		createdNodes = nil
		candidates = nil

		self:BuildNodeGrid()
		self:BuildZone()
		self:ClearEffects()
		notification.AddLegacy("Generated " .. count .. " ground nodes from grid.", 0, 8)
	end
	function TOOL:CleanNodegraphLinks(targetNodes)
		if not nodes then return 0 end
		local count = 0
		local nodeRadius = cvNodeRadius:GetInt()

		local nodesToProcess = {}
		if targetNodes then
			if type(targetNodes) == "table" then
				for k, v in pairs(targetNodes) do
					local id = (type(v) == "number" and v) or k
					if nodes[id] then nodesToProcess[id] = nodes[id] end
				end
			else
				if nodes[targetNodes] then nodesToProcess[targetNodes] = nodes[targetNodes] end
			end
		else
			nodesToProcess = nodes
		end

		self:BuildNodeGrid()
		for id, node in pairs(nodesToProcess) do
			if not node or not node.link then continue end
			for i, link in pairs(node.link) do
				local destID = link.destID
				local destNode = nodes[destID]
				if not destNode then continue end

				local obstructed = false
				local midPoint = node.pos + (destNode.pos - node.pos) * 0.5
				local checkRadius = (node.pos - midPoint):Length() + nodeRadius
				
				local obstructionCandidates = nodeGrid:Query(midPoint, checkRadius, nodes)
				for k, nodeB in pairs(obstructionCandidates) do
					if k ~= id and k ~= destID then
						if nodeB.type == node.type and nodeB.type == destNode.type then
							if IsNodeBetween(node.pos, nodeB.pos, destNode.pos, nodeRadius) then
								obstructed = true
								break
							end
						end
					end
				end
				
				if obstructed then
					self:RemoveLink(id, destID)
					count = count + 1
				end
			end
		end
		
		self:ClearEffects()
		return count
	end
	hook.Add("InputMouseApply", "NEPlusAdjustMassRem", function(cmd, x, y, ang)
		local tool = GetTool()
		if tool then
			if tool:GetOwner():KeyDown(IN_RELOAD) then
				local scrollDelta = cmd:GetMouseWheel()
				if scrollDelta ~= 0 then
					RunConsoleCommand("cl_nodegraph_tool_massrem_radius", math.Clamp(cvMassRemRadius:GetInt() + scrollDelta * 8, 1, 1024))
				end
			end
		end
	end)
	hook.Add("PlayerBindPress", "NEPlusDisableWeaponSwitch", function(ply, bind, pressed)
		local tool = GetTool()
		if tool and tool:GetOwner():KeyDown(IN_RELOAD) and (string.find(bind, "invnext") or string.find(bind, "invprev")) then
			return true
		end
	end)
	net.Receive("cl_nodegrapheditor_undo_node",function(len)
		local nodeID = net.ReadUInt(14)
		local tool = GetTool()
		if(!tool) then return end
		tool:RemoveNode(nodeID)
	end)
	function TOOL:HasLink(src,dest) return nodegraph:HasLink(src,dest) end
	function TOOL:RemoveLinks(nodeID) nodegraph:RemoveLinks(nodeID) end
	function TOOL:RemoveLink(src,dest) nodegraph:RemoveLink(src,dest) end
	function TOOL:TraceHullType(startpos, endpos, hullType, doLift, customMins, customMaxs)
		local offset = 16 - math.Clamp(cvH:GetInt(), 0, 16)
		local pl = self:GetOwner()

		local def = HULL_TYPES[hullType]
		if not def then return false end

		local mins = customMins or def.mins
		local maxs = customMaxs or def.maxs

		-- Bottom-align so the hull never starts intersecting the floor.
		local lift = doLift and offset or 0
		if doLift then
			maxs.z = math.max(maxs.z - (16 - offset), mins.z)
			lift = lift + math.max(0, -mins.z) + 0.1
		end

		local trace = util.TraceHull({
			start = lift > 0 and (startpos + Vector(0, 0, lift)) or startpos,
			endpos = lift > 0 and (endpos + Vector(0, 0, lift)) or endpos,
			mins = mins,
			maxs = maxs,
			mask = TraceMask,
			filter = pl
		})

		return not trace.Hit
	end
	function TOOL:AdjustNodeOffsets()
		local pl = self:GetOwner()

		for nodeID, node in pairs(nodes) do
			if node.type ~= NODE_TYPE_GROUND then continue end

			for i = 1, 10 do
				local def = HULL_TYPES[i]
				local mins = def.mins
				local maxs = def.maxs

				-- Bottom-align so the hull never starts intersecting the floor.
				local lift = math.max(0, -mins.z) + 0.1

				local startpos = node.pos
				local trace = util.TraceHull({
					start = lift > 0 and (startpos + Vector(0, 0, lift)) or startpos,
					endpos = startpos - Vector(0, 0, 128),
					mins = mins,
					maxs = maxs,
					mask = TraceMask,
					filter = pl
				})

				if trace.StartSolid then
					node.offset[i] = 0
					continue
				end
				node.offset[i] = trace.Hit and (trace.HitPos.z - node.pos.z) or 0
			end
		end
	end
	function TOOL:CreateMoveArray(movetype, srcPos, destPos)
		movetype = movetype or 1
		local autoHull = cvHullAuto:GetBool()
		local move = {}
		local cvHulls = {cvHull1, cvHull2, cvHull3, cvHull4, cvHull5, cvHull6, cvHull7, cvHull8, cvHull9, cvHull10}
		for i = 1, #cvHulls do
			local cv = cvHulls[i]
			if movetype == 1 and autoHull then
				move[i] = self:TraceHullType(srcPos, destPos, i, true) and (1 * movetype) or 0
			elseif movetype == 4 and autoHull then
				move[i] = self:TraceHullType(srcPos, destPos, i, false) and (1 * movetype) or 0
			else
				move[i] = math.Clamp(cv:GetInt(), 0, 1) * movetype
			end
		end
		return move
	end
	function TOOL:AddLink(src,dest,movetype)
		local srcNode = nodes[src]
		local destNode = nodes[dest]

		if not srcNode or not destNode then return end

		-- Some safeguards to avoid unexpected consequences.
		if srcNode.type == NODE_TYPE_HINT or destNode.type == NODE_TYPE_HINT then return end
		if (srcNode.type == NODE_TYPE_AIR and destNode.type == NODE_TYPE_CLIMB) or (srcNode.type == NODE_TYPE_CLIMB and destNode.type == NODE_TYPE_AIR) then return end
		if (srcNode.type == NODE_TYPE_AIR and destNode.type == NODE_TYPE_GROUND) or (srcNode.type == NODE_TYPE_GROUND and destNode.type == NODE_TYPE_AIR) then return end

		local move = {}
		if movetype == 1 then
			move = self:CreateMoveArray(1, srcNode.pos, destNode.pos)
		elseif movetype == 2 then
			if srcNode.type ~= NODE_TYPE_GROUND or destNode.type ~= NODE_TYPE_GROUND then
				return
			end
			move = self:CreateMoveArray(2)
		elseif movetype == 4 then
			move = self:CreateMoveArray(4, srcNode.pos, destNode.pos)
		elseif movetype == 8 then
			move = self:CreateMoveArray(8)
		else
			if srcNode.type == NODE_TYPE_AIR and destNode.type == NODE_TYPE_AIR then
				move = self:CreateMoveArray(4, srcNode.pos, destNode.pos)
			elseif srcNode.type == NODE_TYPE_CLIMB and destNode.type == NODE_TYPE_CLIMB then
				move = self:CreateMoveArray(8)
				if cvAutoYaw:GetBool() then
					if destNode.pos[3] > srcNode.pos[3] then
						local calcYaw = CalculateYaw(srcNode.pos, destNode.pos)
						srcNode.yaw = calcYaw
						destNode.yaw = calcYaw
					elseif destNode.pos[3] < srcNode.pos[3] then
						local calcYaw = CalculateYaw(destNode.pos, srcNode.pos)
						srcNode.yaw = calcYaw
						destNode.yaw = calcYaw
					end
				end
			else
				move = self:CreateMoveArray(1, srcNode.pos, destNode.pos)
			end
		end

		nodegraph:AddLink(src, dest, move)
	end
	function TOOL:RemoveNode(nodeID)
		local node = nodes[nodeID]
		if not node then return end
		local nodeType = node.type
		local nodeHint = node.hint
		self:RemoveEffect(nodeID)
		nodeGrid:Remove(nodeID, node)
		nodegraph:RemoveNode(nodeID)
	end
	function TOOL:RemoveLinksWithType(linkType)
		local count = 0
		for _, node in pairs(nodes) do
			if node.type == NODE_TYPE_HINT then continue end
			for i, link in pairs(node.link) do
				if table.HasValue(link.move, linkType) then
					nodegraph:RemoveLink(link.srcID, link.destID)
					count = count + 1
				end
			end
		end
		return count
	end
	local function ClientsideEffect(...)
		local tbEnts = ents.GetAll()
		util.Effect(...)
		return ents.GetAll()[#tbEnts +1] || NULL
	end
	function TOOL:IsNodeTypeVisible(type)
		return (type == NODE_TYPE_GROUND && cvDrawGround:GetBool()) or (type == NODE_TYPE_AIR && cvDrawAir:GetBool()) or (type == NODE_TYPE_CLIMB && cvDrawClimb:GetBool()) or (type == NODE_TYPE_HINT && cvDrawHint:GetBool())
	end
	function TOOL:PlaceAllNodesToGround()
		local pl = self:GetOwner()
		for _, node in pairs(nodes) do
			if node.type == NODE_TYPE_GROUND then
				local startPos = node.pos
				local count = 0
				if cvPNOGHull:GetBool() then
					while count < 16 do
						local trace = util.TraceHull({
							start = startPos,
							endpos = startPos,
							mins = Vector(-16, -16, 0),
							maxs = Vector(16, 16, 8),
							mask = TraceMask,
							filter = pl
						})
					
						if not trace.StartSolid then
							break
						end
					
						startPos = startPos + Vector(0, 0, 1)
						count = count + 1
					end
					local finalTrace = util.TraceHull({
						start = startPos,
						endpos = startPos,
						mins = Vector(-16, -16, 0),
						maxs = Vector(16, 16, 8),
						mask = TraceMask,
						filter = pl
					})
					if finalTrace.StartSolid then
						continue
					end
					local endPos = startPos - Vector(0, 0, 10000)
					local trace = util.TraceHull({
						start = startPos,
						endpos = endPos,
						mins = Vector(-16, -16, 0),
						maxs = Vector(16, 16, 8),
						mask = TraceMask,
						filter = pl
					})
					if trace.Hit then
						node.pos = trace.HitPos + Vector(0, 0, cvPNOGOffset:GetInt())
					end
				else
					while bit.band(util.PointContents(startPos), CONTENTS_SOLID) ~= 0 and count < 16 do
						startPos = startPos + Vector(0, 0, 1)
						count = count + 1
					end
					if bit.band(util.PointContents(startPos), CONTENTS_SOLID) ~= 0 then continue end
					local endPos = startPos - Vector(0, 0, 10000)
					local trace = util.TraceLine({
						start = startPos,
						endpos = endPos,
						mask = TraceMask,
						filter = pl
					})
					if trace.Hit then
						node.pos = trace.HitPos + Vector(0, 0, cvPNOGOffset:GetInt())
					end
				end
			end
		end
		self:BuildNodeGrid()
	end
	function TOOL:IsLineClear(a, b, forcest, forceth)
		local checkvis = cvVis:GetBool()
		if not checkvis then return true end

		if forcest == nil then forcest = cvStepCheck:GetBool() end
		if forceth == nil then forceth = cvTraceHull:GetInt() end

		local pl = self:GetOwner()
		local trLine = {start = nil, endpos = nil, mask = TraceMask, filter = pl}

		if forceth == 1 then -- Ground nodes
			if not self:TraceHullType(a, b, 1, true) then return false end
		elseif forceth == 2 then -- Air nodes
			if not self:TraceHullType(a, b, 2, false) then return false end
		else
			trLine.start = a
			trLine.endpos = b
			local tr = util.TraceLine(trLine)
			if tr.Hit then return false end
		end

		if forcest then
			local H = cvH:GetInt()
			local maxdz = cvDZ:GetInt()
			local maxi = cvDX:GetInt()

			local d1 = (b - a) / 20
			local s = a - d1

			local down100 = Vector(0, 0, -100)

			local dz = -1000
			for i = 0, maxi do
				s = s + d1
				trLine.start = s
				trLine.endpos = s + down100
				--local tr = util.TraceLine(trLine)
				local tr = util.TraceHull({
					start = trLine.start,
					endpos = trLine.endpos,
					mins = Vector(-6, -6, 0),
					maxs = Vector(6, 6, 1),
					mask = TraceMask,
					filter = pl
				})
				if not tr.Hit then return false end

				-- Slope check: inverse cosine 0.70710678 = roughly 45 degrees.
				if tr.HitNormal and tr.HitNormal.z < 0.70710678 then return false end

				local dz1
				if i == 0 or i >= maxi then
					dz1 = s.z - H
				else
					dz1 = tr.HitPos.z
				end

				if i == 0 then
					dz = dz1
				else
					local diff = dz1 - dz
					if diff < -maxdz or diff > maxdz then return false end
					dz = dz1
				end
			end
		end

		return true
	end
	local angNode = Angle(0,0,0) // TODO: Use yaw of node?
	local minNode = Vector(-30,-30,-30)
	local maxNode = Vector(30,30,30)
	function TOOL:GetTraceNode()
		local distMax = cvDist:GetInt()
		distMax = distMax * distMax
		local pl = self:GetOwner()
		local pos = pl:GetShootPos()
		local dir = pl:GetAimVector()
		local origin = self:GetPreviewOrigin()
		local nodeClosest
		local distClosest = math.huge
		local nearbyNodes = nodeGrid:Query(pos, distMax, nodes)
		for id,node in pairs(nearbyNodes) do
			if(self:IsNodeTypeVisible(node.type)) then
				local hit,norm = util.IntersectRayWithOBB(pos,dir *32768,node.pos,angNode,minNode,maxNode)
				if(hit) then
					local d = node.pos:DistToSqr(origin)
					if(d <= distMax) then
						local dPl = node.pos:DistToSqr(pos)
						if(dPl < distClosest) then
							distClosest = dPl
							nodeClosest = id
						end
					end
				end
			end
		end
		if(nodeClosest) then
			local node = nodes[nodeClosest]
			return node,nodeClosest
		end
	end
	local distMinSelect = 1600 -- 40
	local colSelected = Color(255,0,0,255)
	function TOOL:SelectNode(nodeID)
		if(self.m_selected) then
			local nodeSelected = nodes[self.m_selected]
			local eSelected = self.m_tbEffects[self.m_selected]
			if(eSelected) then eSelected:SetColor(Color(255,255,255,255)) end
		end
		local node = nodes[nodeID]
		self:ClearSelection()
		local e = self.m_tbEffects[nodeID]
		if(e) then
			e:SetColor(colSelected)
			e.m_rMin,e.m_rMax = e:GetRenderBounds()
			e:SetRenderBounds(Vector(-16384,-16384,-16384),Vector(16384,16384,16384)) // Make sure this is always rendered, so the links always show
			self.m_selected = nodeID
		end
	end
	function TOOL:ClearSelection()
		if(!self.m_selected) then return end
		local e = self.m_tbEffects[self.m_selected]
		if(e && e.m_rMin) then
			e:SetRenderBounds(e.m_rMin,e.m_rMax)
			e.m_rMin = nil
			e.m_rMax = nil
		end
		self.m_selected = nil
	end
	function TOOL:UpdateSelection(pos)
		if(!self.m_selected) then return end
		local nodeSelected = nodes[self.m_selected]
		if(!nodeSelected) then self:ClearSelection(); return end
		local eSelected = self.m_tbEffects[self.m_selected]
		if(self.m_bKeepSelection) then
			if(!self:GetOwner():KeyDown(IN_DUCK) && !self:GetOwner():KeyDown(IN_USE)) then
				self.m_bKeepSelection = nil
				if(eSelected) then eSelected.m_bKeepSelection = nil end
			else return end
		end
		local d = nodeSelected.pos:DistToSqr(pos)
		if(d > distMinSelect) then
			if(eSelected) then eSelected:SetColor(Color(255,255,255,255)) end
			self:ClearSelection()
		end
	end
	function TOOL:SolidifySelection() // Makes the selected node selected until the duck / use key has been released
		if(!self.m_selected) then return end
		self.m_bKeepSelection = true
		local eSelected = self.m_tbEffects[self.m_selected]
		if(!eSelected) then return end
		eSelected.m_bKeepSelection = true
	end
	function TOOL:RemoveEffect(nodeID)
		if(!self.m_tbEffects[nodeID]) then return end
		if(self.m_selected == nodeID) then self:ClearSelection() end
		self.m_tbEffects[nodeID].m_bRemove = true
		self.m_tbEffects[nodeID] = nil
	end
	local mat = Material("trails/laser")
	local colDefault = Color(0,255,0,255)
	local colJump = Color(0,0,255,255)
	local colArea = Color(210,30,210,255)
	local colRemove = Color(255,0,0,255)
	local colNew = Color(0,255,255,255)
	local colNewBlocked = Color(255,0,255,255)
	local offset = Vector(0,0,3)
	local DrawLinks = function(self)
		local plainLinks = cvPlainLinks:GetBool()
		local showNormalLinks = cvShowNormalLinks:GetBool()
		local showJumpLinks = cvShowJumpLinks:GetBool()
		local showFlyLinks = cvShowFlyLinks:GetBool()
		local showClimbLinks = cvShowClimbLinks:GetBool()
		local showYaw = cvShowYaw:GetBool()
		local yawVal = cvYaw:GetInt()
		local hullView = cvHullView:GetInt()

		local col = colDefault
		if !plainLinks then
			render.SetMaterial(mat)
		else
			render.SetColorMaterial()
		end
		if(self.m_tbLinks) then
			for i = 1, #self.m_tbLinks do
				local nodeLinked = self.m_tbLinks[i]
				render.DrawBeam(self:GetPos() +offset,nodeLinked.pos +offset,plainLinks and 1 or 10,0,0, (nodeLinked.type == NODE_TYPE_GROUND and colDefault) or (nodeLinked.type == NODE_TYPE_AIR and colNew) or (nodeLinked.type == NODE_TYPE_CLIMB and colNewBlocked) or colDefault)
			end
		end
		if(self.m_bPreview) then

			if(showYaw) then
				local yaw = yawVal
				local pos = self:GetPos() +Vector(0,0,30)
				colArrow.a = 255
				cam.Start3D(EyePos(),EyeAngles())
					local dir = Angle(0,yaw,0):Forward()
					render.SetMaterial(matArrow)
					cam.IgnoreZ(true)
					render.DrawBeam(pos,pos +dir *szArrow,6,1,0,colArrow)
					cam.IgnoreZ(false)
				cam.End3D()
			end
		end
		local node,nodeID = self:GetNode()
		if(!node) then return end
		local tool = GetTool()
		if(!tool) then return end
		local nodeSelected
		if(tool.m_selected) then nodeSelected = nodes[tool.m_selected] end
		local nodeTrace
		if(tool.m_traceNode) then nodeTrace = nodes[tool.m_traceNode] end
		for _,link in pairs(node.link) do
			local col
			-- Slower, but it is required to adapt with the link type feature.
			if table.HasValue(link.move, 1) then
				if not showNormalLinks then continue end
				col = colDefault
			elseif table.HasValue(link.move, 2) then
				if not showJumpLinks then continue end
				col = colJump
			elseif table.HasValue(link.move, 4) then
				if not showFlyLinks then continue end
				col = colNew
			elseif table.HasValue(link.move, 8) then
				if not showClimbLinks then continue end
				col = colNewBlocked
			end
			if link.move[hullView] == 0 then
				col = colRemove
			end
			if(tool.m_bKeepSelection) then
				if((link.src == nodeSelected || link.dest == nodeSelected) && (nodeSelected == nodeTrace || nodeTrace == link.src || nodeTrace == link.dest)) then
					if(!nodeTrace || link.src == nodeTrace || link.dest == nodeTrace) then
						col = colRemove
					end
				end
			end
			local dest = link.dest
			render.DrawBeam(node.pos +offset,dest.pos +offset,plainLinks and 1 or 10,0,0,col)
		end
		if(node == nodeSelected) then
			if(nodeTrace) then
				if(!tool:HasLink(nodeID,tool.m_traceNode)) and (tool:GetOwner():KeyDown(IN_DUCK) || tool:GetOwner():KeyDown(IN_USE))  then
					render.DrawBeam(node.pos +offset,nodeTrace.pos +offset,plainLinks and 1 or 10,0,0,colNew)
				end
			end

			if(showYaw) then
				local yaw = node.yaw
				local pos = node.pos +Vector(0,0,15)
				cam.Start3D(EyePos(),EyeAngles())
					local dir = Angle(0,yaw,0):Forward()
					render.SetMaterial(matArrow)
					cam.IgnoreZ(true)
					render.DrawBeam(pos,pos +dir *szArrow,6,1,0,colArrowSelected)
					cam.IgnoreZ(false)
				cam.End3D()
			end
		end
	end
	local DrawMassRem = function(self)
		local tool = GetTool()
		if not tool then return end
		local pos = tool:GetMassRemOrigin()
		if pos then
			render.DrawWireframeSphere(pos, cvMassRemRadius:GetInt(), 16, 16, Color(255,0,0,255), true)
		end
	end
	function TOOL:CreateEffect(nodeID)
		if(IsValid(self.m_tbEffects[nodeID])) then return end
		local node = nodes[nodeID]
		local edata = EffectData()
		if nodes[nodeID].hint and nodes[nodeID].hint ~= 0 and (node.type == NODE_TYPE_GROUND or node.type == NODE_TYPE_AIR) then
			if node.type == NODE_TYPE_GROUND then
				edata:SetMagnitude(5)
			elseif node.type == NODE_TYPE_AIR then
				edata:SetMagnitude(6)
			end
		else
			edata:SetMagnitude(node.type)
		end
		local e = ClientsideEffect("effect_node",edata)
		e:SetPos(node.pos)
		e:SetNode(node,nodeID)
		e.DrawLinks = DrawLinks
		self.m_tbEffects[nodeID] = e
	end
	local function SnapToGrid(vec,szGrid)
		if(szGrid == 0) then return vec end
		local szHalf = szGrid *0.5
		local x,y,z = vec.x,vec.y,vec.z
		if(x %szGrid < szHalf) then x = x -(x %szGrid)
		else x = x +(szGrid -(x %szGrid)) end
		if(y %szGrid < szHalf) then y = y -(y %szGrid)
		else y = y +(szGrid -(y %szGrid)) end
		if(z %szGrid < szHalf) then z = z -(z %szGrid)
		else z = z +(szGrid -(z %szGrid)) end
		return Vector(x,y,z)
	end
	function TOOL:GetPreviewOrigin()
		local pl = self:GetOwner()
		local pos = pl:GetShootPos()
		local snap = cvSnap:GetInt()
		local tr = util.TraceLine(util.GetPlayerTrace(pl))
		local createType = cvCreateType:GetInt()
		if(createType != NODE_TYPE_AIR and createType != NODE_TYPE_HINT) then
			local pos = SnapToGrid(tr.HitPos,snap)
			if(createType == NODE_TYPE_CLIMB) then
				local dir
				if(tr.Normal.x > tr.Normal.y) then dir = Vector(tr.Normal.x /math.abs(tr.Normal.x) *-1,0,0)
				else dir = Vector(0,tr.Normal.y /math.abs(tr.Normal.y) *-1,0) end
				pos = pos +Vector(0,0,8) // Slight offset for climb nodes so they can be placed at edges more easily.
			end
			return pos
		end
		local dMax = createType == NODE_TYPE_AIR and cvDistAirNode:GetInt() or cvDistHintNode:GetInt()
		local d = pos:DistToSqr(tr.HitPos)
		if(d > dMax * dMax) then return SnapToGrid(pos +tr.Normal *dMax,snap) end
		return SnapToGrid(tr.HitPos,snap)
	end
	function TOOL:GetMassRemOrigin()
		local pl = self:GetOwner()
		local tr = util.TraceLine(util.GetPlayerTrace(pl))
		return cvMassRemUsePlyrPos:GetBool() and pl:GetShootPos() or tr.HitPos
	end
	function TOOL:GetAirNodeHeightOffset(pos)
		local tr = util.TraceLine({
			start = pos,
			endpos = pos - Vector(0, 0, 10000),
			mask = TraceMask,
			filter = self:GetOwner()
		})
		if tr.Hit then
			return tr.HitPos.z + cvAirNodeHeightOffset:GetInt()
		end
		return pos.z
	end
	function TOOL:ClearEffects()
		if(self.m_tbEffects) then
			for _,e in pairs(self.m_tbEffects) do
				if(e:IsValid()) then e.m_bRemove = true end
			end
			self.m_tbEffects = nil
		end
		if(IsValid(self.m_ePreview)) then
			self.m_ePreview.m_bRemove = true
			self.m_ePreview = nil
		end
		if(IsValid(self.m_ePreviewMassRem)) then
			self.m_ePreviewMassRem.m_bRemove = true
			self.m_ePreviewMassRem = nil
		end
		self:BuildNodeGrid()
	end
	function TOOL:Holster()
		for _, v in ents.Iterator() do
			if v:GetClass() == "class CLuaEffect" and v.EffectName == "effect_node" then
				if IsValid(v) then
					v:Remove()
				end
			end
		end
		self:ClearEffects()
		self.m_deployed = false
	end
	function TOOL:IsNodeVisible(nodeID)
		local node = nodes[nodeID]
		if(!node) then return false end
		local pl = self:GetOwner()
		local pos = pl:GetShootPos()
		local dir = pl:GetAimVector()
		local hit,norm = util.IntersectRayWithOBB(pos,dir *32768,node.pos,angNode,minNode,maxNode)
		if(!hit) then return false end
		local tr = util.TraceLine({
			start = pos,
			endpos = node.pos +Vector(0,0,3),
			filter = pl,
			mask = MASK_SOLID
		})
		return tr.Fraction > 0.9
	end
	local function nodegraph_recreate_node()
		local txtnode = _R.Nodegraph.Create("nodegraph/"..game.GetMap()..".txt","DATA")
		if txtnode then
			txtnode.m_nodegraph.map_version = nodegraph.m_nodegraph.map_version
			
			nodegraph = txtnode
			nodes = nodegraph:GetNodes()
			links = nodegraph:GetLinks()
			lookup = nodegraph:GetLookupTable()
			local tool = GetTool()
			local hintFile = file.Read("nodegraph/".. game.GetMap() .. ".hint.json", "DATA")
			if hintFile then
				local hints = util.JSONToTable(hintFile)
				if hints and hints.NodeHints then
					for k, v in pairs(hints.NodeHints) do
						-- Lua tables are 1-indexed, so we need to convert the JSON table Node ID keys to 1-indexed.
						local newKey = tonumber(k) + 1
						if not nodes[newKey] then continue end
						nodes[newKey].hint = tonumber(v.HintType)
					end
				end
				if hints and hints.Hints then
					for k, v in pairs(hints.Hints) do
						local parts = string.Split(v.Position, " ")
						local pos = Vector(tonumber(parts[1]), tonumber(parts[2]), tonumber(parts[3]))
						nodegraph:AddNode(pos, NODE_TYPE_HINT, 0, 0, tonumber(v.HintType))
					end
				end
				notification.AddLegacy("Hint Nodes has been loaded from 'nodegraph/".. game.GetMap() .. ".hint.json'.",0,8)
			end
			if(tool) then
				tool:BuildNodeGrid()
				tool:BuildZone()
				tool:ClearEffects()
			end
		end
	end
	function TOOL:BuildZone()
		if not nodes then return end
		if table.Count(nodes) == 0 then return end

		for i, node in pairs(nodes) do
			if node.type ~= NODE_TYPE_HINT then
				node.zone = AI_NODE_ZONE_UNKNOWN
			end
		end
		for i, node in pairs(nodes) do
			if node.type ~= NODE_TYPE_HINT and table.Count(node.link) == 0 then
				node.zone = AI_NODE_ZONE_SOLO
			end
		end
		local curZone = AI_NODE_FIRST_ZONE
		for i, node in pairs(nodes) do
			if node.type ~= NODE_TYPE_HINT and node.zone == AI_NODE_ZONE_UNKNOWN then
				nodegraph:FloodFillZone(node, curZone)
				curZone = curZone + 1
			end
		end
		for i, node in pairs(nodes) do
			nodes[i].zone = node.zone
		end
	end
	function TOOL:OnlyKeepLargestZone(handleGround, handleAir)
		if not handleGround and not handleAir then return end
		if not nodes then return end
		if table.Count(nodes) == 0 then return end

		local count = 0

		self:BuildZone()

		if handleGround then
			local zoneCountGround = {}
			for i, node in pairs(nodes) do
				if (node.type == NODE_TYPE_GROUND) and node.zone >= AI_NODE_FIRST_ZONE then
					zoneCountGround[node.zone] = (zoneCountGround[node.zone] or 0) + 1
				end
			end
			local largestZoneGround = nil
			local largestCountGround = 0
			for zone, count in pairs(zoneCountGround) do
				if count > largestCountGround then
					largestCountGround = count
					largestZoneGround = zone
				end
			end
			if largestZoneGround then
				for i, node in pairs(nodes) do
					if (node.type == NODE_TYPE_GROUND or node.type == NODE_TYPE_CLIMB) and node.zone ~= largestZoneGround then
						self:RemoveEffect(i)
						nodeGrid:Remove(i, node)
						nodegraph:RemoveNode(i)
						count = count + 1
					end
				end
			end
		end

		if handleAir then
			local zoneCountAir = {}
			for i, node in pairs(nodes) do
				if node.type == NODE_TYPE_AIR and node.zone >= AI_NODE_FIRST_ZONE then
					zoneCountAir[node.zone] = (zoneCountAir[node.zone] or 0) + 1
				end
			end
			local largestZoneAir = nil
			local largestCountAir = 0
			for zone, count in pairs(zoneCountAir) do
				if count > largestCountAir then
					largestCountAir = count
					largestZoneAir = zone
				end
			end
			if largestZoneAir then
				for i, node in pairs(nodes) do
					if node.type == NODE_TYPE_AIR and node.zone ~= largestZoneAir then
						self:RemoveEffect(i)
						nodeGrid:Remove(i, node)
						nodegraph:RemoveNode(i)
						count = count + 1
					end
				end
			end
		end

		self:BuildNodeGrid()
		self:ClearEffects()
		return count
	end
	local function parseSelectedZones(convar)
		local listInConVar = convar:GetString()
		local tbl = {}
		for item in string.gmatch(listInConVar, '([^,]+)') do
			item = string.Trim(item)
			if item ~= "" then
				tbl[item] = true
			end
		end
		return tbl
	end
	function TOOL:DelZones(delSelected)
		local zones = parseSelectedZones(cvSelectedZones)
		if table.Count(zones) == 0 then return false end
		if not nodes or table.Count(nodes) == 0 then return false end

		for i, node in pairs(nodes) do
			if node.type == NODE_TYPE_GROUND and not cvSZGround:GetBool() then continue end
			if node.type == NODE_TYPE_AIR and not cvSZAir:GetBool() then continue end
			if node.type == NODE_TYPE_CLIMB and not cvSZClimb:GetBool() then continue end
			if node.type == NODE_TYPE_HINT and not cvSZHint:GetBool() then continue end

			local zoneMatch = zones[tostring(node.zone)]
			if (delSelected and zoneMatch) or (not delSelected and not zoneMatch) then
				self:RemoveEffect(i)
				nodeGrid:Remove(i, node)
				nodegraph:RemoveNode(i)
			end
		end

		self:BuildNodeGrid()
		self:ClearEffects()
		return true
	end
	surface.CreateFont("NEPlusFont",{
		font = "Verdana",
		extended = false,
		size = 24,
		weight = 1000,
		blursize = 0,
		scanlines = 0,
		antialias = true,
		underline = false,
		italic = false,
		strikeout = false,
		symbol = false,
		rotary = false,
		shadow = false,
		additive = false,
		outline = false,
	} )
	function TOOL:DrawToolScreen(width, height)
		surface.SetDrawColor( Color( 0, 0, 0 ) )
		surface.DrawRect( 0, 0, width, height )
		
		local nodeCount = nodegraph and nodegraph:CountNodes(nodes) or 0
		local hintCount = nodegraph and nodegraph:CountHints(nodes) or 0
		draw.SimpleText("Nodes: " .. nodeCount .. " / " .. MAX_NODES, "NEPlusFont", width / 2, 30, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		draw.SimpleText("Hints: " .. hintCount, "NEPlusFont", width / 2, 50, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		
		if self:GetOwner():KeyDown(IN_RELOAD) then
			local yOffset = height / 2 - 30

			-- Title
			draw.SimpleText("Mass Remove Mode", "NEPlusFont", width / 2, yOffset + 40, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

			-- Display radius
			draw.SimpleText("Radius: " .. cvMassRemRadius:GetInt(), "NEPlusFont", width / 2, yOffset + 60, Color(200, 200, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		elseif self.m_selected ~= nil and nodes and nodes[self.m_selected] then
			local selectedNode = nodes[self.m_selected]
			local yOffset = height / 2 - 30
			
			-- Index in table
			draw.SimpleText("Node #" .. self.m_selected, "NEPlusFont", width / 2, yOffset, Color(255, 255, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			
			-- Position
			local pos = selectedNode.pos or Vector(0, 0, 0)
			draw.SimpleText("Pos: " .. math.Round(pos.x) .. " " .. math.Round(pos.y) .. " " .. math.Round(pos.z), "NEPlusFont", width / 2, yOffset + 20, Color(200, 200, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

			-- Yaw
			local yaw = selectedNode.yaw or 0
			draw.SimpleText("Yaw: " .. math.Round(yaw), "NEPlusFont", width / 2, yOffset + 40, Color(200, 200, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

			-- Type
			local nodeType = (selectedNode.type == 2 and "Ground") or (selectedNode.type == 3 and "Air") or (selectedNode.type == 4 and "Climb") or (selectedNode.type == 7 and "Hint") or "Unknown"
			draw.SimpleText("Type: " .. nodeType, "NEPlusFont", width / 2, yOffset + 60, Color(200, 200, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			
			-- Zone
			local nodeZone = selectedNode.zone < 4 and "N/A" or selectedNode.zone or "N/A"
			draw.SimpleText("Zone: " .. nodeZone, "NEPlusFont", width / 2, yOffset + 80, Color(200, 200, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
			
			-- Hint
			local nodeHint = selectedNode.hint == 0 and "None" or selectedNode.hint or "None"
			draw.SimpleText("Hint: " .. nodeHint, "NEPlusFont", width / 2, yOffset + 100, Color(200, 200, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

			-- Current hull offset
			local nodeOffset = selectedNode.offset[cvHullView:GetInt()] or 0
			draw.SimpleText("Hull Offset: " .. math.Round(nodeOffset, 2), "NEPlusFont", width / 2, yOffset + 120, Color(200, 200, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end
	end
	function TOOL:Think()
	
		local delay = cvThinkDelay:GetFloat()

		if not self.NextThinkTime then
			self.NextThinkTime = CurTime()
		end

		if CurTime() >= self.NextThinkTime then
			cl_tool_object = self
			if(!self.m_tbEffects) then
				self.m_tbEffects = {}
				local edata = EffectData()
				edata:SetMagnitude(NODE_TYPE_GROUND)
				self.m_ePreview = ClientsideEffect("effect_node",edata)
				self.m_ePreview.m_bPreview = true
				self.m_ePreview.DrawLinks = DrawLinks
				self.m_ePreviewMassRem = ClientsideEffect("effect_node",edata)
				self.m_ePreviewMassRem.DrawMassRem = DrawMassRem
				if(!nodes) then
					self:GetMapVersion()
					nodegraph = _R.Nodegraph.Read()
					nodes = nodegraph:GetNodes()
					links = nodegraph:GetLinks()
					lookup = nodegraph:GetLookupTable()
					self:GetBuiltInHints()
					local hintFile = 
						file.Read("map_hints/" .. game.GetMap() .. ".json", "DATA") or
						file.Read("data_static/map_hints/" .. game.GetMap() .. ".json", "GAME") or
						file.Read("maps/graphs/" .. game.GetMap() .. ".hint.json", "GAME")
					if hintFile then
						local loadedHints = 0
						local hints = util.JSONToTable(hintFile)
						if hints and hints.NodeHints then
							for k, v in pairs(hints.NodeHints) do
								-- Lua tables are 1-indexed, so we need to convert the JSON table Node ID keys to 1-indexed.
								local newKey = tonumber(k) + 1
								if not nodes[newKey] then continue end
								nodes[newKey].hint = tonumber(v.HintType)
								loadedHints = loadedHints + 1
							end
						end
						if hints and hints.Hints then
							for k, v in pairs(hints.Hints) do
								local parts = string.Split(v.Position, " ")
								local pos = Vector(tonumber(parts[1]), tonumber(parts[2]), tonumber(parts[3]))
								nodegraph:AddNode(pos, NODE_TYPE_HINT, 0, 0, tonumber(v.HintType))
								loadedHints = loadedHints + 1
							end
						end
						if loadedHints > 0 then
							notification.AddLegacy(loadedHints .. " Hint Nodes has been loaded from JSON.",0,8)
						else
							notification.AddLegacy("Failed to load Hint Nodes from JSON.",1,8)
							notification.AddLegacy("The JSON is either wrong format or empty.",0,8)
						end
					else
						timer.Simple(0.1, function()
							local loadedHints = 0
							for i = 1, #hintData do
								local data = hintData[i]
								if not data.IsInfoHint then
									local lookupID = tonumber(data.NodeID)
									for k, v in pairs(lookup) do
										if v == lookupID then
											if nodes[k] then
												nodes[k].hint = tonumber(data.HintType) or 0
												loadedHints = loadedHints + 1
											end
											break
										end
									end
								else
									local parts = string.Split(data.Position, " ")
									local pos = Vector(tonumber(parts[1]), tonumber(parts[2]), tonumber(parts[3]))
									nodegraph:AddNode(pos, NODE_TYPE_HINT, 0, 0, tonumber(data.HintType) or 0)
									loadedHints = loadedHints + 1
								end
							end
							if loadedHints > 0 then
								self:ClearEffects()
								notification.AddLegacy(loadedHints .. " Hint Nodes has been loaded from the map.",0,8)
							end
						end)
					end
				end
				self:BuildNodeGrid()
				self:BuildZone()
				ShowMapWarning()
			end
			if not nodeGrid then self:BuildNodeGrid() end
			local distMax = cvDist:GetInt()
			local distMaxP = distMax * distMax
			local pl = self:GetOwner()
			local pos = pl:GetShootPos()
			local origin = self:GetPreviewOrigin()
			local massRemOrigin = self:GetMassRemOrigin()
			local h=cvH:GetInt()
			local createType = cvCreateType:GetInt()
			if createType == NODE_TYPE_GROUND then
				origin[3]=origin[3]+h
			end
			if createType == NODE_TYPE_AIR and cvAirNodeHeightOffsetEnable:GetBool() then
				origin[3]=self:GetAirNodeHeightOffset(origin)
			end
			if cvHint:GetInt() ~= 0 and (createType == NODE_TYPE_GROUND or createType == NODE_TYPE_AIR) then
				if createType == NODE_TYPE_GROUND then
					self.m_ePreview:SetType(5)
				elseif createType == NODE_TYPE_AIR then
					self.m_ePreview:SetType(6)
				end
			else
				self.m_ePreview:SetType(createType)
			end
			self.m_ePreview:SetPos(origin)
			self.m_ePreview:SetNoDraw((!cvDrawPreview:GetBool() || self.m_selected) && true || false)
			self.m_ePreview:ClearLinks()
			self.m_ePreviewMassRem:SetPos(massRemOrigin)
			self.m_ePreviewMassRem:SetNoDraw(not pl:KeyDown(IN_RELOAD))
			self:UpdateSelection(origin)
			local dir = pl:GetAimVector()
			local distMinLink = cvDistLink:GetInt()
			distMinLink = distMinLink * distMinLink
			self.m_traceNode = nil
			local nodesInRay = {}
			local isNodeProjection = cvNodeProjection:GetBool()
			local isTraceHull = cvTraceHull:GetBool()
			local nodeRadius = cvNodeRadius:GetInt()
			local queryUsingPlayerPos = cvRenderUsingPlayerPos:GetBool() and pos or origin
			local nodesToProcess = nodeGrid:Query(queryUsingPlayerPos, distMax, nodes)
			if self.m_tbEffects then
				for id, _ in pairs(self.m_tbEffects) do
					if id ~= self.m_selected and not nodesToProcess[id] then
						self:RemoveEffect(id)
					end
				end
			end
			for nodeID, node in pairs(nodesToProcess) do
				if(!self:IsNodeTypeVisible(node.type)) then self:RemoveEffect(nodeID)
				else
					local hit,norm = util.IntersectRayWithOBB(pos,dir *32768,node.pos,angNode,minNode,maxNode)
					if(hit) then
						local d = node.pos:DistToSqr(origin)
						hit = d <= distMaxP
					end
					if(hit) then self.m_traceNode = nodeID end
					if(hit && !self.m_bKeepSelection && self.m_tbEffects[nodeID] && self:IsNodeVisible(nodeID)) then table.insert(nodesInRay,nodeID)
					else
						self:CreateEffect(nodeID)
						if cvDrawPreview:GetBool() then
							if node.pos:DistToSqr(origin) <= distMinLink then
								if node.type == createType and createType ~= NODE_TYPE_CLIMB and createType ~= NODE_TYPE_HINT then
									if node.type ~= NODE_TYPE_AIR and createType ~= NODE_TYPE_AIR then
										if self:IsLineClear(origin, node.pos) then
											if isNodeProjection then
												local obstructed = false
												local midPoint = origin + (node.pos - origin) * 0.5
												local checkRadius = (origin - midPoint):Length() + nodeRadius
												local obstructionCandidates = nodeGrid:Query(midPoint, checkRadius, nodes)
												for k, nodeB in pairs(obstructionCandidates) do
													if k ~= nodeID and nodeB.pos ~= origin and nodeB.type == createType then
														if IsNodeBetween(origin, nodeB.pos, node.pos, nodeRadius) then
															obstructed = true
															break
														end
													end
												end
												if not obstructed then
													self.m_ePreview:AddLink(node)
												end
											else
												self.m_ePreview:AddLink(node)
											end
										end
									else
										if self:IsLineClear(origin, node.pos,false,isTraceHull and 2 or 0) then
											if isNodeProjection then
												local obstructed = false
												local midPoint = origin + (node.pos - origin) * 0.5
												local checkRadius = (origin - midPoint):Length() + nodeRadius
												local obstructionCandidates = nodeGrid:Query(midPoint, checkRadius, nodes)
												for k, nodeB in pairs(obstructionCandidates) do
													if k ~= nodeID and nodeB.pos ~= origin and nodeB.type == createType then
															if IsNodeBetween(origin, nodeB.pos, node.pos, nodeRadius) then
															obstructed = true
															break
														end
													end
												end
												if not obstructed then
													self.m_ePreview:AddLink(node)
												end
											else
												self.m_ePreview:AddLink(node)
											end
										end
									end
								end
							end
						end
					end
				end
			end
			local nodeClosest
			local nodeClosestType
			local distClosest = math.huge
			for i = 1, #nodesInRay do
				local nodeID = nodesInRay[i]
				local node = nodes[nodeID]
				local d = node.pos:DistToSqr(pos)
				if(d < distClosest) then
					if (cvDontSelDiffNode:GetBool() and node.type ~= createType) then
						continue
					end
					distClosest = d
					nodeClosest = nodeID
				end
			end
			if(nodeClosest) then self:SelectNode(nodeClosest) end
			self.NextThinkTime = CurTime() + delay
    	end
	end
	function TOOL.BuildCPanel(pnl)
		pnl:AddControl("Header",{Text = "Nodegraph Editor+",Description = [[
		Left click to place/remove a node at your crosshair.
		Right click to place a node at your position.
		Hold reload and left click to remove nodes in radius.
		Hold reload and scroll to change mass remove radius.
		Hold use or crouch and right click on a node to assign a hint to it.
		Hold use or crouch and click a node to enter link edit:
		- Click same node again to clear links.
		- Click linked node to remove link.
		- Click unlinked node to create link.
		]]})

		local selected1 = cvCreateType:GetInt()
		local lbl1 = vgui.Create("DLabel",pnl)
		lbl1:SetColor(Color(0,0,0,255))
		lbl1:SetText("Node Type:")
		local pCBox1 = vgui.Create("DComboBox",pnl)
		pCBox1:SetSortItems(false)
		pCBox1:AddChoice("1. Ground Node",NODE_TYPE_GROUND,selected1 == NODE_TYPE_GROUND)
		pCBox1:AddChoice("2. Air Node",NODE_TYPE_AIR,selected1 == NODE_TYPE_AIR)
		pCBox1:AddChoice("3. Climb Node",NODE_TYPE_CLIMB,selected1 == NODE_TYPE_CLIMB)
		pCBox1:AddChoice("4. Hint Node",NODE_TYPE_HINT,selected1 == NODE_TYPE_HINT)
		pCBox1.OnSelect = function(pCBox1,idx,val,data) RunConsoleCommand("cl_nodegraph_tool_node_type",data) end
		pCBox1:SetWide(170)
		pnl:AddItem(lbl1,pCBox1)

		local selected = cvJumpLink:GetInt()
		local lbl = vgui.Create("DLabel",pnl)
		lbl:SetColor(Color(0,0,0,255))
		lbl:SetText("Link Edit Mode:")
		local pCBox = vgui.Create("DComboBox",pnl)
		pCBox:SetSortItems(false)
		pCBox:AddChoice("1. Normal",0,selected == 0)
		pCBox:AddChoice("2. Jump",1,selected == 1)
		pCBox.OnSelect = function(pCBox,idx,val,data) RunConsoleCommand("cl_nodegraph_tool_jump_link",data) end
		pCBox:SetWide(170)
		pnl:AddItem(lbl,pCBox)

		local selected2 = cvHint:GetInt()
		local lbl2 = vgui.Create("DLabel",pnl)
		lbl2:SetColor(Color(0,0,0,255))
		lbl2:SetText("Node Hint:")
		local pCBox2 = vgui.Create("DComboBox",pnl)
		pCBox2:SetSortItems(false)
		pCBox2:AddChoice("1. None (0)", 0, selected2 == 0)
		pCBox2:AddChoice("2. World: Window (2)", 2, selected2 == 2)
		pCBox2:AddChoice("3. World: Act Busy Hint (12)", 12, selected2 == 12)
		pCBox2:AddChoice("4. World: Visually Interesting (13)", 13, selected2 == 13)
		pCBox2:AddChoice("5. World: Visually Interesting (Don't aim at) (14)", 14, selected2 == 14)
		pCBox2:AddChoice("6. World: Inhibit Combine Mines within 15 feet (15)", 15, selected2 == 15)
		pCBox2:AddChoice("7. World: Visually Interesting (Stealth mode) (16)", 16, selected2 == 16)
		pCBox2:AddChoice("8. Crouch Cover Medium (100)", 100, selected2 == 100)
		pCBox2:AddChoice("9. Crouch Cover Low (101)", 101, selected2 == 101)
		pCBox2:AddChoice("10. Waste Scanner Spawn (102)", 102, selected2 == 102)
		pCBox2:AddChoice("11. Entrance / Exit Pinch (103)", 103, selected2 == 103)
		pCBox2:AddChoice("12. Enemy Disadvantage Point (105)", 105, selected2 == 105)
		pCBox2:AddChoice("13. Health Kit (106)", 106, selected2 == 106)
		pCBox2:AddChoice("14. Antlion: Burrow Point (400)", 400, selected2 == 400)
		pCBox2:AddChoice("15. Antlion: Thumper Flee Point (401)", 401, selected2 == 401)
		pCBox2:AddChoice("16. Headcrab: Burrow Point (450)", 450, selected2 == 450)
		pCBox2:AddChoice("17. Headcrab: Exit Pod Point (451)", 451, selected2 == 451)
		pCBox2:AddChoice("18. Roller: Patrol Point (500)", 500, selected2 == 500)
		pCBox2:AddChoice("19. Roller: Cleanup Spot (501)", 501, selected2 == 501)
		pCBox2:AddChoice("20. Crow: Fly to point (700)", 700, selected2 == 700)
		pCBox2:AddChoice("21. Crow: Perch point (701)", 701, selected2 == 701)
		pCBox2:AddChoice("22. Follower: Wait point (900)", 900, selected2 == 900)
		pCBox2:AddChoice("23. Override jump permission (901)", 901, selected2 == 901)
		pCBox2:AddChoice("24. Player squad transition point (902)", 902, selected2 == 902)
		pCBox2:AddChoice("25. NPC exit point (903)", 903, selected2 == 903)
		pCBox2:AddChoice("26. Strider node (904)", 904, selected2 == 904)
		pCBox2:AddChoice("27. Player Ally: Push away destination (950)", 950, selected2 == 950)
		pCBox2:AddChoice("28. Player Ally: Fear withdrawal destination (951)", 951, selected2 == 951)
		pCBox2:AddChoice("29. HL1 World: Machinery (1000)", 1000, selected2 == 1000)
		pCBox2:AddChoice("30. HL1 World: Blinking Light (1001)", 1001, selected2 == 1001)
		pCBox2:AddChoice("31. HL1 World: Human Blood (1002)", 1002, selected2 == 1002)
		pCBox2:AddChoice("32. HL1 World: Alien Blood (1003)", 1003, selected2 == 1003)
		pCBox2.OnSelect = function(pCBox2,idx,val,data) RunConsoleCommand("cl_nodegraph_tool_node_hint",data) end
		pCBox2:SetWide(170)
		pnl:AddItem(lbl2,pCBox2)

		local selected3 = cvHullView:GetInt()
		local lbl3 = vgui.Create("DLabel",pnl)
		lbl3:SetColor(Color(0,0,0,255))
		lbl3:SetText("Hull View:")
		local pCBox3 = vgui.Create("DComboBox",pnl)
		pCBox3:SetSortItems(false)
		pCBox3:AddChoice("1. HUMAN", 1, selected3 == 1)
		pCBox3:AddChoice("2. SMALL_CENTERED", 2, selected3 == 2)
		pCBox3:AddChoice("3. WIDE_HUMAN", 3, selected3 == 3)
		pCBox3:AddChoice("4. TINY", 4, selected3 == 4)
		pCBox3:AddChoice("5. WIDE_SHORT", 5, selected3 == 5)
		pCBox3:AddChoice("6. MEDIUM", 6, selected3 == 6)
		pCBox3:AddChoice("7. TINY_CENTERED", 7, selected3 == 7)
		pCBox3:AddChoice("8. LARGE", 8, selected3 == 8)
		pCBox3:AddChoice("9. LARGE_CENTERED", 9, selected3 == 9)
		pCBox3:AddChoice("10. MEDIUM_TALL", 10, selected3 == 10)
		pCBox3.OnSelect = function(pCBox3,idx,val,data) RunConsoleCommand("cl_nodegraph_tool_hulltype_view",data) end
		pCBox3:SetWide(170)
		pnl:AddItem(lbl3,pCBox3)

		local selected = TraceMask
		local lbl = vgui.Create("DLabel",pnl)
		lbl:SetColor(Color(0,0,0,255))
		lbl:SetText("Trace Mask:")
		local pCBox = vgui.Create("DComboBox",pnl)
		pCBox:SetSortItems(false)
		pCBox:AddChoice("1. NPCWORLDSTATIC", MASK_NPCWORLDSTATIC, selected == MASK_NPCWORLDSTATIC)
		pCBox:AddChoice("2. NPCSOLID", MASK_NPCSOLID, selected == MASK_NPCSOLID)
		pCBox:AddChoice("3. NPCSOLID_BRUSHONLY", MASK_NPCSOLID_BRUSHONLY, selected == MASK_NPCSOLID_BRUSHONLY)
		pCBox:AddChoice("4. PLAYERSOLID", MASK_PLAYERSOLID, selected == MASK_PLAYERSOLID)
		pCBox:AddChoice("5. PLAYERSOLID_BRUSHONLY", MASK_PLAYERSOLID_BRUSHONLY, selected == MASK_PLAYERSOLID_BRUSHONLY)
		pCBox:AddChoice("6. SOLID", MASK_SOLID, selected == MASK_SOLID)
		pCBox:AddChoice("7. SOLID_BRUSHONLY", MASK_SOLID_BRUSHONLY, selected == MASK_SOLID_BRUSHONLY)
		pCBox.OnSelect = function(pCBox,idx,val,data) TraceMask = data end
		pCBox:SetWide(170)
		pnl:AddItem(lbl,pCBox)

		pnl:AddControl("Slider",{type = "float",min = 0,max = 1,label = "Think Delay",Command = "cl_nodegraph_tool_think_delay"})
		pnl:AddControl("CheckBox",{Label = "Show Node Preview",Command = "cl_nodegraph_tool_draw_preview"})
		pnl:AddControl("CheckBox",{Label = "Show Ground Nodes",Command = "cl_nodegraph_tool_nodes_draw_ground"})
		pnl:AddControl("CheckBox",{Label = "Show Air Nodes",Command = "cl_nodegraph_tool_nodes_draw_air"})
		pnl:AddControl("CheckBox",{Label = "Show Climb Nodes",Command = "cl_nodegraph_tool_nodes_draw_climb"})
		pnl:AddControl("CheckBox",{Label = "Show Hint Nodes",Command = "cl_nodegraph_tool_nodes_draw_hint"})
		pnl:AddControl("CheckBox",{Label = "Show Normal Links",Command = "cl_nodegraph_tool_show_normal_links"})
		pnl:AddControl("CheckBox",{Label = "Show Jump Links",Command = "cl_nodegraph_tool_show_jump_links"})
		pnl:AddControl("CheckBox",{Label = "Show Fly Links",Command = "cl_nodegraph_tool_show_fly_links"})
		pnl:AddControl("CheckBox",{Label = "Show Climb Links",Command = "cl_nodegraph_tool_show_climb_links"})
		pnl:AddControl("CheckBox",{Label = "Fullbright Nodes",Command = "cl_nodegraph_tool_fullbright"})
		pnl:AddControl("CheckBox",{Label = "Plain Node Textures",Command = "cl_nodegraph_tool_plain_nodes"})
		pnl:AddControl("CheckBox",{Label = "Plain Link Textures",Command = "cl_nodegraph_tool_plain_links"})
		pnl:AddControl("CheckBox",{Label = "Always Render on Top",Command = "cl_nodegraph_tool_ignorez"})
		pnl:AddControl("CheckBox",{Label = "Render Using Player Position",Command = "cl_nodegraph_tool_render_using_player_pos"})

		local values = {0,1,2,4,8,16,32,64,128,256,512}
		local snap = cvSnap:GetInt()
		local pContainer = vgui.Create("DPanel", pnl)
		pContainer:SetTall(32)
		pContainer:SetPaintBackground(false)
		local lbl = vgui.Create("DLabel", pContainer)
		lbl:SetText("Snap to grid:")
		lbl:SetDark(true)
		lbl:SizeToContents()
		lbl:Dock(LEFT)
		lbl:DockMargin(0, 0, 8, 0)
		local slider = vgui.Create("DSlider", pContainer)
		slider:SetLockY(0.5)
		slider:SetTrapInside(true)
		slider:Dock(FILL)
		slider:SetHeight(16)
		Derma_Hook(slider, "Paint", "Paint", "NumSlider")
		local wang = vgui.Create("DLabel", pContainer)
		wang:SetText(snap)
		wang:SetContentAlignment(5)
		wang:SetDark(true)
		wang:Dock(RIGHT)
		wang:SetWidth(20)
		local i
		for _ = 1, #values do local val = values[_] if(val == snap) then i = _; break end end
		if(i) then slider:SetSlideX((i - 1) / (#values - 1)) end
		slider.TranslateValues = function(_, x, y)
			local num = tonumber(x * (#values - 1) + 1) or 0
			num = math.Round(num)
			local val = math.Clamp(num, 1, #values)
			wang:SetText(values[val])
			RunConsoleCommand("cl_nodegraph_tool_snap", values[val])
			return ((num - 1) / (#values - 1)), y
		end
		pnl:AddItem(pContainer)
		
		pnl:AddControl("Slider",{type = "int",min = 0,max = 4000,label = "Draw Distance",Command = "cl_nodegraph_tool_draw_distance"})
		pnl:AddControl("Slider",{type = "int",min = 0,max = 1000,label = "Air Node Distance",Command = "cl_nodegraph_tool_airnode_distance"})
		pnl:AddControl("Slider",{type = "int",min = 0,max = 1000,label = "Hint Node Distance",Command = "cl_nodegraph_tool_hintnode_distance"})
		pnl:AddControl("Slider",{type = "int",min = 0,max = 16,label = "Ground Offset Z",Command = "cl_nodegraph_tool_node_z"})
		pnl:AddControl("Slider",{type = "int",min = 64,max = 1024,label = "Air Offset Z",Command = "cl_nodegraph_tool_node_air_z"})
		pnl:AddControl("Slider",{type = "int",min = 0,max = 16,label = "Snap Ground Offset Z",Command = "cl_nodegraph_tool_place_node_on_ground_offset"})
		pnl:AddControl("Slider",{type = "int",min = 0,max = 720,label = "Max Link Distance",Command = "cl_nodegraph_tool_max_link_distance"})
		pnl:AddControl("Slider",{type = "int",min = 0,max = 360,label = "Yaw",Command = "cl_nodegraph_tool_yaw"})
		pnl:AddControl("CheckBox",{Label = "Show Yaw Arrow",Command = "cl_nodegraph_tool_nodes_show_yaw"})
		pnl:AddControl("CheckBox",{Label = "Auto Adjust Yaw for Climb Nodes",Command = "cl_nodegraph_tool_yaw_auto"})
		pnl:AddControl("CheckBox",{Label = "Check Link Visibility",Command = "cl_nodegraph_tool_check_visibility"})
		pnl:AddControl("CheckBox",{Label = "Enable Step Check (Slow)",Command = "cl_nodegraph_tool_stepcheck_enable"})
		pnl:AddControl("CheckBox",{Label = "Enable Node Projection (Slow)",Command = "cl_nodegraph_tool_nodeproj_enable"})
		pnl:AddControl("CheckBox",{Label = "Use Bounding Box for Link Visibility",Command = "cl_nodegraph_tool_use_tracehull"})
		pnl:AddControl("CheckBox",{Label = "Snap Node to Ground",Command = "cl_nodegraph_tool_place_node_on_ground"})
		pnl:AddControl("CheckBox",{Label = "Use Bounding Box for Snap Node to Ground",Command = "cl_nodegraph_tool_place_node_on_ground_hull"})
		pnl:AddControl("CheckBox",{Label = "Undo-able Nodes",Command = "cl_nodegraph_tool_undoable_nodes"})
		pnl:AddControl("CheckBox",{Label = "Don't Select Different Node Type",Command = "cl_nodegraph_tool_dont_select_diff_node_type"})
		pnl:AddControl("CheckBox",{Label = "Use Air Node Height Offset",Command = "cl_nodegraph_tool_node_air_z_enable"})

		pnl:AddControl("Label",{Text = "  "})
		pnl:AddControl("Label",{Text = "Mass Remove Settings"})
		pnl:AddControl("Slider",{type = "int",min = 1,max = 1024,label = "Mass Remove Radius",Command = "cl_nodegraph_tool_massrem_radius"})
		pnl:AddControl("CheckBox",{Label = "Use Player Position",Command = "cl_nodegraph_tool_massrem_useplyrpos"})
		pnl:AddControl("CheckBox",{Label = "Remove Ground Nodes",Command = "cl_nodegraph_tool_massrem_grndnds"})
		pnl:AddControl("CheckBox",{Label = "Remove Air Nodes",Command = "cl_nodegraph_tool_massrem_airnds"})
		pnl:AddControl("CheckBox",{Label = "Remove Climb Nodes",Command = "cl_nodegraph_tool_massrem_climbnds"})
		pnl:AddControl("CheckBox",{Label = "Remove Hint Nodes",Command = "cl_nodegraph_tool_massrem_hintnds"})

		pnl:AddControl("Label",{Text = "  "})
		pnl:AddControl("Label",{Text = "Link Hull Types"})
		local selected = cvHullAuto:GetInt()
		local lbl = vgui.Create("DLabel",pnl)
		lbl:SetColor(Color(0,0,0,255))
		lbl:SetText("Method:")
		local pCBox = vgui.Create("DComboBox",pnl)
		pCBox:SetSortItems(false)
		pCBox:AddChoice("1. Manual",0,selected == 0)
		pCBox:AddChoice("2. Auto",1,selected == 1)
		pCBox.OnSelect = function(pCBox,idx,val,data) RunConsoleCommand("cl_nodegraph_tool_hulltype_auto",data) end
		pCBox:SetWide(170)
		pnl:AddItem(lbl,pCBox)
		pnl:AddControl("CheckBox",{Label = "HUMAN",Command = "cl_nodegraph_tool_hulltype_1"})
		pnl:AddControl("CheckBox", {Label = "SMALL_CENTERED", Command = "cl_nodegraph_tool_hulltype_2"})
		pnl:AddControl("CheckBox", {Label = "WIDE_HUMAN", Command = "cl_nodegraph_tool_hulltype_3"})
		pnl:AddControl("CheckBox", {Label = "TINY", Command = "cl_nodegraph_tool_hulltype_4"})
		pnl:AddControl("CheckBox", {Label = "WIDE_SHORT", Command = "cl_nodegraph_tool_hulltype_5"})
		pnl:AddControl("CheckBox", {Label = "MEDIUM", Command = "cl_nodegraph_tool_hulltype_6"})
		pnl:AddControl("CheckBox", {Label = "TINY_CENTERED", Command = "cl_nodegraph_tool_hulltype_7"})
		pnl:AddControl("CheckBox", {Label = "LARGE", Command = "cl_nodegraph_tool_hulltype_8"})
		pnl:AddControl("CheckBox", {Label = "LARGE_CENTERED", Command = "cl_nodegraph_tool_hulltype_9"})
		pnl:AddControl("CheckBox", {Label = "MEDIUM_TALL", Command = "cl_nodegraph_tool_hulltype_10"})

		pnl:AddControl("Label",{Text = "  "})
		pnl:AddControl("Label",{Text = "Main Functions"})
		local pNoDoor = vgui.Create("DButton",pnl)
		pNoDoor:SetText("Remove All Doors")
		local clicktime = 0
		pNoDoor.DoClick = function(pNoDoor)
			cl_testdoor()
		end
		pNoDoor:SetWide(110)
		pnl:AddItem(pNoDoor)

		local pSave = vgui.Create("DButton",pnl)
		pSave:SetText("Save Nodegraph as AIN")
		pSave.DoClick = function(pSave)
			local tool = GetTool()
			if(!tool) then return end
			nodegraph.m_nodegraph.map_version = updatedMapVersion or nodegraph.m_nodegraph.map_version
			tool:AdjustNodeOffsets()
			nodegraph:Save()
			notification.AddLegacy("Nodegraph has been saved as 'data/nodegraph/" .. game.GetMap() .. ".txt'.",0,8)
			if file.Exists("data/nodegraph/" .. game.GetMap() .. ".hint.json", "GAME") then
				notification.AddLegacy("Hint Nodes has been saved as 'data/nodegraph/" .. game.GetMap() .. ".hint.json'.",0,8)
			end
			--ShowFirstTimeNotification()
			notification.AddLegacy("Successfully saved Nodegraph as AIN.",0,8)
			if(tool) then tool:ClearEffects() end
		end
		pSave:SetWide(110)
		pnl:AddItem(pSave)

		local pSaveENT = vgui.Create("DButton",pnl)
		pSaveENT:SetText("Save Nodegraph as ENT")
		pSaveENT.DoClick = function(pSaveENT)
			local tool = GetTool()
			if(!tool) then return end
			nodegraph:SaveAsENT()
			notification.AddLegacy("Nodegraph has been saved as 'data/nodegraph/" .. game.GetMap() .. ".ent.txt'.",0,8)
			notification.AddLegacy("Successfully saved Nodegraph as ENT.",0,8)
			if(tool) then tool:ClearEffects() end
		end
		pSaveENT:SetWide(110)
		pnl:AddItem(pSaveENT)

		local pSaveVMF = vgui.Create("DButton",pnl)
		pSaveVMF:SetText("Save Nodegraph to VMF")
		pSaveVMF.DoClick = function(pSaveVMF)
			local tool = GetTool()
			if(!tool) then return end
			if not file.Exists("data/nodegraph/" .. game.GetMap() .. ".vmf", "GAME") then
				notification.AddLegacy("Place the VMF file for this map as 'data/nodegraph/" .. game.GetMap() .. ".vmf'.",0,8)
				notification.AddLegacy("The map's VMF file can't be found!",1,8)
				return
			end
			nodegraph:SaveToVMF()
			notification.AddLegacy("Nodegraph has been saved to 'data/nodegraph/" .. game.GetMap() .. ".vmf.txt'.",0,8)
			notification.AddLegacy("Successfully saved Nodegraph to VMF.")
			if(tool) then tool:ClearEffects() end
		end
		pSaveVMF:SetWide(110)
		pnl:AddItem(pSaveVMF)

		local pNodeOnGround = vgui.Create("DButton",pnl)
		pNodeOnGround:SetText("Snap All Nodes to Ground")
		pNodeOnGround.DoClick = function(pNodeOnGround)
			local tool = GetTool()
			if(!tool) then return end
			tool:PlaceAllNodesToGround()
			if(tool) then tool:ClearEffects() end
			notification.AddLegacy("Snapped all nodes position to the ground.",0,8)
		end
		pNodeOnGround:SetWide(110)
		pnl:AddItem(pNodeOnGround)

		local pCleanLinks = vgui.Create("DButton",pnl)
		pCleanLinks:SetText("Clean Nodegraph Links")
		pCleanLinks.DoClick = function(pCleanLinks)
			local tool = GetTool()
			if(!tool) then return end
			local count = tool:CleanNodegraphLinks()
			if(count > 0) then
				tool:ClearEffects()
				notification.AddLegacy("Removed " .. count .. " obstructed links.",0,8)
			else
				notification.AddLegacy("No obstructed links found.",0,8)
			end
		end
		pCleanLinks:SetWide(110)
		pnl:AddItem(pCleanLinks)

		local pRestore = vgui.Create("DButton",pnl)
		pRestore:SetText("Restore Nodegraph")
		pRestore.DoClick = function(pRestore)
			local tool = GetTool()
			if(!tool) then return end
			if(tool) then tool:ClearEffects() end
			nodegraph = _R.Nodegraph.Read()
			nodes = nodegraph:GetNodes()
			links = nodegraph:GetLinks()
			lookup = nodegraph:GetLookupTable()
			tool:GetBuiltInHints()
			local hintFile =
				file.Read("map_hints/" .. game.GetMap() .. ".json", "DATA") or
				file.Read("data_static/map_hints/" .. game.GetMap() .. ".json", "GAME") or
				file.Read("maps/graphs/" .. game.GetMap() .. ".hint.json", "GAME")
			if hintFile then
				local loadedHints = 0
				local hints = util.JSONToTable(hintFile)
				if hints and hints.NodeHints then
					for k, v in pairs(hints.NodeHints) do
						-- Lua tables are 1-indexed, so we need to convert the JSON table Node ID keys to 1-indexed.
						local newKey = tonumber(k) + 1
						if not nodes[newKey] then continue end
						nodes[newKey].hint = tonumber(v.HintType)
						loadedHints = loadedHints + 1
					end
				end
				if hints and hints.Hints then
					for k, v in pairs(hints.Hints) do
						local parts = string.Split(v.Position, " ")
						local pos = Vector(tonumber(parts[1]), tonumber(parts[2]), tonumber(parts[3]))
						nodegraph:AddNode(pos, NODE_TYPE_HINT, 0, 0, tonumber(v.HintType))
						loadedHints = loadedHints + 1
					end
				end
				if loadedHints > 0 then
					notification.AddLegacy(loadedHints .. " Hint Nodes has been loaded from JSON.",0,8)
				else
					notification.AddLegacy("The JSON is either wrong format or empty.",0,8)
					notification.AddLegacy("Failed to load Hint Nodes from JSON.",1,8)
				end
			else
				timer.Simple(0.1, function()
					local loadedHints = 0
					for i = 1, #hintData do
						local data = hintData[i]
						if not data.IsInfoHint then
							local lookupID = tonumber(data.NodeID)
							for k, v in pairs(lookup) do
								if v == lookupID then
									if nodes[k] then
										nodes[k].hint = tonumber(data.HintType) or 0
										loadedHints = loadedHints + 1
									end
									break
								end
							end
						else
							local parts = string.Split(data.Position, " ")
							local pos = Vector(tonumber(parts[1]), tonumber(parts[2]), tonumber(parts[3]))
							nodegraph:AddNode(pos, NODE_TYPE_HINT, 0, 0, tonumber(data.HintType) or 0)
							loadedHints = loadedHints + 1
						end
					end
					if loadedHints > 0 then
						tool:ClearEffects()
						notification.AddLegacy(loadedHints .. " Hint Nodes has been loaded from the map.",0,8)
					end
				end)
			end
			tool:BuildNodeGrid()
			tool:BuildZone()
			notification.AddLegacy("Nodegraph has been restored.",0,8)
		end
		pRestore:SetWide(110)
		pnl:AddItem(pRestore)
	
		local pRecreate = vgui.Create("DButton",pnl)
		pRecreate:SetText("Recreate Nodegraph from TXT")
		pRecreate.DoClick = function(pRecreate)
			local tool = GetTool()
			if(!tool) then return end

			if not file.Exists("data/nodegraph/" .. game.GetMap() .. ".txt", "GAME") then
				notification.AddLegacy("Put your nodegraph .txt into 'data/nodegraph/" .. game.GetMap() .. ".txt'.",0,8)
				notification.AddLegacy("Nodegraph TXT file not found.",1,8)
				return
			end

			nodegraph_recreate_node()
			notification.AddLegacy("Nodegraph has been recreated.",0,8)
		end
		pRecreate:SetWide(110)
		pnl:AddItem(pRecreate)

		local pRemUnlinked = vgui.Create("DButton",pnl)
		pRemUnlinked:SetText("Remove Unlinked Nodes")
		pRemUnlinked.DoClick = function(pRemUnlinked)
			local tool = GetTool()
			if(!tool) then return end
			local count = tool:RemoveUnlinkedNodes()
			if(count > 0) then
				tool:ClearEffects()
				notification.AddLegacy("Removed " .. count .. " unlinked node(s).",0,8)
			else
				notification.AddLegacy("No unlinked nodes found.",0,8)
			end
		end
		pRemUnlinked:SetWide(110)
		pnl:AddItem(pRemUnlinked)

		local pClear = vgui.Create("DButton",pnl)
		pClear:SetText("Clear Nodegraph")
		pClear.DoClick = function(pClear)
			local tool = GetTool()
			if(!tool) then return end
			if(tool) then tool:ClearEffects() end
			nodegraph = _R.Nodegraph.Read()
			nodegraph:Clear()
			if nodeGrid then nodeGrid:Clear() end
			nodes = nodegraph:GetNodes()
			links = nodegraph:GetLinks()
			lookup = nodegraph:GetLookupTable()
			notification.AddLegacy("Nodegraph has been cleared.",0,8)
		end
		pClear:SetWide(110)
		pnl:AddItem(pClear)

		pnl:AddControl("Label",{Text = "  "})
		pnl:AddControl("Label",{Text = "Nodeable Map Creation"})
		pnl:AddControl("Label",{Text = [[If the status says "Not Nodeable", it means that the map will reject any custom nodegraph! You need to make the map nodeable first.

		Depending on the size of the map and your computer's performance, this may freeze your game and could take a while.

		This will create a nodeable map at ]] .. "data/nodegraph/" .. game.GetMap() .. ".bsp.dat."})
		pnl:AddControl("Label",{Text = "Status: " .. (nodegraph_get_map_nodeable() and "Already Nodeable" or "Not Nodeable")})
		
		local pDump = vgui.Create("DButton",pnl)
		pDump:SetText("Create Nodeable Map")
		pDump.DoClick = function(pDump)
			local tool = GetTool()
			if(!tool) then return end

			if nodegraph_get_map_nodeable() then
				notification.AddLegacy("This map is already nodeable.",0,8)
				return
			end

			if nodegraph_create_nodeable_map() then
				notification.AddLegacy("Successfully created a nodeable map at data/nodegraph/" .. game.GetMap() .. ".bsp.dat",0,8)
			else
				notification.AddLegacy("Failed to create a nodeable map.",1,8)
			end
		end
		pDump:SetWide(110)
		pnl:AddItem(pDump)

		pnl:AddControl("Label",{Text = "  "})
		pnl:AddControl("Label",{Text = "Zone Utilities"})

		pnl:AddControl("CheckBox",{Label = "Delete Ground Nodes",Command = "cl_nodegraph_tool_selectedzones_ground"})
		pnl:AddControl("CheckBox",{Label = "Delete Air Nodes",Command = "cl_nodegraph_tool_selectedzones_air"})
		pnl:AddControl("CheckBox",{Label = "Delete Climb Nodes",Command = "cl_nodegraph_tool_selectedzones_climb"})
		pnl:AddControl("CheckBox",{Label = "Delete Hint Nodes",Command = "cl_nodegraph_tool_selectedzones_hint"})

		pnl:TextEntry("Selected Zones", "cl_nodegraph_tool_selectedzones")
		pnl:AddControl("Label",{Text = "Enter zone numbers to delete, separated by commas. For example: 4,5,6"})

		local pBuildZones = vgui.Create("DButton",pnl)
		pBuildZones:SetText("Build Zones")
		pBuildZones.DoClick = function(pBuildZones)
			local tool = GetTool()
			if(!tool) then return end
			tool:BuildZone()
			notification.AddLegacy("Zones have been built.",0,8)
		end
		pBuildZones:SetWide(110)
		pnl:AddItem(pBuildZones)

		local pDelUnselectedZones = vgui.Create("DButton",pnl)
		pDelUnselectedZones:SetText("Delete Unselected Zones")
		pDelUnselectedZones.DoClick = function(pDelUnselectedZones)
			local tool = GetTool()
			if(!tool) then return end
			if tool:DelZones(false) then
				notification.AddLegacy("Unselected zones have been deleted.",0,8)
			end
		end
		pDelUnselectedZones:SetWide(110)
		pnl:AddItem(pDelUnselectedZones)

		local pDelSelectedZones = vgui.Create("DButton",pnl)
		pDelSelectedZones:SetText("Delete Selected Zones")
		pDelSelectedZones.DoClick = function(pDelSelectedZones)
			local tool = GetTool()
			if(!tool) then return end
			if tool:DelZones(true) then
				notification.AddLegacy("Selected zones have been deleted.",0,8)
			end
		end
		pDelSelectedZones:SetWide(110)
		pnl:AddItem(pDelSelectedZones)

		pnl:AddControl("Label",{Text = "  "})
		pnl:AddControl("Label",{Text = "Ground Node Generation"})

		pnl:AddControl("Slider",{type = "int",min = 0,max = 10000,label = "Nav Min Area Size",Command = "cl_nodegraph_tool_gen_ground_navareasize"})
		pnl:AddControl("Slider",{type = "int",min = 0,max = 720,label = "Max Link Distance",Command = "cl_nodegraph_tool_gen_ground_link_distance"})
		pnl:AddControl("Slider",{type = "int",min = 0,max = 16,label = "Node Offset Z",Command = "cl_nodegraph_tool_gen_ground_node_z"})
		pnl:AddControl("CheckBox",{Label = "Use Navmesh Links",Command = "cl_nodegraph_tool_gen_ground_navlinks"})
		pnl:AddControl("CheckBox",{Label = "Use Bounding Box for Link Generation",Command = "cl_nodegraph_tool_gen_ground_link_tracehull"})
		pnl:AddControl("CheckBox",{Label = "Enable Step Check (Slow)",Command = "cl_nodegraph_tool_gen_ground_stepcheck_enable"})
		pnl:AddControl("CheckBox",{Label = "Enable Node Projection (Slow)",Command = "cl_nodegraph_tool_gen_ground_nodeproj_enable"})
		pnl:AddControl("CheckBox",{Label = "Only Keep Largest Zone",Command = "cl_nodegraph_tool_gen_ground_onlykeeplargestzone"})
		pnl:AddControl("CheckBox",{Label = "Generate Jump Links",Command = "cl_nodegraph_tool_gen_ground_jump_links"})
		pnl:AddControl("CheckBox",{Label = "Apply Jump Hints to Nodes",Command = "cl_nodegraph_tool_gen_ground_jump_hints"})
		pnl:AddControl("CheckBox",{Label = "Allow Generating on Crouch Nav Areas",Command = "cl_nodegraph_tool_gen_ground_allow_crouch"})
		pnl:AddControl("CheckBox",{Label = "Allow Generating on Jump Nav Areas",Command = "cl_nodegraph_tool_gen_ground_allow_jump"})
		pnl:AddControl("CheckBox",{Label = "Allow Generating on Water",Command = "cl_nodegraph_tool_gen_ground_allow_water"})
		pnl:AddControl("Label",{Text = [[This feature requires a Navmesh to be present on the map!
		
		Pressing this button will clear Ground Nodes and start the generation. May freeze your game for a while. Please be patient.]]})
		local pGenerate = vgui.Create("DButton",pnl)
		pGenerate:SetText("Generate Ground Nodes")
		pGenerate.DoClick = function(pGenerate)
			local tool = GetTool()
			if(!tool) then return end
			tool:GenerateNodes()
		end
		pGenerate:SetWide(110)
		pnl:AddItem(pGenerate)

		pnl:AddControl("Label",{Text = "  "})
		pnl:AddControl("Label",{Text = "Grid Ground Node Generation"})

		pnl:AddControl("Slider",{type = "int",min = 64,max = 1024,label = "Grid Step",Command = "cl_nodegraph_tool_gen_grid_step"})
		pnl:AddControl("Slider",{type = "int",min = 512,max = 8192,label = "Grid Range",Command = "cl_nodegraph_tool_gen_grid_range"})
		pnl:AddControl("Slider",{type = "int",min = 0,max = 16,label = "Node Offset Z",Command = "cl_nodegraph_tool_gen_grid_height_offset"})
		pnl:AddControl("CheckBox",{Label = "Use Range",Command = "cl_nodegraph_tool_gen_grid_range_enabled"})
		pnl:AddControl("CheckBox",{Label = "Remove Existing Nodes",Command = "cl_nodegraph_tool_gen_grid_removenodes"})
		pnl:AddControl("CheckBox",{Label = "Allow Generating on Water",Command = "cl_nodegraph_tool_gen_grid_allowwater"})

		pnl:AddControl("Label",{Text = "Pressing this button will prompt you to shoot at a position as a starting point, which then will initiate the generation. Press this button again to cancel it. May freeze your game for a while. Please be patient."})
		local pGenGrid = vgui.Create("DButton",pnl)
		pGenGrid:SetText("Generate Ground Nodes")
		pGenGrid.DoClick = function(pGenGrid)
			local tool = GetTool()
			if(!tool) then return end
			if tool.m_bWaitingForGridStart then
				tool.m_bWaitingForGridStart = false
				notification.AddLegacy("Cancelled grid generation.",0,8)
				return
			end
			tool.m_bWaitingForGridStart = true
			notification.AddLegacy("Shoot at a position to start grid generation.",0,8)
		end
		pGenGrid:SetWide(110)
		pnl:AddItem(pGenGrid)

		pnl:AddControl("Label",{Text = "  "})
		pnl:AddControl("Label",{Text = "Air Node Generation"})

		pnl:AddControl("Slider",{type = "int",min = 0,max = 720,label = "Max Link Distance",Command = "cl_nodegraph_tool_gen_air_link_distance"})
		pnl:AddControl("Slider",{type = "int",min = 64,max = 512,label = "Node Height",Command = "cl_nodegraph_tool_gen_air_height"})
		pnl:AddControl("CheckBox",{Label = "Use Ground Node Links",Command = "cl_nodegraph_tool_gen_air_ground_links"})
		pnl:AddControl("CheckBox",{Label = "Enable Node Projection (Slow)",Command = "cl_nodegraph_tool_gen_air_nodeproj_enable"})
		pnl:AddControl("CheckBox",{Label = "Only Keep Largest Zone",Command = "cl_nodegraph_tool_gen_air_onlykeeplargestzone"})
		pnl:AddControl("CheckBox",{Label = "Use Bounding Box for Link Generation",Command = "cl_nodegraph_tool_gen_air_link_tracehull"})
		pnl:AddControl("CheckBox",{Label = "Set All Nodes as Strider Node",Command = "cl_nodegraph_tool_gen_air_strider_node"})
		pnl:AddControl("Label",{Text = [[This feature requires Ground Nodes to be present on the map!
		
		Pressing this button will clear Air Nodes and start the generation. May freeze your game for a while. Please be patient.]]})
		local pGenerateAir = vgui.Create("DButton",pnl)
		pGenerateAir:SetText("Generate Air Nodes")
		pGenerateAir.DoClick = function(pGenerateAir)
			local tool = GetTool()
			if(!tool) then return end
			tool:GenerateAirNodes()
			if(tool) then tool:ClearEffects() end
		end
		pGenerateAir:SetWide(110)
		pnl:AddItem(pGenerateAir)

		pnl:AddControl("Label",{Text = "  "})
		pnl:AddControl("Label",{Text = "Jump Link Generation"})

		pnl:AddControl("Slider",{type = "int",min = 18,max = 256,label = "Min Jump Height",Command = "cl_nodegraph_tool_gen_jump_min_height"})
		pnl:AddControl("Slider",{type = "int",min = 0,max = 720,label = "Max Link Distance",Command = "cl_nodegraph_tool_gen_jump_link_distance"})
		pnl:AddControl("CheckBox",{Label = "Use Bounding Box",Command = "cl_nodegraph_tool_gen_jump_tracehull"})
		pnl:AddControl("CheckBox",{Label = "Apply Jump Hints to Nodes",Command = "cl_nodegraph_tool_gen_jump_hints"})
		pnl:AddControl("Label",{Text = "Pressing this button will clear Jump Links and start the generation. May freeze your game for a while. Please be patient."})
		local pGenerateJumpLinks = vgui.Create("DButton",pnl)
		pGenerateJumpLinks:SetText("Generate Jump Links")
		pGenerateJumpLinks.DoClick = function(pGenerateJumpLinks)
			local tool = GetTool()
			if(!tool) then return end
			tool:GenerateJumpLinks()
			if(tool) then tool:ClearEffects() end
		end
		pGenerateJumpLinks:SetWide(110)
		pnl:AddItem(pGenerateJumpLinks)
	end
else
	function TOOL:LeftClick(tr)
		if(game.SinglePlayer()) then self:CallOnClient(0,tr) end
		return true
	end
	function TOOL:RightClick(tr)
		if(game.SinglePlayer()) then self:CallOnClient(1,tr) end
		return true
	end
	function TOOL:Holster()
		self.m_deployed = false
		if(game.SinglePlayer()) then self:CallOnClient(2) end
		return
	end
	function TOOL:Deploy()
		self.m_deployed = true
		if(game.SinglePlayer()) then self:CallOnClient(4) end
	end
	util.AddNetworkString("sv_nodegrapheditor_undo_node")
	util.AddNetworkString("cl_nodegrapheditor_undo_node")
	net.Receive("sv_nodegrapheditor_undo_node",function(len,pl)
		local nodeID = net.ReadUInt(14)
		undo.Create("Node")
			undo.AddFunction(function()
				net.Start("cl_nodegrapheditor_undo_node")
					net.WriteUInt(nodeID,14)
				net.Send(pl)
			end)
			undo.SetPlayer(pl)
		undo.Finish()
	end)
end