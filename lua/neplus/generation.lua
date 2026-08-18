local Constants = include("neplus/constants.lua")
local Math = include("neplus/math.lua")

local Generation = {}

if CLIENT then
	Generation.cvHGrndNodeGen = CreateClientConVar("cl_nodegraph_tool_gen_ground_node_z", "16", false)
	Generation.cvDistLinkGrndNodeGen = CreateClientConVar("cl_nodegraph_tool_gen_ground_link_distance", "720", false)
	Generation.cvDistLinkAirNodeGen = CreateClientConVar("cl_nodegraph_tool_gen_air_link_distance", "720", false)
	Generation.cvDistLinkJmpLinkGen = CreateClientConVar("cl_nodegraph_tool_gen_jump_link_distance", "720", false)
	Generation.cvStepCheckGrndNodeGen = CreateClientConVar("cl_nodegraph_tool_gen_ground_stepcheck_enable", "1", false)
	Generation.cvNodeProjGrndNodeGen = CreateClientConVar("cl_nodegraph_tool_gen_ground_nodeproj_enable", "1", false)
	Generation.cvNodeProjAirNodeGen = CreateClientConVar("cl_nodegraph_tool_gen_air_nodeproj_enable", "1", false)
	Generation.cvMinJumpHeight = CreateClientConVar("cl_nodegraph_tool_gen_jump_min_height", "72", false)
	Generation.cvJumpGenTraceHull = CreateClientConVar("cl_nodegraph_tool_gen_jump_tracehull", "1", false)
	Generation.cvAirGenTraceHull = CreateClientConVar("cl_nodegraph_tool_gen_air_link_tracehull", "1", false)
	Generation.cvGrndGenTraceHull = CreateClientConVar("cl_nodegraph_tool_gen_ground_link_tracehull", "0", false)
	Generation.cvAirGenStriderNode = CreateClientConVar("cl_nodegraph_tool_gen_air_strider_node", "0", false)
	Generation.cvAirGenHeight = CreateClientConVar("cl_nodegraph_tool_gen_air_height", "64", false)
	Generation.cvAirGenGrndLinks = CreateClientConVar("cl_nodegraph_tool_gen_air_ground_links", "1", false)
	Generation.cvGrndGenNavAreaSize = CreateClientConVar("cl_nodegraph_tool_gen_ground_navareasize", "3000", false)
	Generation.cvGrndGenWater = CreateClientConVar("cl_nodegraph_tool_gen_ground_allow_water", "0", false)
	Generation.cvGrndGenCrouch = CreateClientConVar("cl_nodegraph_tool_gen_ground_allow_crouch", "0", false)
	Generation.cvGrndGenJump = CreateClientConVar("cl_nodegraph_tool_gen_ground_allow_jump", "0", false)
	Generation.cvGrndGenJumpLinks = CreateClientConVar("cl_nodegraph_tool_gen_ground_jump_links", "1", false)
	Generation.cvGrndGenNavLinks = CreateClientConVar("cl_nodegraph_tool_gen_ground_navlinks", "1", false)
	Generation.cvGrndGenHintJumps = CreateClientConVar("cl_nodegraph_tool_gen_ground_jump_hints", "0", false)
	Generation.cvJumpGenHintJumps = CreateClientConVar("cl_nodegraph_tool_gen_jump_hints", "0", false)
	Generation.cvGrndGenKLZ = CreateClientConVar("cl_nodegraph_tool_gen_ground_onlykeeplargestzone", "0", false)
	Generation.cvAirGenKLZ = CreateClientConVar("cl_nodegraph_tool_gen_air_onlykeeplargestzone", "0", false)
	Generation.cvGrndGenGridStep = CreateClientConVar("cl_nodegraph_tool_gen_grid_step", "256", false)
	Generation.cvGrndGenGridRangeEnabled = CreateClientConVar("cl_nodegraph_tool_gen_grid_range_enabled", "0", false)
	Generation.cvGrndGenGridRange = CreateClientConVar("cl_nodegraph_tool_gen_grid_range", "2048", false)
	Generation.cvGrndGenGridRemNodes = CreateClientConVar("cl_nodegraph_tool_gen_grid_removenodes", "1", false)
	Generation.cvGrndGenGridWater = CreateClientConVar("cl_nodegraph_tool_gen_grid_allowwater", "0", false)
	Generation.cvGrndGenGridOffset = CreateClientConVar("cl_nodegraph_tool_gen_grid_height_offset", "16", false)

	local function GetDistLimit()
		local cv = GetConVar("cl_nodegraph_tool_draw_distance")
		return cv and cv:GetInt() or 1500
	end

	local function GetPlaceNodeOnGround()
		local cv = GetConVar("cl_nodegraph_tool_place_node_on_ground")
		return cv and cv:GetBool() or false
	end

	local TimeBudget = 0.006
	local currentCoroutine = nil
	local currentTool = nil
	Generation.IsGenerating = false

	local function CancelTaskInternal(notifyUser)
		if not Generation.IsGenerating then
			return
		end

		hook.Remove("Think", "NEPlusGenerationTask")
		Generation.IsGenerating = false
		currentCoroutine = nil

		if currentTool then
			currentTool:BuildNodeGrid()
			currentTool:BuildZone()
			currentTool:ClearEffects()
		end

		if notifyUser then
			notification.AddLegacy("Cancelled generation.", 0, 8)
		end

		currentTool = nil
	end

	function Generation.CancelTask(tool, notifyUser)
		if tool and not currentTool then
			currentTool = tool
		end

		CancelTaskInternal(notifyUser ~= false)
	end

	local function StartTask(tool, taskFunc, onFinish)
		if Generation.IsGenerating then
			Generation.CancelTask(tool, true)
		end

		Generation.IsGenerating = true
		currentTool = tool

		local lastYieldTime = SysTime()
		local function YieldCheck(force)
			if not Generation.IsGenerating then
				coroutine.yield("cancelled")
				return
			end

			if force or (SysTime() - lastYieldTime) >= TimeBudget then
				lastYieldTime = SysTime()
				coroutine.yield()
				lastYieldTime = SysTime()
			end
		end

		local co = coroutine.create(function()
			local success, result = pcall(taskFunc, YieldCheck)
			if not success then
				ErrorNoHalt("[Nodegraph Editor+] Generation Error: " .. tostring(result) .. "\n")
				notification.AddLegacy("Generation failed with an error.", 1, 8)
			end
			return success, result
		end)

		currentCoroutine = co

		hook.Add("Think", "NEPlusGenerationTask", function()
			if not Generation.IsGenerating or not currentCoroutine then
				hook.Remove("Think", "NEPlusGenerationTask")
				Generation.IsGenerating = false
				return
			end

			local tickStart = SysTime()
			while (SysTime() - tickStart) < TimeBudget do
				if coroutine.status(currentCoroutine) == "dead" then
					hook.Remove("Think", "NEPlusGenerationTask")
					Generation.IsGenerating = false
					currentCoroutine = nil

					if onFinish then
						pcall(onFinish)
					end

					if currentTool then
						currentTool:BuildNodeGrid()
						currentTool:BuildZone()
						currentTool:ClearEffects()
					end

					currentTool = nil
					return
				end

				lastYieldTime = SysTime()
				local ok, yieldVal = coroutine.resume(currentCoroutine)
				if not ok then
					ErrorNoHalt("[Nodegraph Editor+] Generation Coroutine Error: " .. tostring(yieldVal) .. "\n")
					hook.Remove("Think", "NEPlusGenerationTask")
					Generation.IsGenerating = false
					currentCoroutine = nil
					if currentTool then
						currentTool:BuildNodeGrid()
						currentTool:BuildZone()
						currentTool:ClearEffects()
					end

					currentTool = nil
					notification.AddLegacy("Generation failed with an error.", 1, 8)
					return
				end

				if yieldVal == "cancelled" then
					hook.Remove("Think", "NEPlusGenerationTask")
					Generation.IsGenerating = false
					currentCoroutine = nil
					if currentTool then
						currentTool:BuildNodeGrid()
						currentTool:BuildZone()
						currentTool:ClearEffects()
					end

					currentTool = nil
					return
				end
			end
		end)
	end

	function Generation.YieldingCleanLinks(tool, targetNodes, YieldCheck)
		local nodes = tool:GetNodes()
		if not nodes then
			return
		end

		local nodeRadiusSqr = 30
		local cvNodeRadius = 900
		local nodesToProcess = {}
		if targetNodes then
			if type(targetNodes) == "table" then
				for k, v in pairs(targetNodes) do
					local id = (type(v) == "number" and v) or k
					if nodes[id] then
						nodesToProcess[id] = nodes[id]
					end
				end
			else
				if nodes[targetNodes] then
					nodesToProcess[targetNodes] = nodes[targetNodes]
				end
			end
		else
			nodesToProcess = nodes
		end

		tool:BuildNodeGrid()

		local nodeGrid = tool:GetNodeGrid()
		for id, node in pairs(nodesToProcess) do
			if not node or not node.link then
				continue
			end

			for _, link in pairs(node.link) do
				local destID = link.destID
				local destNode = nodes[destID]
				if not destNode then
					continue
				end

				local obstructed = false
				local midPoint = node.pos + (destNode.pos - node.pos) * 0.5
				local checkRadius = (node.pos - midPoint):Length() + nodeRadiusSqr
				local obstructionCandidates = nodeGrid:Query(midPoint, checkRadius, nodes)
				for k, nodeB in pairs(obstructionCandidates) do
					if k ~= id and k ~= destID then
						if nodeB.type == node.type and nodeB.type == destNode.type then
							if Math.IsNodeBetween(node.pos, nodeB.pos, destNode.pos, cvNodeRadius) then
								obstructed = true
								break
							end
						end
					end
				end

				if obstructed then
					tool:RemoveLink(id, destID)
				end

				if YieldCheck then YieldCheck() end
			end
			if YieldCheck then YieldCheck() end
		end
	end

	function Generation.YieldingPlaceNodesToGround(tool, YieldCheck)
		local nodes = tool:GetNodes()
		if not nodes then
			return
		end

		local pl = (tool and tool.GetOwner and tool:GetOwner()) or LocalPlayer()
		local TraceMask = tool:GetTraceMask()
		local cvPNOGHull = GetConVar("cl_nodegraph_tool_place_node_on_ground_hull")
		local cvPNOGOffset = GetConVar("cl_nodegraph_tool_place_node_on_ground_offset")
		local useHull = cvPNOGHull and cvPNOGHull:GetBool() or true
		local offsetZ = cvPNOGOffset and cvPNOGOffset:GetInt() or 0
		for _, node in pairs(nodes) do
			if node.type == Constants.NODE_TYPE_GROUND then
				local startPos = node.pos
				local count = 0
				if useHull then
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

					if not finalTrace.StartSolid then
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
							node.pos = trace.HitPos + Vector(0, 0, offsetZ)
						end
					end
				else
					while bit.band(util.PointContents(startPos), CONTENTS_SOLID) ~= 0 and count < 16 do
						startPos = startPos + Vector(0, 0, 1)
						count = count + 1
					end

					if bit.band(util.PointContents(startPos), CONTENTS_SOLID) == 0 then
						local endPos = startPos - Vector(0, 0, 10000)
						local trace = util.TraceLine({
							start = startPos,
							endpos = endPos,
							mask = TraceMask,
							filter = pl
						})

						if trace.Hit then
							node.pos = trace.HitPos + Vector(0, 0, offsetZ)
						end
					end
				end
			end

			if YieldCheck then
				YieldCheck()
			end
		end

		tool:BuildNodeGrid()
	end

	function Generation.GenerateGroundNodes(tool)
		if not tool then
			return
		end

		local conVars = {
			NavAreaSize = Generation.cvGrndGenNavAreaSize:GetInt(),
			WaterAreas = Generation.cvGrndGenWater:GetBool(),
			CrouchAreas = Generation.cvGrndGenCrouch:GetBool(),
			JumpAreas = Generation.cvGrndGenJump:GetBool(),
			GenJumpLinks = Generation.cvGrndGenJumpLinks:GetBool()
		}

		net.Start("nodegraph_gen_server")
		net.WriteEntity((tool and tool.GetOwner and tool:GetOwner()) or LocalPlayer())
		net.WriteTable(conVars)
		net.SendToServer()
	end

	function Generation.ProcessReceivedNavmeshNodes(tool, posTable)
		if not tool then
			return
		end

		local nodes = tool:GetNodes()
		local nodegraph = tool:GetNodegraph()
		local nodeGrid = tool:GetNodeGrid()

		if not posTable or #posTable <= 0 then
			notification.AddLegacy("No navmesh found. Please generate one first before using.", 0, 8)
			return
		end

		notification.AddLegacy("Starting ground node generation from navmesh...", 0, 8)

		StartTask(tool, function(YieldCheck)
			for id, node in pairs(nodes) do
				if node.type == Constants.NODE_TYPE_GROUND then
					nodegraph:RemoveNode(id)
				end
			end

			YieldCheck()

			local generatedCount = 0
			local areaIDToNodeID = {}
			local nodeList = {}
			local nodesToClean = {}
			for i = 1, #posTable do
				local numNodes = nodegraph:CountNodes(nodes)
				if numNodes >= Constants.MAX_NODES then
					break
				end

				local areaData = posTable[i]
				local nodeID = tool:CreateNodeGen(areaData.pos)
				if nodeID then
					areaIDToNodeID[areaData.id] = nodeID
					nodeList[#nodeList + 1] = { nodeID = nodeID, pos = areaData.pos }
					nodesToClean[#nodesToClean + 1] = nodeID
					generatedCount = generatedCount + 1
				else
					print("Failed to create node for area ID:", areaData.id)
				end

				YieldCheck()
			end

			tool:BuildNodeGrid()
			YieldCheck()

			if Generation.cvGrndGenNavLinks:GetBool() then
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
					YieldCheck()
				end
			end

			if Generation.cvGrndGenJumpLinks:GetBool() then
				for i = 1, #posTable do
					local areaData = posTable[i]
					local srcNodeID = areaIDToNodeID[areaData.id]
					if srcNodeID then
						for j = 1, #areaData.jumps do
							local adjAreaID = areaData.jumps[j]
							local destNodeID = areaIDToNodeID[adjAreaID]
							if destNodeID then
								tool:AddLink(srcNodeID, destNodeID, 2)

								if Generation.cvGrndGenHintJumps:GetBool() then
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
					YieldCheck()
				end
			end

			if Generation.cvDistLinkGrndNodeGen:GetInt() > 0 then
				local distMin = math.min(GetDistLimit(), Generation.cvDistLinkGrndNodeGen:GetInt())
				for i = 1, #nodeList do
					local nodeA = nodeList[i]
					local neighborCandidates = nodeGrid:Query(nodeA.pos, distMin, nodes)
					for otherID, otherNode in pairs(neighborCandidates) do
						if otherID ~= nodeA.nodeID and otherNode.type == Constants.NODE_TYPE_GROUND then
							if not tool:HasLink(nodeA.nodeID, otherID) then
								if tool:IsLineClear(nodeA.pos, otherNode.pos, Generation.cvStepCheckGrndNodeGen:GetBool(), Generation.cvGrndGenTraceHull:GetInt()) then
									tool:AddLink(nodeA.nodeID, otherID)
								end
							end
						end

						YieldCheck()
					end

					YieldCheck()
				end
			end

			if #nodesToClean > 0 and Generation.cvNodeProjGrndNodeGen:GetBool() then
				Generation.YieldingCleanLinks(tool, nodesToClean, YieldCheck)
			end

			if GetPlaceNodeOnGround() then
				Generation.YieldingPlaceNodesToGround(tool, YieldCheck)
			end

			if Generation.cvGrndGenKLZ:GetBool() then
				local klzCount = tool:OnlyKeepLargestZone(true, false)
				generatedCount = generatedCount - (klzCount or 0)
			end

			local removedUnlinked = tool:RemoveUnlinkedNodes(Constants.NODE_TYPE_GROUND)
			generatedCount = generatedCount - (removedUnlinked or 0)

			tool:BuildNodeGrid()
			tool:BuildZone()
			tool:ClearEffects()

			if generatedCount > 0 then
				notification.AddLegacy("Successfully generated " .. generatedCount .. " ground nodes.", 0, 8)
			else
				notification.AddLegacy("Failed to generate ground nodes.", 1, 8)
			end
		end)
	end

	function Generation.GenerateAirNodes(tool)
		if not tool then
			return
		end

		local nodes = tool:GetNodes()
		local nodegraph = tool:GetNodegraph()
		local nodeGrid = tool:GetNodeGrid()
		local traceMask = tool.GetTraceMask and tool:GetTraceMask() or MASK_NPCWORLDSTATIC

		notification.AddLegacy("Starting air node generation...", 0, 8)

		StartTask(tool, function(YieldCheck)
			local groundData = {}
			local nodesToClean = {}
			local count = 0
			local distMin = math.min(GetDistLimit(), Generation.cvDistLinkAirNodeGen:GetInt())
			local pl = (tool and tool.GetOwner and tool:GetOwner()) or LocalPlayer()
			for id, node in pairs(nodes) do
				if node.type == Constants.NODE_TYPE_AIR then
					nodegraph:RemoveNode(id)
				end

				if node.type == Constants.NODE_TYPE_GROUND then
					local validPos
					local startPos = node.pos
					local attempts = 0
					while attempts < 16 do
						local trace = util.TraceHull({
							start = startPos,
							endpos = startPos,
							mins = Vector(-16, -16, 0),
							maxs = Vector(16, 16, 8),
							mask = traceMask,
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
						mask = traceMask,
						filter = pl
					})

					if not finalTrace.StartSolid then
						local endPos = startPos - Vector(0, 0, 10000)
						local trace = util.TraceHull({
							start = startPos,
							endpos = endPos,
							mins = Vector(-16, -16, 0),
							maxs = Vector(16, 16, 8),
							mask = traceMask,
							filter = pl
						})

						if trace.Hit then
							validPos = trace.HitPos
						else
							validPos = node.pos
						end

						groundData[#groundData + 1] = { pos = validPos, parentID = id, links = node.link }
					end
				end

				YieldCheck()
			end

			local parentToAir = {}
			for i = 1, #groundData do
				local data = groundData[i]
				local startPos = data.pos
				local endPos = startPos + Vector(0, 0, Generation.cvAirGenHeight:GetInt())
				local firstTrace = util.TraceLine({
					start = startPos,
					endpos = endPos + Vector(0, 0, 64), -- They must have at least 64 units of empty space above them to be valid.
					mask = traceMask,
					filter = pl
				})

				if not firstTrace.Hit then
					local validPos = endPos
					local numNodes = nodegraph:CountNodes(nodes)
					if numNodes >= Constants.MAX_NODES then
						notification.AddLegacy("Reached the maximum node limit. Can't generate more air nodes.", 0, 8)
						break
					end

					local airNode = tool:CreateNodeGen(validPos, Constants.NODE_TYPE_AIR,
						Generation.cvAirGenStriderNode:GetBool() and 904 or 0)

					if airNode then
						nodes[airNode].parentGround = data.parentID
						parentToAir[data.parentID] = airNode
						nodesToClean[#nodesToClean + 1] = airNode
						count = count + 1
					end
				end

				YieldCheck()
			end

			if Generation.cvAirGenGrndLinks:GetBool() then
				for i = 1, #groundData do
					local data = groundData[i]
					local parentID = data.parentID
					local airNodeID = parentToAir[parentID]
					if airNodeID then
						for _, link in pairs(data.links) do
							if link.move and not table.HasValue(link.move, 1) then
								continue
							end

							local otherGround
							if link.src and link.src ~= nodes[parentID] then
								otherGround = link.src
							elseif link.dest and link.dest ~= nodes[parentID] then
								otherGround = link.dest
							end

							if otherGround then
								local otherID
								for id, n in pairs(nodes) do
									if n == otherGround then
										otherID = id
										break
									end
								end

								if otherID and parentToAir[otherID] then
									tool:AddLink(airNodeID, parentToAir[otherID], 4)
								end
							end
						end
					end

					YieldCheck()
				end
			end

			if Generation.cvDistLinkAirNodeGen:GetInt() > 0 then
				tool:BuildNodeGrid()
				YieldCheck()

				for _, airNodeID in pairs(parentToAir) do
					local validPos = nodes[airNodeID].pos
					local neighborCandidates = nodeGrid:Query(validPos, distMin, nodes)
					for otherID, otherNode in pairs(neighborCandidates) do
						if otherID ~= airNodeID and otherNode.type == Constants.NODE_TYPE_AIR then
							if tool:IsLineClear(validPos, otherNode.pos, false, Generation.cvAirGenTraceHull:GetBool() and 2 or 0) then
								tool:AddLink(airNodeID, otherID, 4)
							end
						end
						YieldCheck()
					end
					YieldCheck()
				end
			end

			if #nodesToClean > 0 and Generation.cvNodeProjAirNodeGen:GetBool() then
				Generation.YieldingCleanLinks(tool, nodesToClean, YieldCheck)
			end

			if Generation.cvAirGenKLZ:GetBool() then
				local klzCount = tool:OnlyKeepLargestZone(false, true)
				count = count - (klzCount or 0)
			end

			local removedNodes = tool:RemoveUnlinkedNodes(Constants.NODE_TYPE_AIR)
			count = count - (removedNodes or 0)
			if count > 0 then
				notification.AddLegacy("Successfully generated " .. count .. " air nodes.", 0, 8)
			else
				notification.AddLegacy(
					"Failed to generate air nodes. Either no ground nodes found, or no space for air nodes.", 1, 8)
			end

			tool:BuildNodeGrid()
			tool:BuildZone()
		end)
	end

	function Generation.GenerateJumpLinks(tool)
		if not tool then
			return
		end

		local nodes = tool:GetNodes()
		local nodeGrid = tool:GetNodeGrid()
		local traceMask = tool.GetTraceMask and tool:GetTraceMask() or MASK_NPCWORLDSTATIC
		local distMinLinear = math.min(GetDistLimit(), Generation.cvDistLinkJmpLinkGen:GetInt())
		local distMin = distMinLinear * distMinLinear
		local pl = (tool and tool.GetOwner and tool:GetOwner()) or LocalPlayer()
		local count = 0

		notification.AddLegacy("Starting jump link generation...", 0, 8)

		StartTask(tool, function(YieldCheck)
			tool:RemoveLinksWithType(2)
			tool:BuildNodeGrid()
			YieldCheck()

			for nodeIDA, nodeA in pairs(nodes) do
				if nodeA.type == Constants.NODE_TYPE_GROUND then
					local neighborCandidates = nodeGrid:Query(nodeA.pos, distMinLinear, nodes)
					for nodeIDB, nodeB in pairs(neighborCandidates) do
						if nodeIDB ~= nodeIDA and nodeB and nodeB.type == Constants.NODE_TYPE_GROUND then
							local d = nodeA.pos:DistToSqr(nodeB.pos)

							if d <= distMin then
								local deltaZ = nodeB.pos[3] - nodeA.pos[3]
								if not tool:HasLink(nodeIDA, nodeIDB) and deltaZ < -Generation.cvMinJumpHeight:GetInt() then
									local traceStart = nodeA.pos + Vector(0, 0, 3)
									local traceEnd = Vector(nodeB.pos.x, nodeB.pos.y, nodeA.pos.z)
									local traceResult
									local trace
									if Generation.cvJumpGenTraceHull:GetBool() then
										trace = {
											start = traceStart,
											endpos = traceEnd,
											mins = Vector(-13, -13, 0),
											maxs = Vector(13, 13, 69),
											mask = traceMask,
											filter = pl
										}

										traceResult = util.TraceHull(trace)
									else
										trace = {
											start = traceStart,
											endpos = traceEnd,
											mask = traceMask,
											filter = pl
										}

										traceResult = util.TraceLine(trace)
									end

									if not traceResult.Hit then
										trace.start = Vector(nodeB.pos.x, nodeB.pos.y, nodeA.pos.z)
										trace.endpos = nodeB.pos + Vector(0, 0, 3)

										local finalTraceResult
										if Generation.cvJumpGenTraceHull:GetBool() then
											finalTraceResult = util.TraceHull(trace)
										else
											finalTraceResult = util.TraceLine(trace)
										end

										if not finalTraceResult.Hit then
											tool:AddLink(nodeIDA, nodeIDB, 2)
											count = count + 1

											if Generation.cvJumpGenHintJumps:GetBool() then
												local srcNode = nodes[nodeIDA]
												local destNode = nodes[nodeIDB]

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

						YieldCheck()
					end
				end

				YieldCheck()
			end

			tool:BuildZone()

			if count > 0 then
				notification.AddLegacy("Successfully generated " .. count .. " jump links.", 0, 8)
			else
				notification.AddLegacy("Failed to generate jump links.", 1, 8)
			end
		end)
	end

	function Generation.GenerateGridNodes(tool, startPos)
		if not tool or not startPos then
			return
		end

		local nodes = tool:GetNodes()
		local nodegraph = tool:GetNodegraph()
		local nodeGrid = tool:GetNodeGrid()
		local traceMask = tool.GetTraceMask and tool:GetTraceMask() or MASK_NPCWORLDSTATIC

		local step = Generation.cvGrndGenGridStep:GetInt()
		local range = Generation.cvGrndGenGridRange:GetInt()
		local useRange = Generation.cvGrndGenGridRangeEnabled:GetBool()
		local allowWater = Generation.cvGrndGenGridWater:GetBool()
		local hOffset = Generation.cvGrndGenGridOffset:GetInt()
		local count = 0
		local pl = (tool and tool.GetOwner and tool:GetOwner()) or LocalPlayer()
		local createdNodes = {}

		local origin = Vector(startPos.x, startPos.y, startPos.z)
		origin.x = math.Round(origin.x / step) * step
		origin.y = math.Round(origin.y / step) * step
		origin.z = math.Round(origin.z / step) * step

		local minX, maxX, minY, maxY, minZ, maxZ
		if useRange then
			minX, maxX = origin.x - range, origin.x + range
			minY, maxY = origin.y - range, origin.y + range
			minZ, maxZ = origin.z - range, origin.z + range
		else
			local mins, maxs = game.GetWorld():GetModelBounds()
			minX = origin.x - math.ceil((origin.x - mins.x) / step) * step
			minY = origin.y - math.ceil((origin.y - mins.y) / step) * step
			minZ = origin.z - math.ceil((origin.z - mins.z) / step) * step
			maxX, maxY, maxZ = maxs.x, maxs.y, maxs.z
		end

		notification.AddLegacy("Starting ground node generation using grid...", 0, 8)

		StartTask(tool, function(YieldCheck)
			if Generation.cvGrndGenGridRemNodes:GetBool() then
				for id, node in pairs(nodes) do
					if node.type == Constants.NODE_TYPE_GROUND then
						nodegraph:RemoveNode(id)
					end
				end
			end

			YieldCheck()

			local candidates = {}
			local rangeSqr = range * range
			for x = minX, maxX, step do
				for y = minY, maxY, step do
					local dx = x - origin.x
					local dy = y - origin.y
					if not useRange or (dx * dx + dy * dy) <= rangeSqr then
						for z = minZ, maxZ, step do
							candidates[#candidates + 1] = Vector(x, y, z)
						end
					end
				end

				YieldCheck()
			end

			table.sort(candidates, function(a, b)
				return a:DistToSqr(origin) < b:DistToSqr(origin)
			end)

			YieldCheck()

			for i = 1, #candidates do
				if nodegraph:CountNodes(nodes) >= Constants.MAX_NODES then
					notification.AddLegacy("Reached node limit. Stopped adding more nodes.", 1, 8)
					break
				end

				local pos = candidates[i]
				local aboveOffset = Vector(0, 0, 0)
				local aboveCheckTr = util.TraceLine({
					start = pos,
					endpos = pos + Vector(0, 0, 128),
					mask = traceMask,
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
					mask = traceMask,
					filter = pl
				})

				if placeCheckTr.Hit and not placeCheckTr.StartSolid and placeCheckTr.HitNormal.z >= 0.70710678 then
					local validWater = true
					if not allowWater then
						local contents = util.PointContents(placeCheckTr.HitPos)
						if bit.band(contents, CONTENTS_WATER) ~= 0 then
							validWater = false
						end
					end

					if validWater then
						local solidCheckTr = util.TraceHull({
							start = placeCheckTr.HitPos + Vector(0, 0, 10),
							endpos = placeCheckTr.HitPos + Vector(0, 0, 10),
							mins = Vector(-13, -13, 0),
							maxs = Vector(13, 13, 62),
							mask = traceMask,
							filter = pl
						})

						if not solidCheckTr.StartSolid then
							local nearby = nodeGrid:Query(placeCheckTr.HitPos, 50, nodes)
							if table.Count(nearby) == 0 then
								local nodeGenerated = nodegraph:AddNode(placeCheckTr.HitPos + Vector(0, 0, hOffset),
									Constants.NODE_TYPE_GROUND, 0, 0, 0)

								if nodeGenerated then
									nodeGrid:Insert(nodeGenerated, nodes[nodeGenerated])
									createdNodes[#createdNodes + 1] = nodeGenerated
									count = count + 1
								end
							end
						end
					end
				end

				YieldCheck()
			end

			if count > 0 then
				tool:BuildNodeGrid()
				YieldCheck()

				for i = 1, #createdNodes do
					local nodeID = createdNodes[i]
					local node = nodes[nodeID]
					if node then
						local nearby = nodeGrid:Query(node.pos, step * 1.5, nodes)
						for otherID, otherNode in pairs(nearby) do
							if otherID ~= nodeID and otherNode.type == Constants.NODE_TYPE_GROUND then
								if not tool:HasLink(nodeID, otherID) then
									if tool:IsLineClear(node.pos, otherNode.pos, true, 0) then
										tool:AddLink(nodeID, otherID)
									end
								end
							end

							YieldCheck()
						end
					end

					YieldCheck()
				end
			end

			tool:BuildNodeGrid()
			tool:BuildZone()
			tool:ClearEffects()

			if count > 0 then
				notification.AddLegacy("Generated " .. count .. " ground nodes from grid.", 0, 8)
			else
				notification.AddLegacy("Failed to generate ground nodes using grid.", 1, 8)
			end
		end)
	end

	local expectedChunks
	local receivedChunks = {}
	net.Receive("nodegraph_gen_client", function()
		local totalChunks = net.ReadUInt(16)
		local chunkIndex = net.ReadUInt(16)
		local chunkSize = net.ReadUInt(32)
		local chunkData = net.ReadData(chunkSize)
		if chunkIndex == 1 then
			expectedChunks = totalChunks
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
			if not json then
				return
			end

			receivedChunks = {}

			local wep = LocalPlayer():GetActiveWeapon()
			local tool = (IsValid(wep) and wep:GetClass() == "gmod_tool" and wep:GetMode() == "neplus") and
				wep:GetToolObject() or nil

			if not tool then
				return
			end

			local posTable = util.JSONToTable(json)
			Generation.ProcessReceivedNavmeshNodes(tool, posTable)
		end
	end)
end

if SERVER then
	util.AddNetworkString("nodegraph_gen_server")
	util.AddNetworkString("nodegraph_gen_client")

	function Generation.GetAllNavAreas(genSettings)
		local eligibleNavAreas = {}
		local eligibleNavAreaIds = {}
		local minimalAreaSize = genSettings.NavAreaSize
		local crouchEnabled = genSettings.CrouchAreas
		local jumpEnabled = genSettings.JumpAreas
		local waterEnabled = genSettings.WaterAreas
		local jumpLinksEnabled = genSettings.GenJumpLinks

		local function IsAreaEligible(navArea)
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
			if IsAreaEligible(navArea) then
				local areaData = {
					id = navArea:GetID(),
					pos = navArea:GetCenter(),
					adjacents = {},
					jumps = {}
				}

				eligibleNavAreas[#eligibleNavAreas + 1] = areaData
				eligibleNavAreaIds[navArea:GetID()] = true
			end
		end

		for i = 1, #eligibleNavAreas do
			local areaData = eligibleNavAreas[i]
			local navArea = navmesh.GetNavAreaByID(areaData.id)
			if not navArea then continue end

			local adjacentAreas = navArea:GetAdjacentAreas()
			for j = 1, #adjacentAreas do
				local adjacentArea = adjacentAreas[j]
				local adjacentId = adjacentArea:GetID()

				if eligibleNavAreaIds[adjacentId] then
					local heightChange = math.abs(navArea:ComputeAdjacentConnectionHeightChange(adjacentArea))

					if heightChange <= 18 then
						areaData.adjacents[#areaData.adjacents + 1] = adjacentId
					else
						if jumpLinksEnabled then
							areaData.jumps[#areaData.jumps + 1] = adjacentId
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
				if #finalAreas < Constants.MAX_NODES then
					finalAreas[#finalAreas + 1] = areaData
					usedAreaIds[areaData.id] = true
				else
					remainingAreas[#remainingAreas + 1] = areaData
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

							finalAreas[#finalAreas + 1] = remainingArea
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
	net.Receive("nodegraph_gen_server", function()
		local plyEntity = net.ReadEntity()
		if not IsValid(plyEntity) then
			return
		end

		local genSettings = net.ReadTable()
		if not genSettings then
			return
		end

		local posTable = Generation.GetAllNavAreas(genSettings) or {}
		local json = util.TableToJSON(posTable)
		local compressed = util.Compress(json)
		local totalChunks = math.ceil(#compressed / chunkSize)
		for i = 1, totalChunks do
			local startPos = (i - 1) * chunkSize + 1
			local endPos = math.min(i * chunkSize, #compressed)
			local chunkData = string.sub(compressed, startPos, endPos)
			timer.Simple(i * 0.1, function()
				if not IsValid(plyEntity) then
					return
				end

				net.Start("nodegraph_gen_client")
				net.WriteUInt(totalChunks, 16)
				net.WriteUInt(i, 16)
				net.WriteUInt(#chunkData, 32)
				net.WriteData(chunkData, #chunkData)
				net.Send(plyEntity)
			end)
		end
	end)
end

return Generation
