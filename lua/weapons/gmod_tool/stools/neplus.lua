------------------------------------
-- Tool Information
------------------------------------

TOOL.Category = "Map"
TOOL.Name = "#tool.neplus.name"
TOOL.Information = { { name = "left" } }

if CLIENT then
    language.Add("tool.neplus.name", "Nodegraph Editor+")
    language.Add("tool.neplus.desc", "Allows you to edit a map's nodegraph")
    language.Add("tool.neplus.left", "Create/delete a node at crosshair position")
    language.Add("tool.neplus.right", "Create a node at player position")
end


------------------------------------
-- Server-Side Functions
------------------------------------

if SERVER then
    util.AddNetworkString("neplus_calltoclient")
end


------------------------------------
-- Client-Side Functions
------------------------------------

if CLIENT then
    net.Receive("neplus_calltoclient", function(len)
        local func = net.ReadString()
        local tool = LocalPlayer():GetTool("neplus")

        if tool and tool[func] then
            if func == "LeftClick" or func == "RightClick" then
                tool[func](tool, LocalPlayer():GetEyeTrace())
            else
                tool[func](tool)
            end
        end
    end)
end


------------------------------------
-- Tool Server-Side Functions
------------------------------------

if SERVER then
    function TOOL:LeftClick(trace)
        if game.SinglePlayer() then
            net.Start("neplus_calltoclient")
            net.WriteString("LeftClick")
            net.Send(self:GetOwner())
        end

        return true
    end

    function TOOL:RightClick(trace)
        if game.SinglePlayer() then
            net.Start("neplus_calltoclient")
            net.WriteString("RightClick")
            net.Send(self:GetOwner())
        end

        return true
    end
end


------------------------------------
-- Tool Client-Side Functions
------------------------------------

if CLIENT then
    function TOOL:LeftClick(trace)
        print("Called LeftClick from client")
        return true
    end

    function TOOL:RightClick(trace)
        print("Called RightClick from client")
        return true
    end
end
