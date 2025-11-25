-- Pathfinding with terrain awareness (water, cliffs, enemies)
-- Uses Factorio's pathfinding API to generate waypoints and queue them

local terrain = require('lib.terrain')
local constants = require('lib.constants')
local logging = require('lib.logging')
local rendering = require('lib.rendering')

local pathing = {}

-- Check if spider can traverse water/lava
-- Water traversal depends on leg collision mask, not body
-- Legs with "player" layer collide with water (water tiles use "player" layer)
function pathing.can_spider_traverse_water(spider)
	if not spider or not spider.valid then return false end
	
	-- Check if this is a SpiderVehicle (has get_spider_legs method)
	local success, legs = pcall(function()
		return spider.get_spider_legs()
	end)
	
	if not success or not legs or #legs == 0 then
		-- No legs = can traverse water (hovering/legless spider)
		-- logging.info("Pathing", "Spider " .. spider.unit_number .. " (" .. spider.name .. ") has no legs, CAN traverse water")
		return true
	end
	
	-- Get the first leg's collision mask (all legs should have the same collision mask)
	local first_leg = legs[1]
	if not first_leg or not first_leg.valid then
		-- logging.warn("Pathing", "Spider " .. spider.unit_number .. " first leg is invalid")
		return false
	end
	
	local leg_prototype = first_leg.prototype
	if not leg_prototype then
		-- logging.warn("Pathing", "Spider " .. spider.unit_number .. " leg has no prototype")
		return false
	end
	
	-- Get the leg's collision mask
	local leg_collision_mask = leg_prototype.collision_mask
	if not leg_collision_mask or not leg_collision_mask.layers then
		-- logging.warn("Pathing", "Spider " .. spider.unit_number .. " leg has no collision_mask.layers")
		return false
	end
	
	-- Check if legs collide with "player" layer (water tiles have "player" in their collision mask)
	-- If legs have "player" in collision mask, they will collide with water = cannot traverse
	if leg_collision_mask.layers["player"] then
		-- logging.info("Pathing", "Spider " .. spider.unit_number .. " legs have 'player' in collision mask, CANNOT traverse water")
		return false
	else
		-- logging.info("Pathing", "Spider " .. spider.unit_number .. " legs do NOT have 'player' in collision mask, CAN traverse water")
		return true
	end
end

-- Check if spider is large enough to cross cliffs
local function can_spider_cross_cliffs(spider)
	if not spider or not spider.valid then return false end
	local prototype = spider.prototype
	if not prototype then return false end
	
	local collision_box = prototype.collision_box
	if not collision_box then return false end
	
	-- Calculate spider size from collision box
	local width = collision_box.right_bottom.x - collision_box.left_top.x
	local height = collision_box.right_bottom.y - collision_box.left_top.y
	local size = math.max(width, height)
	
	-- Threshold: spiders with size >= 2.0 can cross cliffs
	-- Smaller spiders should avoid cliffs
	return size >= 2.0
end

-- Get collision mask for pathfinding based on spider capabilities
local function get_path_collision_mask(spider)
	local can_water = pathing.can_spider_traverse_water(spider)
	local can_cliffs = can_spider_cross_cliffs(spider)
	
	-- Get the spider's actual collision mask to use as base
	local prototype = spider.prototype
	local base_collision_mask = {}
	if prototype and prototype.collision_mask and prototype.collision_mask.layers then
		-- Copy the spider's collision mask layers (it's a dictionary)
		for layer_name, _ in pairs(prototype.collision_mask.layers) do
			base_collision_mask[layer_name] = true
		end
	end
	
	-- If spider can't traverse water, ensure water_tile and lava_tile are in collision mask
	if not can_water then
		base_collision_mask["water_tile"] = true
		base_collision_mask["lava_tile"] = true
		-- logging.debug("Pathing", "Spider " .. spider.unit_number .. " cannot traverse water/lava, adding water_tile and lava_tile to collision mask")
	else
		-- logging.debug("Pathing", "Spider " .. spider.unit_number .. " can traverse water")
	end
	
	-- If spider can't cross cliffs, ensure cliff is in collision mask
	if not can_cliffs then
		base_collision_mask["cliff"] = true
		-- logging.debug("Pathing", "Spider " .. spider.unit_number .. " cannot cross cliffs, adding cliff to collision mask")
	end
	
	-- Keep as dictionary format for request_path (API requires dictionary, not array)
	-- layers must be a dictionary where keys are layer names and values are always true
	local layer_names = {}
	for layer_name, _ in pairs(base_collision_mask) do
		table.insert(layer_names, layer_name)
	end
	-- logging.debug("Pathing", "Spider " .. spider.unit_number .. " collision mask layers: " .. table.concat(layer_names, ", "))
	
	return {
		layers = base_collision_mask,  -- Keep as dictionary, not array
		colliding_with_tiles_only = true,
		consider_tile_transitions = true
	}
end

-- Request pathfinding and queue waypoints
function pathing.set_smart_destination(spider, destination_pos, destination_entity)
	if not spider or not spider.valid then 
		logging.error("Pathing", "Invalid spider")
		return false 
	end
	if not destination_pos then 
		logging.error("Pathing", "No destination position")
		return false 
	end
	
	local surface = spider.surface
	local force = spider.force
	local start_pos = spider.position
	
	-- Check if destination is on water
	local dest_tile = surface.get_tile(math.floor(destination_pos.x), math.floor(destination_pos.y))
	local is_water = false
	if dest_tile and dest_tile.valid then
		local tile_name = dest_tile.name:lower()
		is_water = tile_name:find("water") or tile_name:find("lava") or tile_name:find("lake") or tile_name:find("ammoniacal")
	end
	-- Check if destination is too close - just go straight
	local distance = math.sqrt((start_pos.x - destination_pos.x)^2 + (start_pos.y - destination_pos.y)^2)
	if distance < 5 then
		-- Close destination, go straight
		spider.add_autopilot_destination(destination_pos)
		return true
	end
	
	-- Check if chunks are generated
	local start_chunk = {
		x = math.floor(start_pos.x / 32),
		y = math.floor(start_pos.y / 32)
	}
	local end_chunk = {
		x = math.floor(destination_pos.x / 32),
		y = math.floor(destination_pos.y / 32)
	}
	
	if not surface.is_chunk_generated(start_chunk) or not surface.is_chunk_generated(end_chunk) then
		-- Chunks not generated - can't pathfind, cancel
		return false
	end
	
	-- Get spider prototype for bounding box
	local prototype = spider.prototype
	local bounding_box = {{-0.5, -0.5}, {0.5, 0.5}}
	if prototype and prototype.collision_box then
		bounding_box = prototype.collision_box
	end
	
	-- Get collision mask for pathfinding
	local collision_mask = get_path_collision_mask(spider)
	
	-- Check if path will cross water
	local path_crosses_water = false
	if not is_water then
		-- Check a few points along the path to see if it crosses water
		local steps = 10
		for i = 1, steps do
			local t = i / steps
			local check_x = start_pos.x + (destination_pos.x - start_pos.x) * t
			local check_y = start_pos.y + (destination_pos.y - start_pos.y) * t
			local check_tile = surface.get_tile(math.floor(check_x), math.floor(check_y))
			if check_tile and check_tile.valid then
				local tile_name = check_tile.name:lower()
				if tile_name:find("water") or tile_name:find("lava") or tile_name:find("lake") or tile_name:find("ammoniacal") then
					path_crosses_water = true
					-- logging.warn("Pathing", "  WARNING: Path crosses water at (" .. math.floor(check_x) .. "," .. math.floor(check_y) .. ")")
					break
				end
			end
		end
	end
	
	-- Request pathfinding
	-- Start with standard settings
	local request_id = surface.request_path{
		start = start_pos,
		goal = destination_pos,
		force = force,
		bounding_box = bounding_box,
		collision_mask = collision_mask,
		radius = 20,
		path_resolution_modifier = -3,
		pathfind_flags = {
			cache = false,
			prefer_straight_paths = false,
			low_priority = false
		}
	}
	
	-- logging.info("Pathing", "  Path request ID: " .. request_id)
	
	-- Store retry attempt count
	local retry_count = 0
	if request_id then
		storage.path_requests = storage.path_requests or {}
		storage.path_requests[request_id] = storage.path_requests[request_id] or {}
		storage.path_requests[request_id].retry_count = retry_count
	end
	
	if not request_id then
		-- Pathfinding request failed - can't proceed, cancel
		return false
	end
	
	-- Store path request data
	storage.path_requests = storage.path_requests or {}
	storage.path_requests[request_id] = {
		spider_unit_number = spider.unit_number,
		surface_index = surface.index,
		destination_pos = destination_pos,
		destination_entity = destination_entity
	}
	
	return true
end

-- Calculate angle between three points (in degrees)
-- Returns angle at middle point: 0° = straight, 180° = U-turn
local function calculate_angle(p1, p2, p3)
	local dx1 = p2.x - p1.x
	local dy1 = p2.y - p1.y
	local dx2 = p3.x - p2.x
	local dy2 = p3.y - p2.y
	
	local len1 = math.sqrt(dx1^2 + dy1^2)
	local len2 = math.sqrt(dx2^2 + dy2^2)
	
	if len1 < 0.1 or len2 < 0.1 then
		return 0  -- Straight line (no turn)
	end
	
	-- Normalize vectors
	dx1, dy1 = dx1 / len1, dy1 / len1
	dx2, dy2 = dx2 / len2, dy2 / len2
	
	-- Calculate angle using dot product
	local dot = dx1 * dx2 + dy1 * dy2
	dot = math.max(-1, math.min(1, dot))  -- Clamp to [-1, 1]
	local angle = math.acos(dot) * 180 / math.pi
	
	return angle
end

-- Simplify waypoints: wider spacing on straight paths, tighter on turns
-- Filters water waypoints if spider can't traverse water
local function simplify_waypoints(surface, waypoints, start_pos, can_water, can_cliffs)
	if not waypoints or #waypoints == 0 then
		return {}
	end
	
	-- First pass: filter out any water waypoints if spider can't traverse water
	if not can_water then
		local filtered_waypoints = {}
		for _, waypoint in ipairs(waypoints) do
			local waypoint_pos = waypoint.position or waypoint
			local is_on_water = terrain.is_position_on_water(surface, waypoint_pos, 3.0)
			local exact_tile = surface.get_tile(math.floor(waypoint_pos.x), math.floor(waypoint_pos.y))
			local exact_is_water = false
			if exact_tile and exact_tile.valid then
				local tile_name = exact_tile.name:lower()
				exact_is_water = tile_name:find("water") or tile_name:find("lava") or tile_name:find("lake") or tile_name:find("ammoniacal")
			end
			
			if not is_on_water and not exact_is_water then
				table.insert(filtered_waypoints, waypoint)
			else
				-- logging.warn("Pathing", "  Simplification: Filtered water waypoint at (" .. string.format("%.1f", waypoint_pos.x) .. "," .. string.format("%.1f", waypoint_pos.y) .. ")")
			end
		end
		waypoints = filtered_waypoints
		if #waypoints == 0 then
			return {}
		end
	end
	
	-- Configuration: minimum distances for waypoint spacing
	local MIN_DISTANCE_EASY = 18  -- Open terrain: skip waypoints closer than 18 tiles
	local MIN_DISTANCE_DIFFICULT = 8  -- Difficult terrain: skip waypoints closer than 8 tiles
	local MAX_ANGLE_STRAIGHT = 20  -- If angle < 20°, consider it straight (can skip more)
	local MIN_ANGLE_TURN = 40  -- If angle > 40°, it's a turn (keep waypoint)
	
	local simplified = {}
	local last_kept_pos = start_pos
	
	-- Always keep first waypoint
	if #waypoints > 0 then
		local first_wp = waypoints[1].position or waypoints[1]
		table.insert(simplified, {x = first_wp.x, y = first_wp.y, locked = waypoints[1].locked or false})
		last_kept_pos = first_wp
	end
	
	-- Process middle waypoints with look-ahead
	local i = 2
	while i < #waypoints do
		local waypoint = waypoints[i]
		local waypoint_pos = waypoint.position or waypoint
		local distance = math.sqrt(
			(waypoint_pos.x - last_kept_pos.x)^2 + 
			(waypoint_pos.y - last_kept_pos.y)^2
		)
		
		-- Determine terrain difficulty at this waypoint
		local is_difficult = false
		if not can_water and terrain.is_position_on_water(surface, waypoint_pos, 3) then
			is_difficult = true
		elseif not can_cliffs and terrain.is_position_near_corner_cliff(surface, waypoint_pos, 3) then
			is_difficult = true
		end
		
		-- Calculate path curvature at this waypoint
		local angle = 0  -- Default to straight
		if i > 1 and i < #waypoints then
			local prev_wp = waypoints[i-1]
			local prev_pos = prev_wp.position or prev_wp
			local next_wp = waypoints[i+1]
			local next_pos = next_wp.position or next_wp
			angle = calculate_angle(prev_pos, waypoint_pos, next_pos)
		elseif i == #waypoints - 1 then
			-- Last waypoint before final - check angle from previous
			local prev_wp = waypoints[i-1]
			local prev_pos = prev_wp.position or prev_wp
			local last_wp = waypoints[#waypoints]
			local next_pos = last_wp.position or last_wp
			angle = calculate_angle(prev_pos, waypoint_pos, next_pos)
		end
		
		-- Adjust minimum distance based on curvature
		local base_min_distance = is_difficult and MIN_DISTANCE_DIFFICULT or MIN_DISTANCE_EASY
		local min_distance = base_min_distance
		
		-- If path is very straight (small angle), increase spacing significantly
		if angle < MAX_ANGLE_STRAIGHT then
			min_distance = base_min_distance * 1.8  -- 80% more spacing for straight paths
		-- If path has a turn (large angle), decrease spacing
		elseif angle > MIN_ANGLE_TURN then
			min_distance = base_min_distance * 0.5  -- 50% less spacing for sharp turns
		end
		
		-- Look ahead: can we skip this waypoint and go directly to the next one?
		local should_keep = false
		if distance >= min_distance then
			-- Distance is sufficient, but check if we can skip ahead further
			if i < #waypoints - 1 then
				local next_wp = waypoints[i + 1]
				local next_waypoint = next_wp.position or next_wp
				local distance_to_next = math.sqrt(
					(next_waypoint.x - last_kept_pos.x)^2 + 
					(next_waypoint.y - last_kept_pos.y)^2
				)
				
				-- Calculate angle if we skip this waypoint
				local skip_angle = 180  -- Default to worst case
				if i + 1 < #waypoints then
					-- There's a waypoint after next, check if path is straight
					local next_next_wp = waypoints[i + 2]
					local next_next = next_next_wp.position or next_next_wp
					skip_angle = calculate_angle(last_kept_pos, next_waypoint, next_next)
				end
				
				-- If skipping creates a reasonably straight path, skip this waypoint
				-- Only skip if the path remains straight and distance is sufficient
				if distance_to_next >= min_distance and skip_angle < MAX_ANGLE_STRAIGHT * 1.5 then
					i = i + 1  -- Skip to next waypoint
					goto continue
				end
			end
			should_keep = true
		elseif angle > MIN_ANGLE_TURN then
			-- Sharp turn - keep waypoint even if distance is small
			should_keep = true
		end
		
		if should_keep then
			table.insert(simplified, {x = waypoint_pos.x, y = waypoint_pos.y, locked = waypoint.locked or false})
			last_kept_pos = waypoint_pos
		end
		
		::continue::
		i = i + 1
	end
	
	-- Always keep last waypoint (if there was more than one)
	if #waypoints > 1 then
		local last_wp = waypoints[#waypoints]
		local last_waypoint = last_wp.position or last_wp
		local distance_to_last = math.sqrt(
			(last_waypoint.x - last_kept_pos.x)^2 + 
			(last_waypoint.y - last_kept_pos.y)^2
		)
		
		if distance_to_last >= 3 then
			table.insert(simplified, {x = last_waypoint.x, y = last_waypoint.y, locked = last_wp.locked or false})
		elseif #simplified > 0 then
			-- If last waypoint is too close, replace the previous one with it
			-- This ensures we always reach the destination
			simplified[#simplified] = {x = last_waypoint.x, y = last_waypoint.y, locked = last_wp.locked or false}
		else
			table.insert(simplified, {x = last_waypoint.x, y = last_waypoint.y, locked = last_wp.locked or false})
		end
	end
	
	return simplified
end

-- Smooth waypoints by cutting corners (skips locked waypoints)
local function smooth_waypoints(waypoints, start_pos)
	if not waypoints or #waypoints < 2 then
		return waypoints
	end
	
	local smoothed = {}
	local MIN_ANGLE_FOR_SMOOTHING = 5  -- Very low threshold - smooth almost all waypoints
	local SMOOTH_STRAIGHT_SEGMENTS = true  -- Also smooth straight segments
	local SMOOTH_ALL_WAYPOINTS = true  -- Smooth all waypoints, even very straight ones
	
	-- Always keep first waypoint
	table.insert(smoothed, waypoints[1])
	
	-- Process middle waypoints to cut corners
	for i = 2, #waypoints - 1 do
		local prev_pos = waypoints[i - 1]
		local curr_pos = waypoints[i]
		local next_pos = waypoints[i + 1]
		
		-- Check if this waypoint is locked (detour point) - if so, don't smooth it
		if curr_pos.locked then
			-- logging.debug("Pathing", "  Skipping smoothing for locked waypoint at (" .. string.format("%.1f", curr_pos.x) .. "," .. string.format("%.1f", curr_pos.y) .. ")")
			table.insert(smoothed, curr_pos)
			goto continue
		end
		
		-- Calculate vectors
		local dx1 = curr_pos.x - prev_pos.x
		local dy1 = curr_pos.y - prev_pos.y
		local dx2 = next_pos.x - curr_pos.x
		local dy2 = next_pos.y - curr_pos.y
		
		local len1 = math.sqrt(dx1^2 + dy1^2)
		local len2 = math.sqrt(dx2^2 + dy2^2)
		
		if len1 > 0.1 and len2 > 0.1 then
			-- Normalize direction vectors
			local dir1_x, dir1_y = dx1 / len1, dy1 / len1
			local dir2_x, dir2_y = dx2 / len2, dy2 / len2
			
			-- Calculate angle at this waypoint
			local dot = dir1_x * dir2_x + dir1_y * dir2_y
			dot = math.max(-1, math.min(1, dot))
			local angle = math.acos(dot) * 180 / math.pi
			
			-- Smooth all waypoints, with varying intensity based on turn angle
			local smoothed_pos
			if angle > MIN_ANGLE_FOR_SMOOTHING and angle < 150 then
				-- Turn detected - very aggressive corner cutting
				local cut_factor = 0.75  -- Very aggressive cutting
				local turn_sharpness = math.min(1.0, (angle - MIN_ANGLE_FOR_SMOOTHING) / 60.0)
				cut_factor = cut_factor * (0.7 + turn_sharpness * 0.3)  -- Range: 0.7-1.0 for maximum smoothness
				
				-- Calculate points partway along each segment
				local point1_x = prev_pos.x + (curr_pos.x - prev_pos.x) * (1.0 - cut_factor)
				local point1_y = prev_pos.y + (curr_pos.y - prev_pos.y) * (1.0 - cut_factor)
				local point2_x = curr_pos.x + (next_pos.x - curr_pos.x) * cut_factor
				local point2_y = curr_pos.y + (next_pos.y - curr_pos.y) * cut_factor
				
				-- The smoothed waypoint is the midpoint between these two points
				smoothed_pos = {
					x = (point1_x + point2_x) / 2,
					y = (point1_y + point2_y) / 2,
					locked = false
				}
			elseif SMOOTH_STRAIGHT_SEGMENTS and (angle <= MIN_ANGLE_FOR_SMOOTHING or SMOOTH_ALL_WAYPOINTS) then
				-- Straight or nearly straight path - apply stronger smoothing
				local light_smooth = 0.3  -- Increased from 0.15 for smoother straight segments
				smoothed_pos = {
					x = curr_pos.x * (1.0 - light_smooth) + (prev_pos.x + next_pos.x) / 2 * light_smooth,
					y = curr_pos.y * (1.0 - light_smooth) + (prev_pos.y + next_pos.y) / 2 * light_smooth,
					locked = false
				}
			else
				-- Very sharp turn (> 150°) - keep original waypoint
				smoothed_pos = {x = curr_pos.x, y = curr_pos.y, locked = false}
			end
			
			table.insert(smoothed, smoothed_pos)
		else
			-- Too short segments - keep original waypoint
			table.insert(smoothed, {x = curr_pos.x, y = curr_pos.y, locked = false})
		end
		
		::continue::
	end
	
	-- Always keep last waypoint
	if #waypoints > 1 then
		table.insert(smoothed, waypoints[#waypoints])
	end
	
	return smoothed
end

-- Calculate detour point around nest, choosing shorter side of path
local function calculate_nest_detour(surface, nest_pos, prev_waypoint, next_waypoint, DETOUR_DISTANCE)
	-- Calculate the path direction vector (from prev to next)
	local path_dx = next_waypoint.x - prev_waypoint.x
	local path_dy = next_waypoint.y - prev_waypoint.y
	local path_len = math.sqrt(path_dx^2 + path_dy^2)
	
	if path_len < 0.1 then
		-- Path too short, can't calculate detour
		return nil
	end
	
	-- Normalize path direction
	path_dx = path_dx / path_len
	path_dy = path_dy / path_len
	
	-- Calculate perpendicular vectors (left and right of path)
	-- Left perpendicular: rotate 90° counter-clockwise
	local left_dx = -path_dy
	local left_dy = path_dx
	
	-- Right perpendicular: rotate 90° clockwise
	local right_dx = path_dy
	local right_dy = -path_dx
	
	-- Calculate detour points at DETOUR_DISTANCE from nest
	local left_detour = {
		x = nest_pos.x + left_dx * DETOUR_DISTANCE,
		y = nest_pos.y + left_dy * DETOUR_DISTANCE,
		locked = true  -- Mark as locked so smoothing doesn't move it
	}
	
	local right_detour = {
		x = nest_pos.x + right_dx * DETOUR_DISTANCE,
		y = nest_pos.y + right_dy * DETOUR_DISTANCE,
		locked = true
	}
	
	-- Calculate total path length for both options (prev → detour → next)
	local left_dist = math.sqrt((left_detour.x - prev_waypoint.x)^2 + (left_detour.y - prev_waypoint.y)^2) +
	                  math.sqrt((next_waypoint.x - left_detour.x)^2 + (next_waypoint.y - left_detour.y)^2)
	
	local right_dist = math.sqrt((right_detour.x - prev_waypoint.x)^2 + (right_detour.y - prev_waypoint.y)^2) +
	                   math.sqrt((next_waypoint.x - right_detour.x)^2 + (next_waypoint.y - right_detour.y)^2)
	
	-- Choose the shorter route
	if left_dist <= right_dist then
		-- logging.info("Pathing", "  Detour: LEFT side chosen (dist=" .. string.format("%.1f", left_dist) .. " vs " .. string.format("%.1f", right_dist) .. ")")
		return left_detour
	else
		-- logging.info("Pathing", "  Detour: RIGHT side chosen (dist=" .. string.format("%.1f", right_dist) .. " vs " .. string.format("%.1f", left_dist) .. ")")
		return right_detour
	end
end

-- Insert detour waypoints around nearby enemy nests
local function insert_nest_detours(surface, waypoints)
	local NEST_AVOIDANCE_DISTANCE = 80  -- Stay at least 40 tiles from nests
	local MAX_ITERATIONS = 3  -- Prevent infinite loops
	
	for iteration = 1, MAX_ITERATIONS do
		local violations_found = false
		local new_waypoints = {}
		local i = 1
		
		while i <= #waypoints do
			local curr_wp = waypoints[i]
			
			-- Find nests near this waypoint
			local nearby_nests = surface.find_entities_filtered{
				position = curr_wp,
				radius = NEST_AVOIDANCE_DISTANCE,
				type = {"unit-spawner", "turret"},  -- Nests and worms
				force = "enemy"
			}
			
			if #nearby_nests > 0 then
				-- Found a nest too close - need to insert detour
				violations_found = true
				local nest = nearby_nests[1]  -- Use closest nest
				
				-- logging.warn("Pathing", "  Iteration " .. iteration .. ": Waypoint " .. i .. " (" .. string.format("%.1f", curr_wp.x) .. "," .. string.format("%.1f", curr_wp.y) .. ") within " .. NEST_AVOIDANCE_DISTANCE .. " tiles of nest at (" .. string.format("%.1f", nest.position.x) .. "," .. string.format("%.1f", nest.position.y) .. ")")
				
				-- Find the previous safe waypoint
				local prev_wp = new_waypoints[#new_waypoints] or {x = curr_wp.x - 10, y = curr_wp.y - 10}
				
				-- Find the next safe waypoint (skip ahead past nest)
				local next_wp = nil
				for j = i + 1, #waypoints do
					local test_wp = waypoints[j]
					local dist_to_nest = math.sqrt((test_wp.x - nest.position.x)^2 + (test_wp.y - nest.position.y)^2)
					if dist_to_nest >= NEST_AVOIDANCE_DISTANCE then
						next_wp = test_wp
						i = j - 1  -- Jump to this waypoint, will be incremented at end of loop
						break
					end
				end
				
				if not next_wp then
					-- No safe waypoint found after nest, use last waypoint
					next_wp = waypoints[#waypoints]
					i = #waypoints
				end
				
				-- Calculate detour point
				local detour_point = calculate_nest_detour(surface, nest.position, prev_wp, next_wp, NEST_AVOIDANCE_DISTANCE)
				
				if detour_point then
					-- logging.info("Pathing", "  Inserting detour point at (" .. string.format("%.1f", detour_point.x) .. "," .. string.format("%.1f", detour_point.y) .. ")")
					table.insert(new_waypoints, detour_point)
				else
					-- logging.warn("Pathing", "  Failed to calculate detour point, keeping original waypoint")
					table.insert(new_waypoints, curr_wp)
				end
			else
				-- Waypoint is safe, keep it
				table.insert(new_waypoints, curr_wp)
			end
			
			i = i + 1
		end
		
		waypoints = new_waypoints
		
		if not violations_found then
			-- logging.info("Pathing", "  Nest detour iteration " .. iteration .. ": No violations found, done")
			break
		else
			-- logging.info("Pathing", "  Nest detour iteration " .. iteration .. ": Violations found, checking again...")
		end
	end
	
	return waypoints
end

-- Handle pathfinding result and queue waypoints
function pathing.handle_path_result(path_result)
	if not path_result then 
		return 
	end
	
	local request_data = storage.path_requests and storage.path_requests[path_result.id]
	if not request_data then 
		return 
	end
	
	-- Get spider from surface
	local surface = game.surfaces[request_data.surface_index]
	if not surface or not surface.valid then
		storage.path_requests[path_result.id] = nil
		return
	end
	
	-- Try to find spider by checking all spiders in storage
	local spider_data = storage.spiders and storage.spiders[request_data.spider_unit_number]
	if not spider_data or not spider_data.entity or not spider_data.entity.valid then
		storage.path_requests[path_result.id] = nil
		return
	end
	
	local spider = spider_data.entity
	
	-- Check if path was found
	-- Note: path_result.path is the array of waypoints directly
	-- Check for try_again_later flag
	if path_result.try_again_later then
		-- Retry the pathfinding request
		local collision_mask = get_path_collision_mask(spider)
		local prototype = spider.prototype
		local bounding_box = {{-0.5, -0.5}, {0.5, 0.5}}
		if prototype and prototype.collision_box then
			bounding_box = prototype.collision_box
		end
		
		local retry_request_id = surface.request_path{
			start = spider.position,
			goal = request_data.destination_pos,
			force = spider.force,
			bounding_box = bounding_box,
			collision_mask = collision_mask,
			radius = 20,
			path_resolution_modifier = -3,
			pathfind_flags = {
				cache = false,
				prefer_straight_paths = false,
				low_priority = true
			}
		}
		
		if retry_request_id then
			storage.path_requests[retry_request_id] = request_data
			storage.path_requests[path_result.id] = nil
			return
		end
	end
	
	if not path_result.path then
		-- Path not found - cancel journey
		local spider_data = storage.spiders[spider.unit_number]
		if spider_data and spider and spider.valid then
			rendering.draw_error_text(spider, "No path found!", {0, -2.0})
			spider_data.status = constants.idle
			spider_data.requester_target = nil
			spider_data.provider_target = nil
			spider_data.payload_item = nil
			spider_data.payload_item_count = 0
		end
		storage.path_requests[path_result.id] = nil
		return
	end
	
	-- path_result.path is the array of waypoints directly
	local waypoints = path_result.path
	if not waypoints or #waypoints == 0 then
		-- No waypoints - cancel journey
		local spider_data = storage.spiders[spider.unit_number]
		if spider_data and spider and spider.valid then
			rendering.draw_error_text(spider, "No waypoints!", {0, -2.0})
			spider_data.status = constants.idle
			spider_data.requester_target = nil
			spider_data.provider_target = nil
			spider_data.payload_item = nil
			spider_data.payload_item_count = 0
		end
		storage.path_requests[path_result.id] = nil
		return
	end
	
	-- Clear existing autopilot destinations before setting new ones
	-- This is important to prevent waypoints from previous destinations interfering
	if spider.autopilot_destinations then
		-- Clear all existing destinations
		for i = #spider.autopilot_destinations, 1, -1 do
			spider.autopilot_destination = nil
		end
	end
	spider.autopilot_destination = nil
	
	-- Filter waypoints for water/cliffs (only if spider can't traverse them)
	local can_water = pathing.can_spider_traverse_water(spider)
	local can_cliffs = can_spider_cross_cliffs(spider)
	local safe_waypoints = {}
	local skipped_water = 0
	local skipped_cliffs = 0
	
	-- logging.info("Pathing", "Processing " .. #waypoints .. " waypoints for spider " .. spider.unit_number .. " (can_water=" .. tostring(can_water) .. ", can_cliffs=" .. tostring(can_cliffs) .. ")")
	
	for i, waypoint in ipairs(waypoints) do
		local waypoint_pos = waypoint.position
		local prev_pos = (i > 1) and waypoints[i-1].position or spider.position
		local next_pos = (i < #waypoints) and waypoints[i+1].position or nil
		
		-- Check what terrain this waypoint is on
		local is_on_water = terrain.is_position_on_water(surface, waypoint_pos, 1.5)
		local is_near_cliff = terrain.is_position_near_corner_cliff(surface, waypoint_pos, 2.5)
		
		-- Check if waypoint is on or near water (ALWAYS filter if spider CAN'T traverse water)
		if not can_water then
			-- Check with multiple radii to be absolutely sure
			local is_on_water_1 = terrain.is_position_on_water(surface, waypoint_pos, 1.5)
			local is_on_water_2 = terrain.is_position_on_water(surface, waypoint_pos, 2.0)
			local is_on_water_3 = terrain.is_position_on_water(surface, waypoint_pos, 3.0)
			
			-- Also check the exact tile
			local exact_tile = surface.get_tile(math.floor(waypoint_pos.x), math.floor(waypoint_pos.y))
			local exact_tile_is_water = false
			if exact_tile and exact_tile.valid then
				local tile_name = exact_tile.name:lower()
				exact_tile_is_water = tile_name:find("water") or tile_name:find("lava") or tile_name:find("lake") or tile_name:find("ammoniacal")
			end
			
			if is_on_water_1 or is_on_water_2 or is_on_water_3 or exact_tile_is_water then
				-- logging.warn("Pathing", "  Waypoint " .. i .. " (" .. string.format("%.1f", waypoint_pos.x) .. "," .. string.format("%.1f", waypoint_pos.y) .. ") on/near water - SKIPPED")
				skipped_water = skipped_water + 1
				goto next_waypoint
			end
		end
		
		-- Check if waypoint is near a corner cliff (only filter if spider CAN'T cross cliffs)
		if not can_cliffs and is_near_cliff then
			-- logging.warn("Pathing", "  Waypoint " .. i .. " (" .. string.format("%.1f", waypoint_pos.x) .. "," .. string.format("%.1f", waypoint_pos.y) .. ") near corner cliff - SKIPPED")
			skipped_cliffs = skipped_cliffs + 1
			goto next_waypoint
		-- Allow waypoints that cross straight cliffs (larger spiders can do this)
		elseif not can_cliffs and terrain.is_waypoint_crossing_straight_cliff(surface, waypoint_pos, prev_pos, next_pos, 2.5) then
			-- This is OK - straight cliffs are easy to traverse
			-- logging.debug("Pathing", "  Waypoint " .. i .. " (" .. string.format("%.1f", waypoint_pos.x) .. "," .. string.format("%.1f", waypoint_pos.y) .. ") crossing straight cliff - OK")
		end
		
		-- Waypoint is safe, add it
		table.insert(safe_waypoints, {x = waypoint_pos.x, y = waypoint_pos.y, locked = false})
		
		::next_waypoint::
	end
	
	-- logging.info("Pathing", "Filtered waypoints: " .. #safe_waypoints .. " safe, " .. skipped_water .. " water, " .. skipped_cliffs .. " cliffs")
	
	-- If we filtered out all waypoints, cancel journey
	if #safe_waypoints == 0 then
		local spider_data = storage.spiders[spider.unit_number]
		if spider_data then
			rendering.draw_error_text(spider, "Path blocked!", {0, -2.0})
			spider_data.status = constants.idle
			spider_data.requester_target = nil
			spider_data.provider_target = nil
			spider_data.payload_item = nil
			spider_data.payload_item_count = 0
		end
		storage.path_requests[path_result.id] = nil
		return
	end
	
	-- Simplify waypoints with adaptive spacing
	local simplified_waypoints = simplify_waypoints(surface, safe_waypoints, spider.position, can_water, can_cliffs)
	
	-- If simplification removed all waypoints, use original safe waypoints
	if #simplified_waypoints == 0 then
		-- logging.warn("Pathing", "Simplification removed all waypoints, using original filtered waypoints")
		simplified_waypoints = safe_waypoints
	else
		-- logging.info("Pathing", "Simplified waypoints: " .. #safe_waypoints .. " -> " .. #simplified_waypoints)
	end
	
	-- Smooth waypoints by cutting corners for smoother paths
	local smoothed_waypoints = smooth_waypoints(simplified_waypoints, spider.position)
	-- logging.info("Pathing", "Smoothed waypoints: " .. #simplified_waypoints .. " -> " .. #smoothed_waypoints)
	
	-- ITERATIVE APPROACH: Check for nest violations and insert detours, then re-smooth
	-- logging.info("Pathing", "Checking for nest violations and inserting detours...")
	local waypoints_with_detours = insert_nest_detours(surface, smoothed_waypoints)
	
	-- If detours were inserted, re-smooth the path (respecting locked detour points)
	if #waypoints_with_detours ~= #smoothed_waypoints then
		-- logging.info("Pathing", "Detours inserted (" .. #smoothed_waypoints .. " -> " .. #waypoints_with_detours .. "), re-smoothing path...")
		waypoints_with_detours = smooth_waypoints(waypoints_with_detours, spider.position)
		-- logging.info("Pathing", "Re-smoothed waypoints: " .. #waypoints_with_detours)
	else
		-- logging.info("Pathing", "No detours needed, using smoothed waypoints")
	end
	
	-- Apply final waypoints to autopilot
	for _, waypoint in ipairs(waypoints_with_detours) do
		spider.add_autopilot_destination({x = waypoint.x, y = waypoint.y})
	end
	
	-- Add final destination if we have a land waypoint (from retry)
	if request_data.land_waypoint then
		spider.add_autopilot_destination(request_data.land_waypoint)
	end
	
	-- Add final destination
	spider.add_autopilot_destination(request_data.destination_pos)
	
	-- logging.info("Pathing", "Final path has " .. #waypoints_with_detours .. " waypoints")
	
	-- Clean up
	storage.path_requests[path_result.id] = nil
end

return pathing