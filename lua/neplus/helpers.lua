function IsMapNodeable()
	local path = "maps/graphs/" .. game.GetMap() .. ".ain"
	if file.Exists(path, "BSP") then
		return false
	end

	return true
end

function RecreateNodegraph()
	local path2 = "maps/graphs/" .. game.GetMap() .. ".ain"
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
	path2 = "nodegraph/" .. game.GetMap() .. ".txt"
	F2 = file.Open(path2, "rb", "DATA")
	if F2 then
		F2:ReadLong()
		version2 = F2:ReadLong()
		size2 = F2:ReadLong()
		F2:Close()
	else
		return false
	end

	return version1 ~= version2 or size1 ~= size2
end

function GenerateNodeableMap()
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
	local searchLen = #searchStr
	local chunkSize = 1024 * 64
	local buffer = ""

	while not inFile:EndOfFile() do
		local chunk = inFile:Read(chunkSize)
		if not chunk or chunk == "" then
			break
		end

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
	end

	if #buffer > 0 then
		outFile:Write(string.Replace(buffer, searchStr, replaceStr))
	end

	inFile:Close()
	outFile:Close()
	return true
end

local function FireOpenOnEnt(a)
	local x = ents.FindByClass(a)
	for i = 1, #x do
		local v = x[i]
		v:Fire("open")
	end
end

local function RemoveEntities()
	if game.GetMap() == "pl_thundermountain" then
		return
	end

	local x = ents.FindByClass("func_brush")
	for i = 1, #x do
		local v = x[i]
		v:Fire("break")
		v:Fire("disable")
		if string.find(v:GetName(), "door") then
			v:Remove()
		end
	end

	RunConsoleCommand("ent_remove_all", "func_door")
	RunConsoleCommand("ent_remove_all", "func_door_rotating")
	RunConsoleCommand("ent_remove_all", "prop_door")
	RunConsoleCommand("ent_remove_all", "prop_door_rotating")
	RunConsoleCommand("ent_remove_all", "func_breakable")
	if game.GetMap() == "pl_millstone_event" then
		RunConsoleCommand("ent_remove_all", "func_brush")
	end

	local x = ents.FindByClass("prop_dynamic")
	for i = 1, #x do
		local v = x[i]
		local nm = v:GetName()
		if string.find(nm, "door") or string.find(nm, "barrier") or nm == "cap2_signs_back_props" then
			v:Remove()
		end
	end
end

function OpenAndRemoveDoors()
	FireOpenOnEnt("func_door")
	FireOpenOnEnt("func_door_rotating")
	FireOpenOnEnt("prop_door")
	FireOpenOnEnt("prop_door_rotating")
	timer.Simple(2, function()
		RemoveEntities()
	end)
end
