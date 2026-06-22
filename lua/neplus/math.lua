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
