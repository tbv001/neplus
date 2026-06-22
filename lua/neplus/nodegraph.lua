include("neplus/constants.lua")

local Nodegraph = {}
Nodegraph.__index = Nodegraph

function Nodegraph:Create(filePath, gamePath)
	local nodeTable = {}
	setmetatable(nodeTable, Nodegraph)

	if filePath and not nodeTable:ParseFile(filePath, gamePath) then
		nodeTable:Clear()
	end

	return nodeTable
end

function Nodegraph:Read(filePath)
	if not filePath then
		filePath = "maps/graphs/" .. game.GetMap() .. ".ain"
	end

	return Nodegraph:Create(filePath)
end

function Nodegraph:Clear()
	local mapVersion = self.m_nodegraph and self.m_nodegraph.map_version or 0
	self.m_nodegraph = {
		ainet_version = AINET_VERSION_NUMBER,
		map_version = mapVersion,
		nodes = {},
		links = {},
		lookup = {}
	}
end

function Nodegraph:ParseFile(filePath, gamePath)
	gamePath = gamePath or "GAME"
	local fileHandle = file.Open(filePath, "rb", gamePath)
	if not fileHandle then
		return
	end

	local ainetVersion = fileHandle:ReadLong()
	local mapVersion = fileHandle:ReadLong()
	local nodegraph = {
		ainet_version = ainetVersion,
		map_version = mapVersion
	}

	if ainetVersion ~= AINET_VERSION_NUMBER then
		MsgN("Unknown graph file")
		fileHandle:Close()
		return
	end

	local numNodes = fileHandle:ReadLong()
	if numNodes > MAX_NODES or numNodes < 0 then
		MsgN("Graph file has an unexpected amount of nodes")
		fileHandle:Close()
		return
	end

	local nodes = {}
	for _ = 1, numNodes do
		local pos = Vector(fileHandle:ReadFloat(), fileHandle:ReadFloat(), fileHandle:ReadFloat())
		local yaw = fileHandle:ReadFloat()
		local hullOffsets = {}

		for j = 1, NUM_HULLS do
			hullOffsets[j] = fileHandle:ReadFloat()
		end

		local nodeType = fileHandle:ReadByte()
		local nodeInfo = fileHandle:ReadUShort()
		local zone = fileHandle:ReadShort()

		local node = {
			pos = pos,
			yaw = yaw,
			offset = hullOffsets,
			type = nodeType,
			info = nodeInfo,
			zone = zone,
			neighbor = {},
			numneighbors = 0,
			link = {},
			numlinks = 0,
			hint = 0
		}

		nodes[#nodes + 1] = node
	end

	local numLinks = fileHandle:ReadLong()
	local links = {}
	for _ = 1, numLinks do
		local link = {}
		local sourceId = fileHandle:ReadShort()
		local destId = fileHandle:ReadShort()
		if sourceId == nil or destId == nil then
			break
		end

		local nodeSrc = nodes[sourceId + 1]
		local nodeDest = nodes[destId + 1]
		if nodeSrc and nodeDest then
			nodeSrc.neighbor[#nodeSrc.neighbor + 1] = nodeDest
			nodeSrc.numneighbors = nodeSrc.numneighbors + 1

			nodeSrc.link[#nodeSrc.link + 1] = link
			nodeSrc.numlinks = nodeSrc.numlinks + 1
			link.src = nodeSrc
			link.srcID = sourceId + 1

			nodeDest.neighbor[#nodeDest.neighbor + 1] = nodeSrc
			nodeDest.numneighbors = nodeDest.numneighbors + 1

			nodeDest.link[#nodeDest.link + 1] = link
			nodeDest.numlinks = nodeDest.numlinks + 1
			link.dest = nodeDest
			link.destID = destId + 1
		else
			MsgN("Unknown link source or destination " .. sourceId .. " " .. destId)
		end

		local moveFlags = {}
		for j = 1, NUM_HULLS do
			moveFlags[j] = fileHandle:ReadByte()
		end

		link.move = moveFlags
		links[#links + 1] = link
	end

	local lookup = {}
	for _ = 1, numNodes do
		lookup[#lookup + 1] = fileHandle:ReadLong()
	end

	fileHandle:Close()
	nodegraph.nodes = nodes
	nodegraph.links = links
	nodegraph.lookup = lookup
	self.m_nodegraph = nodegraph

	return nodegraph
end

function Nodegraph:GetData()
	return self.m_nodegraph
end

function Nodegraph:GetNodes()
	return self:GetData().nodes
end

function Nodegraph:GetLinks()
	return self:GetData().links
end

function Nodegraph:GetLookupTable()
	return self:GetData().lookup
end

-- Since info_hint(s) are not included in the nodegraph, they must not count towards the node count!
function Nodegraph:CountNodes(tbl)
	local count = 0
	for _, node in pairs(tbl) do
		if node.type ~= NODE_TYPE_HINT then
			count = count + 1
		end
	end

	return count
end

function Nodegraph:CountHints(tbl)
	local count = 0
	for _, node in pairs(tbl) do
		if node.type == NODE_TYPE_HINT then
			count = count + 1
		end
	end

	return count
end

function Nodegraph:AddNode(pos, type, yaw, info, hintid)
	type = type or NODE_TYPE_GROUND
	local nodes = self:GetNodes()
	local numNodes = self:CountNodes(nodes)
	if numNodes == MAX_NODES and type ~= NODE_TYPE_HINT then
		return false
	end

	local offset = {}
	for i = 1, NUM_HULLS do
		offset[i] = 0
	end

	local node = {
		pos = pos,
		yaw = yaw or 0,
		offset = offset,
		type = type,
		info = info or 0,
		zone = AI_NODE_ZONE_UNKNOWN,
		neighbor = {},
		numneighbors = 0,
		link = {},
		numlinks = 0,
		hint = hintid or 0
	}

	local maxID = 0
	for k in pairs(nodes) do
		if k > maxID then
			maxID = k
		end
	end

	local nodeID = maxID + 1
	nodes[nodeID] = node
	local lookup = self:GetLookupTable()
	if type ~= NODE_TYPE_HINT then
		lookup[nodeID] = nodeID
	end

	return nodeID
end

function Nodegraph:RemoveLinks(nodeID)
	local nodes = self:GetNodes()
	local node = nodes[nodeID]
	if not node then
		return
	end

	local links = self:GetLinks()
	local toRemove = {}
	for k, link in pairs(links) do
		if link.dest == node or link.src == node then
			toRemove[k] = link
		end
	end

	for k, link in pairs(toRemove) do
		links[k] = nil

		if link.dest == node and link.src then
			for _, linkSrc in pairs(link.src.link) do
				if linkSrc.dest == node or linkSrc.src == node then
					link.src.link[_] = nil
				end
			end
		end

		if link.src == node and link.dest then
			for _, linkSrc in pairs(link.dest.link) do
				if linkSrc.dest == node or linkSrc.src == node then
					link.dest.link[_] = nil
				end
			end
		end
	end

	node.link = {}
end

function Nodegraph:RemoveNode(nodeID)
	local nodes = self:GetNodes()

	if not nodes[nodeID] then
		return
	end

	self:RemoveLinks(nodeID)
	nodes[nodeID] = nil

	local lookup = self:GetLookupTable()
	lookup[nodeID] = nil
end

function Nodegraph:RemoveLink(src, dest)
	local nodes = self:GetNodes()
	local nodeSrc = nodes[src]
	local nodeDest = nodes[dest]
	if not nodeSrc or not nodeDest then
		return
	end

	local links = self:GetLinks()
	for _, link in pairs(links) do
		if (link.src == nodeSrc and link.dest == nodeDest) or (link.src == nodeDest and link.dest == nodeSrc) then
			links[_] = nil
		end
	end

	for _, linkSrc in pairs(nodeSrc.link) do
		if (linkSrc.src == nodeSrc and linkSrc.dest == nodeDest) or (linkSrc.src == nodeDest and linkSrc.dest == nodeSrc) then
			nodeSrc.link[_] = nil
		end
	end

	for _, linkDest in pairs(nodeDest.link) do
		if (linkDest.src == nodeSrc and linkDest.dest == nodeDest) or (linkDest.src == nodeDest and linkDest.dest == nodeSrc) then
			nodeDest.link[_] = nil
		end
	end
end

function Nodegraph:AddLink(src, dest, move)
	if src == dest then
		return
	end

	local nodes = self:GetNodes()
	local nodeSrc = nodes[src]
	local nodeDest = nodes[dest]
	if not nodeSrc or not nodeDest then
		return
	end

	if nodeSrc.type == NODE_TYPE_HINT or nodeDest.type == NODE_TYPE_HINT then
		return
	end

	if not move then
		move = {}
		for i = 1, NUM_HULLS do
			move[i] = 1
		end
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
	for k in pairs(nodeSrc.link) do
		if k > maxSrcLink then
			maxSrcLink = k
		end
	end

	nodeSrc.link[maxSrcLink + 1] = link

	local maxDestLink = 0
	for k in pairs(nodeDest.link) do
		if k > maxDestLink then
			maxDestLink = k
		end
	end

	nodeDest.link[maxDestLink + 1] = link1

	local links = self:GetLinks()
	local maxLink = 0
	for k in pairs(links) do
		if k > maxLink then
			maxLink = k
		end
	end

	links[maxLink + 1] = link
end

function Nodegraph:GetLink(src, dest)
	local nodes = self:GetNodes()
	local nodeSrc = nodes[src]
	local nodeDest = nodes[dest]
	if not nodeSrc or not nodeDest then
		return
	end

	for _, link in pairs(nodeSrc.link) do
		if link.src == nodeDest or link.dest == nodeDest then
			return link
		end
	end

	for _, link in pairs(nodeDest.link) do
		if link.src == nodeSrc or link.dest == nodeSrc then
			return link
		end
	end
end

function Nodegraph:HasLink(src, dest)
	return self:GetLink(src, dest) ~= nil
end

function Nodegraph:FloodFillZone(startNode, zone)
	if startNode.zone ~= AI_NODE_ZONE_UNKNOWN then
		return
	end

	local stack = {startNode}

	while #stack > 0 do
		local node = table.remove(stack)
		if node.zone == AI_NODE_ZONE_UNKNOWN then
			node.zone = zone

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

function Nodegraph:Save(filePath)
	if not filePath then
		file.CreateDir("nodegraph")
		filePath = "nodegraph/" .. game.GetMap() .. ".txt"
	end

	local data = self:GetData()
	local nodes = data.nodes
	local nodeID = 1
	local hintID = 1
	local nodeIDs = {}
	local tempHints = {}
	local nodeKeys = {}
	for k in pairs(nodes) do
		nodeKeys[#nodeKeys + 1] = k
	end

	table.sort(nodeKeys)

	-- Remove info_hint(s) as they are not included in the nodegraph.
	for i = 1, #nodeKeys do
		local k = nodeKeys[i]
		local node = nodes[k]

		if node.type == NODE_TYPE_HINT then
			tempHints[hintID] = node
			nodes[k] = nil
			hintID = hintID + 1
		end
	end

	nodeKeys = {}
	for k in pairs(nodes) do
		nodeKeys[#nodeKeys + 1] = k
	end

	table.sort(nodeKeys)

	-- Put everything in a sequential order
	for i = 1, #nodeKeys do
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
	for k in pairs(links) do
		linkKeys[#linkKeys + 1] = k
	end

	table.sort(linkKeys)

	-- Update the node IDs in the links and put everything in a sequential order
	for i = 1, #linkKeys do
		local k = linkKeys[i]
		local link = links[k]
		local newSrc = nodeIDs[link.srcID]
		local newDest = nodeIDs[link.destID]

		if newSrc and newDest then
			links[k] = nil
			links[linkID] = link
			link.destID = newDest
			link.srcID = newSrc
			link.dest = nodes[link.destID]
			link.src = nodes[link.srcID]
			linkID = linkID + 1
		else
			links[k] = nil
		end
	end

	-- After putting everything in sequential order, we save hints for corresponding node IDs.
	local saveHints = true
	if file.Exists("data/nodegraph/" .. game.GetMap() .. ".hint.json", "GAME") then
		file.Delete("nodegraph/" .. game.GetMap() .. ".hint.json")
	end

	local nodeHints = { NodeHints = {}, Hints = {} }
	for nodeId, node in pairs(nodes) do
		if node.hint and node.hint ~= 0 then
			nodeHints.NodeHints[tostring(nodeId - 1)] = { Position = tostring(node.pos), HintType = tostring(node.hint) }

			if node.hint == 901 then
				nodeHints.NodeHints[tostring(nodeId - 1)].SpawnFlags = "65536"
			end
		end
	end

	for i = 1, #tempHints do
		local hint = tempHints[i]
		nodeHints.Hints[i] = { Position = tostring(hint.pos), HintType = tostring(hint.hint) }
	end

	if table.IsEmpty(nodeHints.NodeHints) and table.IsEmpty(nodeHints.Hints) then
		saveHints = false
	end

	if table.IsEmpty(nodeHints.NodeHints) then
		nodeHints.NodeHints = nil
	end

	if table.IsEmpty(nodeHints.Hints) then
		nodeHints.Hints = nil
	end

	local jsonHints = util.TableToJSON(nodeHints, false)
	if saveHints == true then
		file.Write("nodegraph/" .. game.GetMap() .. ".hint.json", jsonHints)
	end

	-- Initialize zones.
	for _, node in pairs(nodes) do
		node.zone = AI_NODE_ZONE_UNKNOWN
	end

	for _, node in pairs(nodes) do
		if table.Count(node.link) == 0 then
			node.zone = AI_NODE_ZONE_SOLO
		end
	end

	local curZone = AI_NODE_FIRST_ZONE
	for _, node in pairs(nodes) do
		if node.zone == AI_NODE_ZONE_UNKNOWN then
			self:FloodFillZone(node, curZone)
			curZone = curZone + 1
		end
	end

	for i, node in pairs(nodes) do
		nodes[i].zone = node.zone
	end

	-- The lookup table are WC Node IDs.
	for nodeId = 1, #nodes do
		data.lookup[nodeId] = nodeId
	end

	local fileHandle = file.Open(filePath, "wb", "DATA")
	fileHandle:WriteLong(data.ainet_version)
	fileHandle:WriteLong(data.map_version)

	local numNodes = #nodes
	fileHandle:WriteLong(numNodes)
	for i = 1, numNodes do
		local node = nodes[i]

		for j = 1, 3 do
			fileHandle:WriteFloat(node.pos[j])
		end

		fileHandle:WriteFloat(node.yaw)

		for j = 1, NUM_HULLS do
			fileHandle:WriteFloat(node.offset[j])
		end

		fileHandle:WriteByte(node.type)
		node.info = node.type == NODE_TYPE_CLIMB and 2 or 0
		fileHandle:WriteUShort(node.info)
		fileHandle:WriteShort(node.zone)
	end

	local numLinks = #links
	fileHandle:WriteLong(numLinks)

	for i = 1, numLinks do
		local link = links[i]
		fileHandle:WriteShort(link.srcID - 1)
		fileHandle:WriteShort(link.destID - 1)

		for j = 1, NUM_HULLS do
			fileHandle:WriteByte(link.move[j])
		end
	end

	local lookup = data.lookup
	for i = 1, numNodes do
		fileHandle:WriteLong(lookup[i])
	end

	fileHandle:Close()

	-- Let's add back our hint nodes.
	for i = 1, #tempHints do
		local tempHint = tempHints[i]
		self:AddNode(tempHint.pos, tempHint.type, tempHint.yaw, tempHint.info, tempHint.hint)
	end
end

function Nodegraph:SaveAsENT(filePath)
	if not filePath then
		file.CreateDir("nodegraph")
		filePath = "nodegraph/" .. game.GetMap() .. ".ent.txt"
	end

	local fileHandle = file.Open(filePath, "wb", "DATA")
	if not fileHandle then
		return
	end

	local data = self:GetData()
	local nodes = data.nodes
	local nodeID = 1
	local nodeIDs = {}
	local nodeKeys = {}
	for k in pairs(nodes) do
		nodeKeys[#nodeKeys + 1] = k
	end

	table.sort(nodeKeys)

	-- Put everything in a sequential order
	for i = 1, #nodeKeys do
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
	for k in pairs(links) do
		linkKeys[#linkKeys + 1] = k
	end

	table.sort(linkKeys)

	-- Update the node IDs in the links and put everything in a sequential order
	for i = 1, #linkKeys do
		local k = linkKeys[i]
		local link = links[k]
		local newSrc = nodeIDs[link.srcID]
		local newDest = nodeIDs[link.destID]

		if newSrc and newDest then
			links[k] = nil
			links[linkID] = link
			link.destID = newDest
			link.srcID = newSrc
			link.dest = nodes[link.destID]
			link.src = nodes[link.srcID]
			linkID = linkID + 1
		else
			links[k] = nil
		end
	end

	for i = 1, #nodes do
		local node = nodes[i]

		if (node.type == NODE_TYPE_GROUND or node.type == NODE_TYPE_AIR) and node.hint == 0 then
			fileHandle:Write("entity\n")
			fileHandle:Write("{\n")
			fileHandle:Write("\t\"origin\" \"" .. math.floor(node.pos[1]) .. " " .. math.floor(node.pos[2]) .. " " .. math.floor(node.pos[3]) .. "\"\n")
			fileHandle:Write("\t\"nodeid\" \"" .. (i) .. "\"\n")
			fileHandle:Write("\t\"angles\" \"0 " .. math.floor(node.yaw) .. " 0\"\n")

			if node.type == NODE_TYPE_AIR then
				fileHandle:Write("\t\"classname\" \"info_node_air\"\n")
			else
				fileHandle:Write("\t\"classname\" \"info_node\"\n")
			end

			fileHandle:Write("}\n")
		else
			fileHandle:Write("entity\n")
			fileHandle:Write("{\n")
			fileHandle:Write("\t\"origin\" \"" .. math.floor(node.pos[1]) .. " " .. math.floor(node.pos[2]) .. " " .. math.floor(node.pos[3]) .. "\"\n")
			fileHandle:Write("\t\"nodeid\" \"" .. (i) .. "\"\n")
			fileHandle:Write("\t\"angles\" \"0 " .. math.floor(node.yaw) .. " 0\"\n")
			fileHandle:Write("\t\"hinttype\" \"" .. node.hint .. "\"\n")
			fileHandle:Write("\t\"StartHintDisabled\" \"0\"\n")
			fileHandle:Write("\t\"nodeFOV\" \"360\"\n")
			fileHandle:Write("\t\"MinimumState\" \"1\"\n")
			fileHandle:Write("\t\"MaximumState\" \"3\"\n")

			if node.type == NODE_TYPE_CLIMB then
				local success = false

				for j = 1, #node.link do
					local link = node.link[j]

					if link.move and table.HasValue(link.move, 8) then
						if nodes[link.destID] and nodes[link.destID].type ~= NODE_TYPE_CLIMB then
							continue
						end

						fileHandle:Write("\t\"TargetNode\" \"" .. link.destID .. "\"\n")
						success = true
						break
					end
				end

				if not success then
					fileHandle:Write("\t\"TargetNode\" \"-1\"\n")
				end
			elseif node.type == NODE_TYPE_GROUND and node.hint == 901 then
				local success = false

				for j = 1, #node.link do
					local link = node.link[j]

					if link.move and table.HasValue(link.move, 2) then
						if nodes[link.destID] and nodes[link.destID].hint ~= 901 then
							continue
						end

						fileHandle:Write("\t\"TargetNode\" \"" .. link.destID .. "\"\n")
						success = true
						break
					end
				end

				if not success then
					fileHandle:Write("\t\"TargetNode\" \"-1\"\n")
				end

				fileHandle:Write("\t\"spawnflags\" \"65536\"\n")
			else
				fileHandle:Write("\t\"TargetNode\" \"-1\"\n")
			end

			if node.type == NODE_TYPE_GROUND then
				fileHandle:Write("\t\"classname\" \"info_node_hint\"\n")
			elseif node.type == NODE_TYPE_AIR then
				fileHandle:Write("\t\"classname\" \"info_node_air_hint\"\n")
			elseif node.type == NODE_TYPE_CLIMB then
				fileHandle:Write("\t\"classname\" \"info_node_climb\"\n")
			else
				fileHandle:Write("\t\"classname\" \"info_hint\"\n")
			end

			fileHandle:Write("}\n")
		end
	end

	fileHandle:Close()
end

function Nodegraph:SaveToVMF(filePath)
	if not filePath then
		file.CreateDir("nodegraph")
		filePath = "nodegraph/" .. game.GetMap() .. ".vmf"
	end

	local vmfContent = ""
	local existingFile = file.Open(filePath, "rb", "DATA")
	if existingFile then
		vmfContent = existingFile:Read(existingFile:Size())
		existingFile:Close()
	end

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

	local outputFile = string.gsub(filePath, "%.vmf$", ".vmf.txt")
	local fileHandle = file.Open(outputFile, "wb", "DATA")
	if not fileHandle then
		return
	end

	local data = self:GetData()
	local nodes = data.nodes
	local nodeID = 1
	local nodeIDs = {}
	local nodeKeys = {}
	for k in pairs(nodes) do
		nodeKeys[#nodeKeys + 1] = k
	end

	table.sort(nodeKeys)

	-- Put everything in a sequential order
	for i = 1, #nodeKeys do
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
	for k in pairs(links) do
		linkKeys[#linkKeys + 1] = k
	end

	table.sort(linkKeys)

	-- Update the node IDs in the links and put everything in a sequential order
	for i = 1, #linkKeys do
		local k = linkKeys[i]
		local link = links[k]
		local newSrc = nodeIDs[link.srcID]
		local newDest = nodeIDs[link.destID]

		if newSrc and newDest then
			links[k] = nil
			links[linkID] = link
			link.destID = newDest
			link.srcID = newSrc
			link.dest = nodes[link.destID]
			link.src = nodes[link.srcID]
			linkID = linkID + 1
		else
			links[k] = nil
		end
	end

	fileHandle:Write(vmfContent)

	for i = 1, #nodes do
		local node = nodes[i]

		if (node.type == NODE_TYPE_GROUND or node.type == NODE_TYPE_AIR) and node.hint == 0 then
			fileHandle:Write("entity\n")
			fileHandle:Write("{\n")
			fileHandle:Write("\t\"origin\" \"" .. math.floor(node.pos[1]) .. " " .. math.floor(node.pos[2]) .. " " .. math.floor(node.pos[3]) .. "\"\n")
			fileHandle:Write("\t\"nodeid\" \"" .. (i) .. "\"\n")
			fileHandle:Write("\t\"angles\" \"0 " .. math.floor(node.yaw) .. " 0\"\n")

			if node.type == NODE_TYPE_AIR then
				fileHandle:Write("\t\"classname\" \"info_node_air\"\n")
			else
				fileHandle:Write("\t\"classname\" \"info_node\"\n")
			end

			fileHandle:Write("}\n")
		else
			fileHandle:Write("entity\n")
			fileHandle:Write("{\n")
			fileHandle:Write("\t\"origin\" \"" .. math.floor(node.pos[1]) .. " " .. math.floor(node.pos[2]) .. " " .. math.floor(node.pos[3]) .. "\"\n")
			fileHandle:Write("\t\"nodeid\" \"" .. (i) .. "\"\n")
			fileHandle:Write("\t\"angles\" \"0 " .. math.floor(node.yaw) .. " 0\"\n")
			fileHandle:Write("\t\"hinttype\" \"" .. node.hint .. "\"\n")
			fileHandle:Write("\t\"StartHintDisabled\" \"0\"\n")
			fileHandle:Write("\t\"nodeFOV\" \"360\"\n")
			fileHandle:Write("\t\"MinimumState\" \"1\"\n")
			fileHandle:Write("\t\"MaximumState\" \"3\"\n")

			if node.type == NODE_TYPE_CLIMB then
				local success = false

				for j = 1, #node.link do
					local link = node.link[j]

					if link.move and table.HasValue(link.move, 8) then
						if nodes[link.destID] and nodes[link.destID].type ~= NODE_TYPE_CLIMB then
							continue
						end

						fileHandle:Write("\t\"TargetNode\" \"" .. link.destID .. "\"\n")
						success = true
						break
					end
				end

				if not success then
					fileHandle:Write("\t\"TargetNode\" \"-1\"\n")
				end
			elseif node.type == NODE_TYPE_GROUND and node.hint == 901 then
				local success = false

				for j = 1, #node.link do
					local link = node.link[j]

					if link.move and table.HasValue(link.move, 2) then
						if nodes[link.destID] and nodes[link.destID].hint ~= 901 then
							continue
						end

						fileHandle:Write("\t\"TargetNode\" \"" .. link.destID .. "\"\n")
						success = true
						break
					end
				end

				if not success then
					fileHandle:Write("\t\"TargetNode\" \"-1\"\n")
				end

				fileHandle:Write("\t\"spawnflags\" \"65536\"\n")
			else
				fileHandle:Write("\t\"TargetNode\" \"-1\"\n")
			end

			if node.type == NODE_TYPE_GROUND then
				fileHandle:Write("\t\"classname\" \"info_node_hint\"\n")
			elseif node.type == NODE_TYPE_AIR then
				fileHandle:Write("\t\"classname\" \"info_node_air_hint\"\n")
			elseif node.type == NODE_TYPE_CLIMB then
				fileHandle:Write("\t\"classname\" \"info_node_climb\"\n")
			else
				fileHandle:Write("\t\"classname\" \"info_hint\"\n")
			end

			fileHandle:Write("}\n")
		end
	end

	fileHandle:Close()
end

return Nodegraph
