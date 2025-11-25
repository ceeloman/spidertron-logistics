-- Terrain detection utilities for pathfinding
-- Functions for water, cliff, and enemy detection

local terrain = {}

-- Check if a position is on or near water
function terrain.is_position_on_water(surface, position, check_radius)
	check_radius = check_radius or 1.5  -- Default: check 1.5 tiles radius
	
	-- Check the center tile
	local tile = surface.get_tile(math.floor(position.x), math.floor(position.y))
	if tile and tile.valid then
		local tile_name = tile.name:lower()
		if tile_name:find("water") or tile_name:find("lava") or tile_name:find("lake") or tile_name:find("ammoniacal") then
			return true
		end
	end
	
	-- Check surrounding tiles within radius
	for dx = -math.ceil(check_radius), math.ceil(check_radius) do
		for dy = -math.ceil(check_radius), math.ceil(check_radius) do
			local dist = math.sqrt(dx^2 + dy^2)
			if dist <= check_radius then
				local check_pos = {x = math.floor(position.x + dx), y = math.floor(position.y + dy)}
				local check_tile = surface.get_tile(check_pos.x, check_pos.y)
				if check_tile and check_tile.valid then
					local tile_name = check_tile.name:lower()
					if tile_name:find("water") or tile_name:find("lava") or tile_name:find("lake") or tile_name:find("ammoniacal") then
						return true
					end
				end
			end
		end
	end
	
	return false
end

-- Check if a position is directly on water (exact tile only, no radius)
function terrain.is_position_directly_on_water(surface, position)
	local tile = surface.get_tile(math.floor(position.x), math.floor(position.y))
	if tile and tile.valid then
		local tile_name = tile.name:lower()
		return tile_name:find("water") or tile_name:find("lava") or tile_name:find("lake") or tile_name:find("ammoniacal")
	end
	return false
end

-- Check if a position is near a corner cliff (2+ cliffs at different angles)
function terrain.is_position_near_corner_cliff(surface, position, check_radius)
	check_radius = check_radius or 2.5  -- Default: check 2.5 tiles radius
	
	local nearby_cliffs = surface.find_entities_filtered{
		position = position,
		radius = check_radius,
		type = "cliff"
	}
	
	-- Need at least 2 cliffs to form a corner
	if #nearby_cliffs < 2 then
		return false
	end
	
	-- Check if cliffs are at different angles (indicating a corner)
	-- If cliffs are aligned in a line, it's a straight cliff (OK to cross)
	-- If cliffs are at different angles, it's a corner (avoid)
	local angles = {}
	for _, cliff in ipairs(nearby_cliffs) do
		local dx = cliff.position.x - position.x
		local dy = cliff.position.y - position.y
		local angle = math.atan2(dy, dx)
		-- Normalize angle to 0-2π
		if angle < 0 then
			angle = angle + 2 * math.pi
		end
		-- Round to nearest 45 degrees to group similar angles
		local rounded_angle = math.floor((angle / math.pi * 4) + 0.5) * (math.pi / 4)
		angles[rounded_angle] = (angles[rounded_angle] or 0) + 1
	end
	
	-- If we have cliffs at 2+ different angle groups, it's a corner
	local distinct_angles = 0
	for _ in pairs(angles) do
		distinct_angles = distinct_angles + 1
	end
	
	return distinct_angles >= 2
end

-- Check if a waypoint path segment is traveling parallel to a cliff
function terrain.is_waypoint_parallel_to_cliff(surface, waypoint_pos, prev_pos, next_pos, check_radius)
	check_radius = check_radius or 2.0  -- Check 2 tiles radius
	
	-- Calculate path direction
	local path_dx, path_dy
	if prev_pos and next_pos then
		-- Use both directions to get average
		local dx1 = next_pos.x - waypoint_pos.x
		local dy1 = next_pos.y - waypoint_pos.y
		local dx2 = waypoint_pos.x - prev_pos.x
		local dy2 = waypoint_pos.y - prev_pos.y
		path_dx = (dx1 + dx2) / 2
		path_dy = (dy1 + dy2) / 2
	elseif next_pos then
		path_dx = next_pos.x - waypoint_pos.x
		path_dy = next_pos.y - waypoint_pos.y
	elseif prev_pos then
		path_dx = waypoint_pos.x - prev_pos.x
		path_dy = waypoint_pos.y - prev_pos.y
	else
		return false  -- Can't determine direction
	end
	
	local path_length = math.sqrt(path_dx^2 + path_dy^2)
	if path_length < 0.1 then
		return false  -- Too short to determine direction
	end
	
	-- Normalize direction vector
	path_dx = path_dx / path_length
	path_dy = path_dy / path_length
	
	-- Find nearby cliffs
	local nearby_cliffs = surface.find_entities_filtered{
		position = waypoint_pos,
		radius = check_radius,
		type = "cliff"
	}
	
	if #nearby_cliffs == 0 then
		return false
	end
	
	-- Check if any cliff is aligned parallel to the path
	for _, cliff in ipairs(nearby_cliffs) do
		local cliff_dx = cliff.position.x - waypoint_pos.x
		local cliff_dy = cliff.position.y - waypoint_pos.y
		local cliff_dist = math.sqrt(cliff_dx^2 + cliff_dy^2)
		
		if cliff_dist > 0.1 then
			-- Normalize cliff direction
			cliff_dx = cliff_dx / cliff_dist
			cliff_dy = cliff_dy / cliff_dist
			
			-- Calculate dot product (parallel = close to 1 or -1)
			local dot_product = math.abs(path_dx * cliff_dx + path_dy * cliff_dy)
			
			-- If dot product > 0.7, path is roughly parallel to cliff
			if dot_product > 0.7 then
				return true
			end
		end
	end
	
	return false
end

-- Check if a waypoint is crossing a straight cliff (2-3 cliffs in a line)
function terrain.is_waypoint_crossing_straight_cliff(surface, waypoint_pos, prev_pos, next_pos, check_radius)
	check_radius = check_radius or 2.5
	
	local nearby_cliffs = surface.find_entities_filtered{
		position = waypoint_pos,
		radius = check_radius,
		type = "cliff"
	}
	
	-- Need at least 2 cliffs to be a straight cliff line
	if #nearby_cliffs < 2 then
		return false
	end
	
	-- Calculate path direction (perpendicular to path = crossing direction)
	local path_dx, path_dy
	if prev_pos and next_pos then
		local dx1 = next_pos.x - waypoint_pos.x
		local dy1 = next_pos.y - waypoint_pos.y
		local dx2 = waypoint_pos.x - prev_pos.x
		local dy2 = waypoint_pos.y - prev_pos.y
		path_dx = (dx1 + dx2) / 2
		path_dy = (dy1 + dy2) / 2
	elseif next_pos then
		path_dx = next_pos.x - waypoint_pos.x
		path_dy = next_pos.y - waypoint_pos.y
	elseif prev_pos then
		path_dx = waypoint_pos.x - prev_pos.x
		path_dy = waypoint_pos.y - prev_pos.y
	else
		return false
	end
	
	local path_length = math.sqrt(path_dx^2 + path_dy^2)
	if path_length < 0.1 then
		return false
	end
	
	-- Normalize path direction
	path_dx = path_dx / path_length
	path_dy = path_dy / path_length
	
	-- Check if cliffs are aligned in a line (perpendicular to path = crossing)
	local aligned_count = 0
	for _, cliff in ipairs(nearby_cliffs) do
		local cliff_dx = cliff.position.x - waypoint_pos.x
		local cliff_dy = cliff.position.y - waypoint_pos.y
		local cliff_dist = math.sqrt(cliff_dx^2 + cliff_dy^2)
		
		if cliff_dist > 0.1 then
			cliff_dx = cliff_dx / cliff_dist
			cliff_dy = cliff_dy / cliff_dist
			
			-- For crossing, we want cliffs perpendicular to path (dot product close to 0)
			local dot_product = math.abs(path_dx * cliff_dx + path_dy * cliff_dy)
			
			-- If dot product < 0.5, cliff is roughly perpendicular (crossing)
			if dot_product < 0.5 then
				aligned_count = aligned_count + 1
			end
		end
	end
	
	-- If 2+ cliffs are aligned perpendicular to path, it's a straight cliff crossing (OK)
	return aligned_count >= 2
end

-- Check if a position is near an enemy nest (biters/spitters)
function terrain.is_position_near_enemy_nest(surface, position, check_radius)
	check_radius = check_radius or 10  -- Default: check 10 tiles radius
	
	local nearby_nests = surface.find_entities_filtered{
		position = position,
		radius = check_radius,
		type = {"unit-spawner", "turret"}  -- Spawners and worms
	}
	
	return #nearby_nests > 0
end

return terrain

