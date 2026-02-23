local debug = debug
local table = table
local setmetatable = setmetatable
local game = game
local file = file
local MsgN = MsgN
local Vector = Vector
local pairs = pairs
local tostring = tostring
local util = util
local math = math
local string = string

local NODE_TYPE_GROUND = 2
local NODE_TYPE_AIR = 3
local NODE_TYPE_CLIMB = 4
local NODE_TYPE_WATER = 5
local NODE_TYPE_HINT = 7
local AI_NODE_ZONE_UNKNOWN = 0
local AI_NODE_ZONE_SOLO = 1
local AI_NODE_ZONE_UNIVERSAL = 3
local AI_NODE_FIRST_ZONE = 4
local AINET_VERSION_NUMBER = 37
local NUM_HULLS = 10
local MAX_NODES = 8192

local _R = debug.getregistry()
local meta = {}
_R.Nodegraph = meta
local methods = {}
meta.__index = methods
function meta:__tostring()
	local str = "Nodegraph [" .. table.Count(self:GetNodes()) .. " Nodes] [" .. table.Count(self:GetLinks()) .. " Links] [AINET " .. self:GetAINetVersion() .. "] [MAP " .. self:GetMapVersion() .. "]"
	return str
end
methods.MetaName = "Nodegraph"
function _R.Nodegraph.Create(f,fmode)
	local t = {}
	setmetatable(t,meta)
	if(f) then if(!t:ParseFile(f,fmode)) then t:Clear() end
	else t:Clear() end
	return t
end

function _R.Nodegraph.Read(f)
	if(!f) then f = "maps/graphs/" .. game.GetMap() .. ".ain" end
	return _R.Nodegraph.Create(f)
end

function methods:Clear()
	local map_version = self.m_nodegraph and self.m_nodegraph.map_version or 0
	self.m_nodegraph = {
		ainet_version = AINET_VERSION_NUMBER,
		map_version = map_version,
		nodes = {},
		links = {},
		lookup = {}
	}
end

function methods:GetAINetVersion()
	return self:GetData().ainet_version
end

function methods:GetMapVersion()
	return self:GetData().map_version
end

function methods:ParseFile(f,fmode)
	fmode = fmode or "GAME"
	f = file.Open(f,"rb",fmode)
		if(!f) then return end
		local ainet_ver = f:ReadLong()
		local map_ver = f:ReadLong()
		local nodegraph = {
			ainet_version = ainet_ver,
			map_version = map_ver
		}
		if(ainet_ver != AINET_VERSION_NUMBER) then
			MsgN("Unknown graph file")
			f:Close()
			return
		end
		local numNodes = f:ReadLong()
		if(numNodes > MAX_NODES || numNodes < 0) then
			MsgN("Graph file has an unexpected amount of nodes")
			f:Close()
			return
		end
		local nodes = {}
		for i = 1,numNodes do
			local v = Vector(f:ReadFloat(),f:ReadFloat(),f:ReadFloat())
			local yaw = f:ReadFloat()
			local flOffsets = {}
			for i = 1,NUM_HULLS do
				flOffsets[i] = f:ReadFloat()
			end
			local nodetype = f:ReadByte()
			local nodeinfo = f:ReadUShort()
			local zone = f:ReadShort()
			
			local node = {
				pos = v,
				yaw = yaw,
				offset = flOffsets,
				type = nodetype,
				info = nodeinfo,
				zone = zone,
				neighbor = {},
				numneighbors = 0,
				link = {},
				numlinks = 0,
				hint = 0
			}
			nodes[#nodes + 1] = node
		end
		local numLinks = f:ReadLong()
		local links = {}
		for i = 1,numLinks do
			local link = {}
			local srcID = f:ReadShort()
			local destID = f:ReadShort()
			local nodesrc = nodes[srcID +1]
			local nodedest = nodes[destID +1]
			if(nodesrc && nodedest) then
				nodesrc.neighbor[#nodesrc.neighbor + 1] = nodedest
				nodesrc.numneighbors = nodesrc.numneighbors +1
				
				nodesrc.link[#nodesrc.link + 1] = link
				nodesrc.numlinks = nodesrc.numlinks +1
				link.src = nodesrc
				link.srcID = srcID +1
				
				nodedest.neighbor[#nodedest.neighbor + 1] = nodesrc
				nodedest.numneighbors = nodedest.numneighbors +1
				
				nodedest.link[#nodedest.link + 1] = link
				nodedest.numlinks = nodedest.numlinks +1
				link.dest = nodedest
				link.destID = destID +1
			else MsgN("Unknown link source or destination " .. srcID .. " " .. destID) end
			local moves = {}
			for i = 1,NUM_HULLS do
				moves[i] = f:ReadByte()
			end
			link.move = moves
			links[#links + 1] = link
		end
		local lookup = {}
		for i = 1,numNodes do
			lookup[#lookup + 1] = f:ReadLong()
		end
	f:Close()
	nodegraph.nodes = nodes
	nodegraph.links = links
	nodegraph.lookup = lookup
	self.m_nodegraph = nodegraph
	return nodegraph
end

function methods:GetData()
	return self.m_nodegraph
end

function methods:GetNodes()
	return self:GetData().nodes
end

function methods:GetLinks()
	return self:GetData().links
end

function methods:GetLookupTable()
	return self:GetData().lookup
end

function methods:GetNode(nodeID)
	return self:GetNodes()[nodeID]
end

-- Since info_hint(s) are not included in the nodegraph, they must not count towards the node count!
function methods:CountNodes(tbl)
	local count = 0
	for i, node in pairs(tbl) do
	   if node.type ~= NODE_TYPE_HINT then
		  count = count + 1
	   end
	end
	return count
end

function methods:CountHints(tbl)
	local count = 0
	for i, node in pairs(tbl) do
	   if node.type == NODE_TYPE_HINT then
		  count = count + 1
	   end
	end
	return count
end

function methods:AddNode(pos,type,yaw,info,hintid)
	type = type || NODE_TYPE_GROUND
	local nodes = self:GetNodes()
	local numNodes = self:CountNodes(nodes)
	if(numNodes == MAX_NODES and type ~= NODE_TYPE_HINT) then return false end
	local offset = {}
	for i = 1,NUM_HULLS do offset[i] = 0 end
	local node = {
		pos = pos,
		yaw = yaw || 0,
		offset = offset,
		type = type,
		info = info || 0,
		zone = AI_NODE_ZONE_UNKNOWN,
		neighbor = {},
		numneighbors = 0,
		link = {},
		numlinks = 0,
		hint = hintid or 0
	}
	local maxID = 0
	for k in pairs(nodes) do
		if k > maxID then maxID = k end
	end
	local nodeID = maxID + 1
	nodes[nodeID] = node
	local lookup = self:GetLookupTable()
	if type ~= NODE_TYPE_HINT then lookup[nodeID] = nodeID end
	return nodeID
end

function methods:RemoveLinks(nodeID)
	local nodes = self:GetNodes()
	local node = nodes[nodeID]
	if(!node) then return end
	local links = self:GetLinks()
	for _,link in pairs(links) do
		if(link.dest == node) then
			links[_] = nil
			if(link.src) then
				for _,linkSrc in pairs(link.src.link) do
					if(linkSrc.dest == node || linkSrc.src == node) then
						link.src.link[_] = nil
					end
				end
			end
		elseif(link.src == node) then
			links[_] = nil
			if(link.dest) then
				for _,linkSrc in pairs(link.dest.link) do
					if(linkSrc.dest == node || linkSrc.src == node) then
						link.dest.link[_] = nil
					end
				end
			end
		end
	end
	node.link = {}
end

function methods:RemoveNode(nodeID)
	local nodes = self:GetNodes()
	if(!nodes[nodeID]) then return end
	local node = nodes[nodeID]
	self:RemoveLinks(nodeID)
	nodes[nodeID] = nil
	local lookup = self:GetLookupTable()
	lookup[nodeID] = nil
end

function methods:RemoveLink(src,dest)
	local nodes = self:GetNodes()
	local nodeSrc = nodes[src]
	local nodeDest = nodes[dest]
	if(!nodeSrc || !nodeDest) then return end
	local links = self:GetLinks()
	for _,link in pairs(links) do
		if((link.src == nodeSrc && link.dest == nodeDest) || (link.src == nodeDest && link.dest == nodeSrc)) then
			links[_] = nil
		end
	end
	for _,linkSrc in pairs(nodeSrc.link) do
		if((linkSrc.src == nodeSrc && linkSrc.dest == nodeDest) || (linkSrc.src == nodeDest && linkSrc.dest == nodeSrc)) then
			nodeSrc.link[_] = nil
		end
	end
	for _,linkDest in pairs(nodeDest.link) do
		if((linkDest.src == nodeSrc && linkDest.dest == nodeDest) || (linkDest.src == nodeDest && linkDest.dest == nodeSrc)) then
			nodeDest.link[_] = nil
		end
	end
end

function methods:AddLink(src,dest,move)
	if(src == dest) then return end
	local nodes = self:GetNodes()
	local nodeSrc = nodes[src]
	local nodeDest = nodes[dest]
	if(!nodeSrc || !nodeDest) then return end
	if(!move) then
		move = {}
		for i = 1,NUM_HULLS do move[i] = 1 end
	end
	local link = {
		src = nodeSrc,
		dest = nodeDest,
		srcID = src,
		destID = dest,
		move = move
	}
	local link1 = {
		src = nodeDest,
		dest = nodeSrc,
		srcID = dest,
		destID = src,
		move = move
	}
	local maxSrcLink = 0
	for k in pairs(nodeSrc.link) do if k > maxSrcLink then maxSrcLink = k end end
	nodeSrc.link[maxSrcLink + 1] = link
	local maxDestLink = 0
	for k in pairs(nodeDest.link) do if k > maxDestLink then maxDestLink = k end end
	nodeDest.link[maxDestLink + 1] = link1
	local _links = self:GetLinks()
	local maxLink = 0
	for k in pairs(_links) do if k > maxLink then maxLink = k end end
	_links[maxLink + 1] = link
end

function methods:GetLink(src,dest)
	local nodes = self:GetNodes()
	local nodeSrc = nodes[src]
	local nodeDest = nodes[dest]
	if(!nodeSrc || !nodeDest) then return end
	for _,link in pairs(nodeSrc.link) do
		if(link.src == nodeDest || link.dest == nodeDest) then return link end
	end
	for _,link in pairs(nodeDest.link) do
		if(link.src == nodeSrc || link.dest == nodeSrc) then return link end
	end
end

function methods:HasLink(src,dest)
	return self:GetLink(src,dest) != nil
end

function methods:FloodFillZone(startNode, zone)
    if startNode.zone ~= AI_NODE_ZONE_UNKNOWN then return end

	-- We use iterative approach instead of recursion to avoid stack overflow on dense nodegraphs.
    local stack = {startNode}
    while #stack > 0 do
        local node = table.remove(stack)
        
        if node.zone == AI_NODE_ZONE_UNKNOWN then
            node.zone = zone
            
            -- Add all unknown zone linked nodes to the stack.
            for _, link in pairs(node.link) do
                local linkedNode
                if link.dest == node then
                    linkedNode = link.src
                else
                    linkedNode = link.dest
                end
                
                if linkedNode.zone == AI_NODE_ZONE_UNKNOWN then
                    stack[#stack + 1] = linkedNode
                end
            end
        end
    end
end

function methods:Save(f)
	if(!f) then
		file.CreateDir("nodegraph")
		f = "nodegraph/" .. game.GetMap() .. ".txt"
	end
	local data = self:GetData()
	local nodes = data.nodes
	local nodeID = 1
	local hintID = 1
	local nodeIDs = {}
	local tempHints = {}
	local nodeKeys = {}
	for k in pairs(nodes) do nodeKeys[#nodeKeys + 1] = k end
	table.sort(nodeKeys)
	for i = 1, #nodeKeys do	-- Remove info_hint(s) as they are not included in the nodegraph.
		local k = nodeKeys[i]
		local node = nodes[k]
		if node.type == NODE_TYPE_HINT then
			tempHints[hintID] = node
			nodes[k] = nil
			hintID = hintID + 1
		end
	end
	nodeKeys = {}
	for k in pairs(nodes) do nodeKeys[#nodeKeys + 1] = k end
	table.sort(nodeKeys)
	for i = 1, #nodeKeys do -- Put everything in a sequential order
		local k = nodeKeys[i]
		local node = nodes[k]
		nodes[k] = nil
		nodes[nodeID] = node
		nodeIDs[k] = nodeID
		nodeID = nodeID + 1
	end
	local links = data.links
	local linkID = 1
	local linkKeys = {}
	for k in pairs(links) do linkKeys[#linkKeys + 1] = k end
	table.sort(linkKeys)
	for i = 1, #linkKeys do -- Update the node IDs in the links and put everything in a sequential order
		local k = linkKeys[i]
		local link = links[k]
		links[k] = nil
		links[linkID] = link
		link.destID = nodeIDs[link.destID]
		link.srcID = nodeIDs[link.srcID]
		link.dest = nodes[link.destID]
		link.src = nodes[link.srcID]
		linkID = linkID + 1
	end

	-- After putting everything in sequential order, we save hints for corresponding node IDs.
	local saveHints = true
	if file.Exists("data/nodegraph/" .. game.GetMap() .. ".hint.json", "GAME") then
		file.Delete("nodegraph/" .. game.GetMap() .. ".hint.json")
	end
	local nodeHints = { NodeHints = {}, Hints = {} }
	for nodeID, node in pairs(nodes) do
		if node.hint and node.hint ~= 0 then
			nodeHints.NodeHints[tostring(nodeID - 1)] = { Position = tostring(node.pos), HintType = tostring(node.hint) }
			if node.hint == 901 then
				nodeHints.NodeHints[tostring(nodeID - 1)].SpawnFlags = "65536"
			end
		end
	end
	for i = 1, #tempHints do
		local hint = tempHints[i]
		nodeHints.Hints[i] = { Position = tostring(hint.pos), HintType = tostring(hint.hint) }
	end
	if table.IsEmpty(nodeHints.NodeHints) and table.IsEmpty(nodeHints.Hints) then saveHints = false end
	if table.IsEmpty(nodeHints.NodeHints) then nodeHints.NodeHints = nil end
	if table.IsEmpty(nodeHints.Hints) then nodeHints.Hints = nil end
	local jsonHints = util.TableToJSON(nodeHints, false)
	if saveHints == true then file.Write("nodegraph/" .. game.GetMap() .. ".hint.json", jsonHints) end

	-- Initialize zones.
	for i, node in pairs(nodes) do
		node.zone = AI_NODE_ZONE_UNKNOWN
	end
	for i, node in pairs(nodes) do
		if table.Count(node.link) == 0 then
			node.zone = AI_NODE_ZONE_SOLO
		end
	end
	local curZone = AI_NODE_FIRST_ZONE
	for i, node in pairs(nodes) do
		if node.zone == AI_NODE_ZONE_UNKNOWN then
			self:FloodFillZone(node, curZone)
			curZone = curZone + 1
		end
	end
	for i, node in pairs(nodes) do
		nodes[i].zone = node.zone
	end
	
	-- The lookup table are WC Node IDs.
	for nodeID = 1, #nodes do
		data.lookup[nodeID] = nodeID
	end
	local lookup = data.lookup
	local f = file.Open(f,"wb","DATA")
	f:WriteLong(data.ainet_version)
	f:WriteLong(data.map_version)
	local numNodes = #nodes
	f:WriteLong(numNodes)
	for i = 1,numNodes do
		local node = nodes[i]
		for i = 1,3 do f:WriteFloat(node.pos[i]) end
		f:WriteFloat(node.yaw)
		for i = 1,NUM_HULLS do
			f:WriteFloat(node.offset[i])
		end
		f:WriteByte(node.type)
		node.info = node.type == NODE_TYPE_CLIMB and 2 or 0
		f:WriteUShort(node.info)
		f:WriteShort(node.zone)
	end
	local numLinks = #links
	f:WriteLong(numLinks)
	for i = 1,numLinks do
		local link = links[i]
		f:WriteShort(link.srcID -1)
		f:WriteShort(link.destID -1)
		for i = 1,NUM_HULLS do
			f:WriteByte(link.move[i])
		end
	end
	for i = 1,numNodes do
		f:WriteLong(lookup[i])
	end
	f:Close()
	for i = 1, #tempHints do -- Let's add back our hint nodes.
		local v = tempHints[i]
		self:AddNode(v.pos, v.type, v.yaw, v.info, v.hint)
	end
end

function methods:SaveAsENT(f)
	if(!f) then
		file.CreateDir("nodegraph")
		f = "nodegraph/" .. game.GetMap() .. ".ent.txt"
	end
	local f = file.Open(f,"wb","DATA")
	if(!f) then return end

	local data = self:GetData()
	local nodes = data.nodes
	local nodeID = 1
	local nodeIDs = {}
	local nodeKeys = {}
	for k in pairs(nodes) do nodeKeys[#nodeKeys + 1] = k end
	table.sort(nodeKeys)
	for i = 1, #nodeKeys do -- Put everything in a sequential order
		local k = nodeKeys[i]
		local node = nodes[k]
		nodes[k] = nil
		nodes[nodeID] = node
		nodeIDs[k] = nodeID
		nodeID = nodeID + 1
	end
	local links = data.links
	local linkID = 1
	local linkKeys = {}
	for k in pairs(links) do linkKeys[#linkKeys + 1] = k end
	table.sort(linkKeys)
	for i = 1, #linkKeys do -- Update the node IDs in the links and put everything in a sequential order
		local k = linkKeys[i]
		local link = links[k]
		links[k] = nil
		links[linkID] = link
		link.destID = nodeIDs[link.destID]
		link.srcID = nodeIDs[link.srcID]
		link.dest = nodes[link.destID]
		link.src = nodes[link.srcID]
		linkID = linkID + 1
	end
	
	for i = 1, #nodes do
		local node = nodes[i]
		if (node.type == NODE_TYPE_GROUND or node.type == NODE_TYPE_AIR) and node.hint == 0 then
			f:Write("entity\n")
			f:Write("{\n")
			f:Write("\t\"origin\" \"" .. math.floor(node.pos[1]) .. " " .. math.floor(node.pos[2]) .. " " .. math.floor(node.pos[3]) .. "\"\n")
			f:Write("\t\"nodeid\" \"" .. (i) .. "\"\n")
			f:Write("\t\"angles\" \"0 " .. math.floor(node.yaw) .. " 0\"\n")
			if node.type == NODE_TYPE_AIR then
				f:Write("\t\"classname\" \"info_node_air\"\n")
			else
				f:Write("\t\"classname\" \"info_node\"\n")
			end
			f:Write("}\n")
		else
			f:Write("entity\n")
			f:Write("{\n")
			f:Write("\t\"origin\" \"" .. math.floor(node.pos[1]) .. " " .. math.floor(node.pos[2]) .. " " .. math.floor(node.pos[3]) .. "\"\n")
			f:Write("\t\"nodeid\" \"" .. (i) .. "\"\n")
			f:Write("\t\"angles\" \"0 " .. math.floor(node.yaw) .. " 0\"\n")
			f:Write("\t\"hinttype\" \"" .. node.hint .. "\"\n")
			f:Write("\t\"StartHintDisabled\" \"0\"\n")
			f:Write("\t\"nodeFOV\" \"360\"\n")
			f:Write("\t\"MinimumState\" \"1\"\n")
			f:Write("\t\"MaximumState\" \"3\"\n")
			if node.type == NODE_TYPE_CLIMB then
				local success = false
				for j = 1, #node.link do
					local link = node.link[j]
					if link.move and table.HasValue(link.move, 8) then
						if nodes[link.destID] and nodes[link.destID].type ~= NODE_TYPE_CLIMB then
							continue
						end

						f:Write("\t\"TargetNode\" \"" .. link.destID .. "\"\n")
						success = true
						break
					end
				end
				if not success then
					f:Write("\t\"TargetNode\" \"-1\"\n")
				end
			elseif node.type == NODE_TYPE_GROUND and node.hint == 901 then
				local success = false
				for j = 1, #node.link do
					local link = node.link[j]
					if link.move and table.HasValue(link.move, 2) then
						if nodes[link.destID] and nodes[link.destID].hint ~= 901 then
							continue
						end

						f:Write("\t\"TargetNode\" \"" .. link.destID .. "\"\n")
						success = true
						break
					end
				end
				if not success then
					f:Write("\t\"TargetNode\" \"-1\"\n")
				end
				f:Write("\t\"spawnflags\" \"65536\"\n")
			else
				f:Write("\t\"TargetNode\" \"-1\"\n")
			end
			if node.type == NODE_TYPE_GROUND then
				f:Write("\t\"classname\" \"info_node_hint\"\n")
			elseif node.type == NODE_TYPE_AIR then
				f:Write("\t\"classname\" \"info_node_air_hint\"\n")
			elseif node.type == NODE_TYPE_CLIMB then
				f:Write("\t\"classname\" \"info_node_climb\"\n")
			else
				f:Write("\t\"classname\" \"info_hint\"\n")
			end
			f:Write("}\n")
		end
	end
	f:Close()
end

function methods:SaveToVMF(f)
	if(!f) then
		file.CreateDir("nodegraph")
		f = "nodegraph/" .. game.GetMap() .. ".vmf"
	end
	
	-- Read existing VMF file.
	local vmfContent = ""
	local existingFile = file.Open(f, "rb", "DATA")
	if existingFile then
		vmfContent = existingFile:Read(existingFile:Size())
		existingFile:Close()
	end
	
	-- Remove existing node entities using brace counting.
	local function removeNodeEntities(content)
		local result = ""
		local i = 1
		local len = string.len(content)
		
		while i <= len do
			local entityStart, entityEnd = string.find(content, "entity", i)
			if not entityStart then
				result = result .. string.sub(content, i)
				break
			end
			
			result = result .. string.sub(content, i, entityStart - 1)
			
			local braceStart = string.find(content, "{", entityEnd)
			if not braceStart then
				result = result .. string.sub(content, entityStart, entityEnd)
				i = entityEnd + 1
			else
				local braceCount = 1
				local j = braceStart + 1
				local entityContent = ""
				
				while j <= len and braceCount > 0 do
					local char = string.sub(content, j, j)
					entityContent = entityContent .. char
					if char == "{" then
						braceCount = braceCount + 1
					elseif char == "}" then
						braceCount = braceCount - 1
					end
					j = j + 1
				end
				
				local shouldRemove = false
				if string.find(entityContent, "\"classname\"%s+\"info_node\"") or
				   string.find(entityContent, "\"classname\"%s+\"info_node_air\"") or
				   string.find(entityContent, "\"classname\"%s+\"info_node_hint\"") or
				   string.find(entityContent, "\"classname\"%s+\"info_node_air_hint\"") or
				   string.find(entityContent, "\"classname\"%s+\"info_hint\"") or
				   string.find(entityContent, "\"classname\"%s+\"info_node_climb\"") then
					shouldRemove = true
				end
				
				if not shouldRemove then
					result = result .. "entity" .. string.sub(content, entityEnd + 1, j - 1)
				end
				i = j
			end
		end
		
		return result
	end
	
	vmfContent = removeNodeEntities(vmfContent)
	
	-- Open output file.
	local outputFile = string.gsub(f, "%.vmf$", ".vmf.txt")
	local f = file.Open(outputFile,"wb","DATA")
	if(!f) then return end

	local data = self:GetData()
	local nodes = data.nodes
	local nodeID = 1
	local hintID = 1
	local nodeIDs = {}
	local nodeKeys = {}
	for k in pairs(nodes) do nodeKeys[#nodeKeys + 1] = k end
	table.sort(nodeKeys)
	for i = 1, #nodeKeys do -- Put everything in a sequential order
		local k = nodeKeys[i]
		local node = nodes[k]
		nodes[k] = nil
		nodes[nodeID] = node
		nodeIDs[k] = nodeID
		nodeID = nodeID + 1
	end
	local links = data.links
	local linkID = 1
	local linkKeys = {}
	for k in pairs(links) do linkKeys[#linkKeys + 1] = k end
	table.sort(linkKeys)
	for i = 1, #linkKeys do -- Update the node IDs in the links and put everything in a sequential order
		local k = linkKeys[i]
		local link = links[k]
		links[k] = nil
		links[linkID] = link
		link.destID = nodeIDs[link.destID]
		link.srcID = nodeIDs[link.srcID]
		link.dest = nodes[link.destID]
		link.src = nodes[link.srcID]
		linkID = linkID + 1
	end
	
	-- Write existing VMF content first.
	f:Write(vmfContent)
	vmfContent = nil
	
	for i = 1, #nodes do
		local node = nodes[i]
		if (node.type == NODE_TYPE_GROUND or node.type == NODE_TYPE_AIR) and node.hint == 0 then
			f:Write("entity\n")
			f:Write("{\n")
			f:Write("\t\"origin\" \"" .. math.floor(node.pos[1]) .. " " .. math.floor(node.pos[2]) .. " " .. math.floor(node.pos[3]) .. "\"\n")
			f:Write("\t\"nodeid\" \"" .. (i) .. "\"\n")
			f:Write("\t\"angles\" \"0 " .. math.floor(node.yaw) .. " 0\"\n")
			if node.type == NODE_TYPE_AIR then
				f:Write("\t\"classname\" \"info_node_air\"\n")
			else
				f:Write("\t\"classname\" \"info_node\"\n")
			end
			f:Write("}\n")
		else
			f:Write("entity\n")
			f:Write("{\n")
			f:Write("\t\"origin\" \"" .. math.floor(node.pos[1]) .. " " .. math.floor(node.pos[2]) .. " " .. math.floor(node.pos[3]) .. "\"\n")
			f:Write("\t\"nodeid\" \"" .. (i) .. "\"\n")
			f:Write("\t\"angles\" \"0 " .. math.floor(node.yaw) .. " 0\"\n")
			f:Write("\t\"hinttype\" \"" .. node.hint .. "\"\n")
			f:Write("\t\"StartHintDisabled\" \"0\"\n")
			f:Write("\t\"nodeFOV\" \"360\"\n")
			f:Write("\t\"MinimumState\" \"1\"\n")
			f:Write("\t\"MaximumState\" \"3\"\n")
			if node.type == NODE_TYPE_CLIMB then
				local success = false
				for j = 1, #node.link do
					local link = node.link[j]
					if link.move and table.HasValue(link.move, 8) then
						if nodes[link.destID] and nodes[link.destID].type ~= NODE_TYPE_CLIMB then
							continue
						end

						f:Write("\t\"TargetNode\" \"" .. link.destID .. "\"\n")
						success = true
						break
					end
				end
				if not success then
					f:Write("\t\"TargetNode\" \"-1\"\n")
				end
			elseif node.type == NODE_TYPE_GROUND and node.hint == 901 then
				local success = false
				for j = 1, #node.link do
					local link = node.link[j]
					if link.move and table.HasValue(link.move, 2) then
						if nodes[link.destID] and nodes[link.destID].hint ~= 901 then
							continue
						end

						f:Write("\t\"TargetNode\" \"" .. link.destID .. "\"\n")
						success = true
						break
					end
				end
				if not success then
					f:Write("\t\"TargetNode\" \"-1\"\n")
				end
				f:Write("\t\"spawnflags\" \"65536\"\n")
			else
				f:Write("\t\"TargetNode\" \"-1\"\n")
			end
			if node.type == NODE_TYPE_GROUND then
				f:Write("\t\"classname\" \"info_node_hint\"\n")
			elseif node.type == NODE_TYPE_AIR then
				f:Write("\t\"classname\" \"info_node_air_hint\"\n")
			elseif node.type == NODE_TYPE_CLIMB then
				f:Write("\t\"classname\" \"info_node_climb\"\n")
			else
				f:Write("\t\"classname\" \"info_hint\"\n")
			end
			f:Write("}\n")
		end
	end
	f:Close()
end