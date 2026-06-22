local Grid = {}
Grid.__index = Grid

function Grid:New(cellSize)
	local grid = setmetatable({}, Grid)
	grid.cellSize = cellSize or 1024
	grid.invCellSize = 1 / grid.cellSize
	grid.cells = {}

	return grid
end

function Grid:GetCellCoords(pos)
	local s = self.invCellSize
	return math.floor(pos.x * s), math.floor(pos.y * s), math.floor(pos.z * s)
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
	if not node then
		return
	end

	local pos = node.pos
	if not pos then
		return
	end

	local x, y, z = self:GetCellCoords(pos)
	local cz = self:_ensureCell3D(x, y, z)
	cz[nodeID] = true
	node.cx, node.cy, node.cz = x, y, z
end

function Grid:Remove(nodeID, node)
	if not node then
		return
	end

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
	if not pos or not radius or radius <= 0 or not nodes then
		return {}
	end

	local result = {}

	local radiusSqr = radius * radius
	local invSize = self.invCellSize

	local minX = math.floor((pos.x - radius) * invSize)
	local minY = math.floor((pos.y - radius) * invSize)
	local minZ = math.floor((pos.z - radius) * invSize)

	local maxX = math.floor((pos.x + radius) * invSize)
	local maxY = math.floor((pos.y + radius) * invSize)
	local maxZ = math.floor((pos.z + radius) * invSize)

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
										if dx * dx + dy * dy + dz * dz <= radiusSqr then
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
	if not nodes then
		return
	end

	self:Clear()
	for id, node in pairs(nodes) do
		self:Insert(id, node)
	end
end

function Grid:Clear()
	self.cells = {}
end

return Grid
