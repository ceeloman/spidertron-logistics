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

-- Get the maximum water gap width that a spider can step over
-- Base game spidertrons can step over gaps up to 15 tiles wide
local function get_spider_water_gap_tolerance(spider)
	if not spider or not spider.valid then return 15.0 end
	
	-- Base game spidertrons can step over water gaps up to 15 tiles
	-- This is based on their leg reach distance
	return 15.0
end

-- Get collision mask for pathfinding based on spider capabilities
-- Use leg collision mask as base (like Spidertron Enhancements) - this determines what legs can traverse
local function get_path_collision_mask(spider, relaxed)
	relaxed = relaxed or false
	local can_water = pathing.can_spider_traverse_water(spider)
	local can_cliffs = can_spider_cross_cliffs(spider)
	
	-- Get the spider's legs to use their collision mask
	local success, legs = pcall(function()
		return spider.get_spider_legs()
	end)
	
	local base_collision_mask = {}
	
	if success and legs and #legs > 0 then
		-- Use first leg's collision mask (all legs have same collision mask)
		local first_leg = legs[1]
		if first_leg and first_leg.valid then
			local leg_prototype = first_leg.prototype
			if leg_prototype and leg_prototype.collision_mask and leg_prototype.collision_mask.layers then
				-- Copy the leg's collision mask layers (it's a dictionary)
				for layer_name, _ in pairs(leg_prototype.collision_mask.layers) do
					base_collision_mask[layer_name] = true
				end
			end
		end
	end
	
	-- Fallback to spider body collision mask if legs aren't available
	if not next(base_collision_mask) then
		local prototype = spider.prototype
		if prototype and prototype.collision_mask and prototype.collision_mask.layers then
			-- Copy the spider's collision mask layers (it's a dictionary)
			for layer_name, _ in pairs(prototype.collision_mask.layers) do
				base_collision_mask[layer_name] = true
			end
		end
	end
	
	-- Don't add water_tile/lava_tile restrictions to collision mask
	-- With leg collision mask + tiny bounding box, Factorio's pathfinder can find paths that step over water gaps
	-- We'll filter waypoints afterward to ensure paths don't cross too much water
	-- This allows the pathfinder to find paths over land bridges and small water gaps
	if not can_water then
		-- logging.debug("Pathing", "Spider " .. spider.unit_number .. " cannot traverse water, will filter waypoints after pathfinding")
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
		return false 
	end
	if not destination_pos then 
		return false 
	end
	
	local surface = spider.surface
	local start_pos = spider.position
	
	-- Check if destination is too close
	local distance = math.sqrt((start_pos.x - destination_pos.x)^2 + (start_pos.y - destination_pos.y)^2)
	if distance < 10 then
		spider.add_autopilot_destination(destination_pos)
		return true
	end
	
	-- Get spider legs
	local success, legs = pcall(function()
		return spider.get_spider_legs()
	end)
	
	if not success or not legs or #legs == 0 then
		spider.add_autopilot_destination(destination_pos)
		return true
	end
	
	local first_leg = legs[1]
	if not first_leg or not first_leg.valid then
		spider.add_autopilot_destination(destination_pos)
		return true
	end
	
	local target_position = surface.find_non_colliding_position(
		first_leg.name,
		destination_pos,
		10,
		2
	)
	target_position = target_position or destination_pos
	
	-- Get leg collision mask
	local leg_prototype = first_leg.prototype
	if not leg_prototype or not leg_prototype.collision_mask then
		spider.add_autopilot_destination(target_position)
		return true
	end
	
	local leg_collision_mask = leg_prototype.collision_mask
	
	-- Check if spider can traverse water (legs have "player" layer = can't traverse)
	local can_traverse_water = not (leg_collision_mask.layers and leg_collision_mask.layers["player"])
	
	-- Build path collision mask
	-- CRITICAL: We keep the player layer IN the collision mask for pathfinding
	-- This prevents pathfinder from routing across large water bodies
	-- We'll handle narrow gaps in post-processing
	local path_collision_mask = {
		layers = {},
		colliding_with_tiles_only = true,
		consider_tile_transitions = true
	}
	
	if leg_collision_mask.layers then
		for layer_name, _ in pairs(leg_collision_mask.layers) do
			path_collision_mask.layers[layer_name] = true
		end
	end
	
	logging.info("Pathing", "Spider " .. spider.unit_number .. " can_traverse_water=" .. tostring(can_traverse_water))
	
	-- Request paths from multiple leg positions
	local request_ids = {}
	for i, leg in pairs(legs) do
		if i % 2 == 1 then
			local request_id = surface.request_path{
				start = leg.position,
				goal = target_position,
				force = spider.force,
				bounding_box = {{-0.01, -0.01}, {0.01, 0.01}},
				collision_mask = path_collision_mask,
				radius = 20,
				path_resolution_modifier = -3,
				pathfind_flags = {
					cache = false,
					prefer_straight_paths = false,
					low_priority = false
				}
			}
			
			if request_id then
				table.insert(request_ids, request_id)
				
				storage.path_requests = storage.path_requests or {}
				storage.path_requests[request_id] = {
					spider_unit_number = spider.unit_number,
					surface_index = surface.index,
					start_position = leg.position,
					destination_pos = target_position,
					destination_entity = destination_entity,
					start_tick = game.tick,
					leg_index = i,
					collision_mask = path_collision_mask,
					can_traverse_water = can_traverse_water
				}
			end
		end
	end
	
	if #request_ids == 0 then
		return false
	end
	
	storage.pathfinder_statuses = storage.pathfinder_statuses or {}
	storage.pathfinder_statuses[spider.unit_number] = storage.pathfinder_statuses[spider.unit_number] or {}
	
	local total_requests = #request_ids
	storage.pathfinder_statuses[spider.unit_number][game.tick] = {
		finished = 0,
		success = false,
		total_requests = total_requests,
		destination_pos = target_position
	}
	
	logging.info("Pathing", "Requested " .. total_requests .. " paths for spider " .. spider.unit_number)
	
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
-- Simplifies waypoints by removing unnecessary ones (doesn't filter water - that's done earlier)
local function simplify_waypoints(surface, waypoints, start_pos, can_water, can_cliffs)
	if not waypoints or #waypoints == 0 then
		return {}
	end
	
	-- Don't filter water waypoints here - that's already done in the main filtering step
	-- The waypoints passed here are already safe (filtered for water/cliffs)
	-- We just simplify by removing waypoints that are too close together
	
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
		
		-- Determine terrain difficulty at this waypoint (declare before goto)
		-- Don't check for water here - waypoints are already filtered for water safety
		-- Only check for cliffs if spider can't cross them
		local is_difficult = false
		
		-- Also check if waypoint is near water - if so, be more conservative about removing it
		-- It might be on a land bridge and critical for the path
		-- (declare before goto to avoid scope issues)
		local is_near_water = terrain.is_position_on_water(surface, waypoint_pos, 2.0)
		
		-- Calculate path curvature at this waypoint (declare before goto)
		local angle = 0  -- Default to straight
		
		-- Adjust minimum distance based on curvature (declare before goto)
		local base_min_distance = 0
		local min_distance = 0
		
		-- Look ahead variables (declare before goto)
		local should_keep = false
		local next_wp = nil
		local next_waypoint = nil
		local distance_to_next = 0
		local skip_angle = 180
		local next_next_wp = nil
		local next_next = nil
		
		-- If waypoint is locked (from adjustment step), always keep it
		-- Locked waypoints are critical for the path (e.g., on land bridges)
		if waypoint.locked then
			table.insert(simplified, {x = waypoint_pos.x, y = waypoint_pos.y, locked = true})
			last_kept_pos = waypoint_pos
			i = i + 1
			goto continue
		end
		if not can_cliffs and terrain.is_position_near_corner_cliff(surface, waypoint_pos, 3) then
			is_difficult = true
		end
		if is_near_water then
			-- Waypoint is near water - use difficult terrain spacing to be more conservative
			is_difficult = true
		end
		
		-- Calculate path curvature at this waypoint
		if i > 1 and i < #waypoints then
			local prev_wp = waypoints[i-1]
			local prev_pos = prev_wp.position or prev_wp
			next_wp = waypoints[i+1]
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
		base_min_distance = is_difficult and MIN_DISTANCE_DIFFICULT or MIN_DISTANCE_EASY
		min_distance = base_min_distance
		
		-- If path is very straight (small angle), increase spacing significantly
		if angle < MAX_ANGLE_STRAIGHT then
			min_distance = base_min_distance * 1.8  -- 80% more spacing for straight paths
		-- If path has a turn (large angle), decrease spacing
		elseif angle > MIN_ANGLE_TURN then
			min_distance = base_min_distance * 0.5  -- 50% less spacing for sharp turns
		end
		
		-- Look ahead: can we skip this waypoint and go directly to the next one?
		should_keep = false
		if distance >= min_distance then
			-- Distance is sufficient, but check if we can skip ahead further
			if i < #waypoints - 1 then
				next_wp = waypoints[i + 1]
				next_waypoint = next_wp.position or next_wp
				distance_to_next = math.sqrt(
					(next_waypoint.x - last_kept_pos.x)^2 + 
					(next_waypoint.y - last_kept_pos.y)^2
				)
				
				-- Calculate angle if we skip this waypoint
				skip_angle = 180  -- Default to worst case
				if i + 1 < #waypoints then
					-- There's a waypoint after next, check if path is straight
					next_next_wp = waypoints[i + 2]
					next_next = next_next_wp.position or next_next_wp
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

-- Find the closest land point near a position (searches outward in a spiral)
local function find_closest_land_point(surface, position, max_search_radius)
	max_search_radius = max_search_radius or 10
	local start_tile_x = math.floor(position.x)
	local start_tile_y = math.floor(position.y)
	
	-- Check the exact position first
	if not terrain.is_position_directly_on_water(surface, position) then
		return {x = position.x, y = position.y}
	end
	
	-- Search in expanding circles
	for radius = 1, max_search_radius do
		for dx = -radius, radius do
			for dy = -radius, radius do
				-- Only check points on the edge of the circle
				local dist = math.sqrt(dx^2 + dy^2)
				if dist >= radius - 0.5 and dist <= radius + 0.5 then
					local check_x = start_tile_x + dx
					local check_y = start_tile_y + dy
					local check_pos = {x = check_x + 0.5, y = check_y + 0.5}
					
					if not terrain.is_position_directly_on_water(surface, check_pos) then
						return check_pos
					end
				end
			end
		end
	end
	
	-- No land found within search radius
	return nil
end

-- Detect water crossings in a path and find land bridge sections
-- Returns array of {start_land_pos, end_land_pos, water_start_idx, water_end_idx}
local function detect_water_crossings(surface, waypoints, start_pos, spider, can_water)
	if can_water then
		return {}  -- Spider can traverse water, no need to detect crossings
	end
	
	local crossings = {}
	local gap_tolerance = get_spider_water_gap_tolerance(spider)
	local in_water_section = false
	local water_start_idx = nil
	local water_start_land_pos = nil
	
	-- Check each segment
	for i = 1, #waypoints + 1 do
		local segment_start = (i == 1) and start_pos or waypoints[i-1].position
		local segment_end = (i <= #waypoints) and waypoints[i].position or nil
		
		if not segment_end then
			break
		end
		
		-- Check if this segment crosses water
		local crosses_water = line_segment_crosses_water(surface, segment_start, segment_end, can_water, spider)
		local start_is_water = terrain.is_position_directly_on_water(surface, segment_start)
		local end_is_water = terrain.is_position_directly_on_water(surface, segment_end)
		
		if crosses_water or start_is_water or end_is_water then
			if not in_water_section then
				-- Entering water section
				in_water_section = true
				water_start_idx = i - 1
				water_start_land_pos = find_closest_land_point(surface, segment_start, 5)
			end
		else
			if in_water_section then
				-- Exiting water section
				local water_end_land_pos = find_closest_land_point(surface, segment_end, 5)
				
				if water_start_land_pos and water_end_land_pos then
					-- Check if gap is within tolerance
					local gap_distance = math.sqrt(
						(water_end_land_pos.x - water_start_land_pos.x)^2 +
						(water_end_land_pos.y - water_start_land_pos.y)^2
					)
					
					if gap_distance <= gap_tolerance then
						-- This is a traversable land bridge
						table.insert(crossings, {
							start_land_pos = water_start_land_pos,
							end_land_pos = water_end_land_pos,
							water_start_idx = water_start_idx,
							water_end_idx = i - 1,
							gap_distance = gap_distance
						})
						logging.info("Pathing", "Detected land bridge crossing: gap=" .. string.format("%.2f", gap_distance) .. " tiles (tolerance=" .. string.format("%.2f", gap_tolerance) .. ")")
					else
						logging.warn("Pathing", "Water gap too wide: " .. string.format("%.2f", gap_distance) .. " tiles (tolerance=" .. string.format("%.2f", gap_tolerance) .. ")")
					end
				end
				
				in_water_section = false
				water_start_idx = nil
				water_start_land_pos = nil
			end
		end
	end
	
	-- Handle case where path ends in water
	if in_water_section then
		local last_pos = (#waypoints > 0) and waypoints[#waypoints].position or start_pos
		local water_end_land_pos = find_closest_land_point(surface, last_pos, 5)
		
		if water_start_land_pos and water_end_land_pos then
			local gap_distance = math.sqrt(
				(water_end_land_pos.x - water_start_land_pos.x)^2 +
				(water_end_land_pos.y - water_start_land_pos.y)^2
			)
			
			if gap_distance <= gap_tolerance then
				table.insert(crossings, {
					start_land_pos = water_start_land_pos,
					end_land_pos = water_end_land_pos,
					water_start_idx = water_start_idx,
					water_end_idx = #waypoints,
					gap_distance = gap_distance
				})
			end
		end
	end
	
	return crossings
end

-- Check if a line segment crosses water (for spiders that can't traverse water)
-- Now accounts for spider size - spidertrons can step over gaps up to 15 tiles
local function line_segment_crosses_water(surface, start_pos, end_pos, can_water, spider)
	if can_water then
		-- Spider can traverse water, so crossing is OK
		return false
	end
	
	local gap_tolerance = get_spider_water_gap_tolerance(spider)
	
	-- Check multiple points along the line segment
	local distance = math.sqrt((end_pos.x - start_pos.x)^2 + (end_pos.y - start_pos.y)^2)
	local steps = math.max(3, math.ceil(distance / 1.0))  -- Check every ~1 tile for better precision
	
	local consecutive_water_count = 0
	local max_consecutive_water = 0
	
	for i = 0, steps do
		local t = i / steps
		local check_x = start_pos.x + (end_pos.x - start_pos.x) * t
		local check_y = start_pos.y + (end_pos.y - start_pos.y) * t
		
		-- Check if this point is on water (use smaller radius for exact detection)
		local is_water = terrain.is_position_on_water(surface, {x = check_x, y = check_y}, 0.5)
		
		-- Also check the exact tile
		if not is_water then
			local check_tile = surface.get_tile(math.floor(check_x), math.floor(check_y))
			if check_tile and check_tile.valid then
				local tile_name = check_tile.name:lower()
				is_water = tile_name:find("water") or tile_name:find("lava") or tile_name:find("lake") or tile_name:find("ammoniacal")
			end
		end
		
		if is_water then
			consecutive_water_count = consecutive_water_count + 1
			max_consecutive_water = math.max(max_consecutive_water, consecutive_water_count)
		else
			consecutive_water_count = 0
		end
	end
	
	-- If the maximum consecutive water gap is within tolerance, spider can step over it
	-- Convert consecutive count to approximate tile distance
	-- Each step represents (distance / steps) tiles, so consecutive water steps = (consecutive / steps) * distance
	local water_gap_width = (max_consecutive_water / steps) * distance
	
	logging.info("Pathing", "  Water gap check: consecutive=" .. max_consecutive_water .. ", steps=" .. steps .. ", distance=" .. string.format("%.2f", distance) .. ", gap_width=" .. string.format("%.2f", water_gap_width) .. ", tolerance=" .. string.format("%.2f", gap_tolerance))
	
	-- If gap is small enough, allow crossing (land bridge scenario)
	-- Also allow if there's no water at all (max_consecutive_water == 0)
	if max_consecutive_water == 0 then
		-- No water detected - path is safe
		return false  -- Don't block
	elseif water_gap_width <= gap_tolerance then
		logging.info("Pathing", "  Allowing path (gap " .. string.format("%.2f", water_gap_width) .. " <= tolerance " .. string.format("%.2f", gap_tolerance) .. ")")
		return false  -- Can step over, don't block
	end
	
	-- If there's any water that's too wide, block the path
	logging.warn("Pathing", "  Blocking path (gap " .. string.format("%.2f", water_gap_width) .. " > tolerance " .. string.format("%.2f", gap_tolerance) .. ")")
	return true  -- Blocks path
end

-- Smooth waypoints by cutting corners (skips locked waypoints)
-- Now checks for water crossings to prevent smoothing over water
local function smooth_waypoints(waypoints, start_pos, surface, can_water, spider)
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
			
			-- Check if smoothing would cross water - if so, keep original waypoint
			-- Don't smooth if it would cross more water than the spider can step over
			if surface and not can_water and spider then
				-- Check if the path from previous to smoothed position crosses water
				if line_segment_crosses_water(surface, prev_pos, smoothed_pos, can_water, spider) then
					-- Smoothed path would cross water, keep original waypoint
					smoothed_pos = {x = curr_pos.x, y = curr_pos.y, locked = false}
				else
					-- Also check path from smoothed position to next
					if line_segment_crosses_water(surface, smoothed_pos, next_pos, can_water, spider) then
						-- Smoothed path would cross water, keep original waypoint
						smoothed_pos = {x = curr_pos.x, y = curr_pos.y, locked = false}
					end
				end
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

-- Adjust waypoints near water to move them away from water edges
-- For waypoints that can't be moved (water on both sides), lock them and adjacent waypoints
-- Only applies fine-tuning to waypoints near water, not the entire path
local function adjust_waypoints_near_water(surface, waypoints, spider, can_water)
	if can_water then
		-- Spider can traverse water, no adjustment needed
		return waypoints
	end
	
	if not waypoints or #waypoints == 0 then
		return waypoints
	end
	
	local adjusted = {}
	local WATER_CHECK_RADIUS = 2.0  -- Check if waypoint is within 2 tiles of water
	local MOVE_SEARCH_RADIUS = 3.0  -- Search up to 3 tiles away for a safe position
	local locked_indices = {}  -- Track which waypoints are locked
	
	-- First pass: identify waypoints near water and try to move them
	-- BUT: don't move waypoints that are on land bridges (critical for path)
	for i, waypoint in ipairs(waypoints) do
		local waypoint_pos = {x = waypoint.x, y = waypoint.y}
		
		-- Check if waypoint itself is directly on water (not just near it)
		local exact_is_water = terrain.is_position_directly_on_water(surface, waypoint_pos)
		
		-- Check if waypoint is near water (but not on it)
		local is_near_water = terrain.is_position_on_water(surface, waypoint_pos, WATER_CHECK_RADIUS)
		
		-- If waypoint is directly on water, it should have been filtered already
		-- But if it's near water (land bridge scenario), check if we should move it
		if is_near_water and not exact_is_water then
			-- Check if this is a land bridge waypoint (water on both sides)
			-- If so, don't move it - it's critical for the path
			local prev_pos = (i > 1) and {x = waypoints[i-1].x, y = waypoints[i-1].y} or nil
			local next_pos = (i < #waypoints) and {x = waypoints[i+1].x, y = waypoints[i+1].y} or nil
			
			-- Check if path segments cross water (land bridge scenario)
			local is_land_bridge = false
			if prev_pos then
				local crosses_water = line_segment_crosses_water(surface, prev_pos, waypoint_pos, can_water, spider)
				if not crosses_water then
					-- Path from previous doesn't cross water, check if next does
					if next_pos then
						crosses_water = line_segment_crosses_water(surface, waypoint_pos, next_pos, can_water, spider)
						if not crosses_water then
							-- Neither segment crosses water, but waypoint is near water
							-- This might be a land bridge - don't move it
							is_land_bridge = true
						end
					end
				end
			end
			
			if is_land_bridge then
				-- This is a land bridge waypoint - keep it as-is, don't move it
				logging.info("Pathing", "Waypoint " .. i .. " is on land bridge - keeping position (critical for path)")
				table.insert(adjusted, {x = waypoint_pos.x, y = waypoint_pos.y, locked = true})
			else
				-- Not a land bridge, try to move it away from water
				logging.info("Pathing", "Waypoint " .. i .. " at (" .. string.format("%.1f", waypoint_pos.x) .. "," .. string.format("%.1f", waypoint_pos.y) .. ") is near water, attempting to move")
				
				-- Try to find a nearby land position
				local best_pos = nil
				local best_distance_from_water = 0
				
				-- Search in a spiral pattern around the waypoint
				for radius = 0.5, MOVE_SEARCH_RADIUS, 0.5 do
					for angle = 0, 2 * math.pi, math.pi / 4 do  -- Check 8 directions
						local test_x = waypoint_pos.x + radius * math.cos(angle)
						local test_y = waypoint_pos.y + radius * math.sin(angle)
						local test_pos = {x = test_x, y = test_y}
						
						-- Check if this position is on land (not water)
						local is_water_here = terrain.is_position_on_water(surface, test_pos, 0.5)
						
						if not is_water_here then
							-- Check distance to nearest water to find safest position
							local min_water_dist = MOVE_SEARCH_RADIUS
							for check_radius = 0.5, MOVE_SEARCH_RADIUS, 0.5 do
								if terrain.is_position_on_water(surface, test_pos, check_radius) then
									min_water_dist = check_radius
									break
								end
							end
							
							-- If this position is further from water, prefer it
							if min_water_dist > best_distance_from_water then
								best_pos = test_pos
								best_distance_from_water = min_water_dist
							end
						end
					end
					
					-- If we found a good position, use it
					if best_pos and best_distance_from_water >= 1.0 then
						break
					end
				end
				
				if best_pos and best_distance_from_water >= 1.0 then
					-- Found a safe position to move to
					logging.info("Pathing", "  Moving waypoint " .. i .. " to (" .. string.format("%.1f", best_pos.x) .. "," .. string.format("%.1f", best_pos.y) .. ") (distance from water: " .. string.format("%.2f", best_distance_from_water) .. ")")
					table.insert(adjusted, {x = best_pos.x, y = best_pos.y, locked = false})
				else
					-- Can't find a safe position - this waypoint is constrained by water
					-- Keep it as-is and lock it (might be on a land bridge)
					logging.warn("Pathing", "  Waypoint " .. i .. " cannot be moved (water on all sides), locking it")
					locked_indices[i] = true
					-- Keep original position
					table.insert(adjusted, {x = waypoint_pos.x, y = waypoint_pos.y, locked = true})
				end
			end
		else
			-- Waypoint is not near water, keep as-is
			table.insert(adjusted, {x = waypoint_pos.x, y = waypoint_pos.y, locked = false})
		end
	end
	
	-- Second pass: apply locked status to waypoints that were marked
	for i, waypoint in ipairs(adjusted) do
		if locked_indices[i] then
			waypoint.locked = true
		end
	end
	
	local moved_count = 0
	local locked_count = 0
	for i, waypoint in ipairs(adjusted) do
		if waypoint.locked then
			locked_count = locked_count + 1
		end
		if waypoint.x ~= waypoints[i].x or waypoint.y ~= waypoints[i].y then
			moved_count = moved_count + 1
		end
	end
	
	if moved_count > 0 or locked_count > 0 then
		logging.info("Pathing", "Adjusted waypoints near water: " .. moved_count .. " moved, " .. locked_count .. " locked")
	end
	
	return adjusted
end

-- Helper function: Check if path segment crosses water gap that's too wide
local function check_water_gap(surface, pos1, pos2, max_gap)
	local dx = pos2.x - pos1.x
	local dy = pos2.y - pos1.y
	local distance = math.sqrt(dx^2 + dy^2)
	
	-- Check multiple points along segment
	local steps = math.max(3, math.ceil(distance))
	local consecutive_water = 0
	local max_consecutive_water = 0
	
	for i = 0, steps do
		local t = i / steps
		local check_pos = {
			x = pos1.x + dx * t,
			y = pos1.y + dy * t
		}
		
		local tile = surface.get_tile(math.floor(check_pos.x), math.floor(check_pos.y))
		local is_water = false
		if tile and tile.valid then
			local tile_name = tile.name:lower()
			is_water = tile_name:find("water") or tile_name:find("lava") or 
			           tile_name:find("lake") or tile_name:find("ammoniacal")
		end
		
		if is_water then
			consecutive_water = consecutive_water + 1
			max_consecutive_water = math.max(max_consecutive_water, consecutive_water)
		else
			consecutive_water = 0
		end
	end
	
	-- Calculate actual gap width in tiles
	local gap_width = (max_consecutive_water / steps) * distance
	return gap_width > max_gap, gap_width
end

-- Helper function: Filter waypoints that cross water gaps too wide
local function filter_water_waypoints(surface, waypoints, spider_pos, can_traverse_water, spider)
	if can_traverse_water then
		return waypoints -- Spider can traverse water, no filtering needed
	end
	
	-- Base game spidertron can step over gaps up to ~15 tiles
	local max_gap = 15.0
	
	local filtered = {}
	local last_pos = spider_pos
	
	for i, wp in ipairs(waypoints) do
		local pos = wp.position or wp
		
		-- Check if segment to this waypoint crosses a water gap that's too wide
		local gap_too_wide, gap_width = check_water_gap(surface, last_pos, pos, max_gap)
		
		if gap_too_wide then
			logging.warn("Pathing", "Waypoint " .. i .. " crosses water gap of " .. 
			            string.format("%.1f", gap_width) .. " tiles (max: " .. max_gap .. ") - FILTERED")
			-- Don't add this waypoint or any after it
			break
		end
		
		table.insert(filtered, wp)
		last_pos = pos
	end
	
	return filtered
end

function pathing.handle_path_result(path_result)
	if not path_result then return end
	
	local request_data = storage.path_requests and storage.path_requests[path_result.id]
	if not request_data then return end
	
	local surface = game.surfaces[request_data.surface_index]
	if not surface or not surface.valid then
		storage.path_requests[path_result.id] = nil
		return
	end
	
	local spider_data = storage.spiders and storage.spiders[request_data.spider_unit_number]
	if not spider_data or not spider_data.entity or not spider_data.entity.valid then
		storage.path_requests[path_result.id] = nil
		return
	end
	
	local spider = spider_data.entity
	local start_tick = request_data.start_tick
	
	local status_table = storage.pathfinder_statuses[spider.unit_number] and 
	                     storage.pathfinder_statuses[spider.unit_number][start_tick]
	
	if not status_table then
		storage.path_requests[path_result.id] = nil
		return
	end
	
	local destination_pos = request_data.destination_pos
	
	if status_table.success then
		status_table.finished = status_table.finished + 1
		storage.path_requests[path_result.id] = nil
		
		if status_table.finished == status_table.total_requests then
			storage.pathfinder_statuses[spider.unit_number][start_tick] = nil
		end
		return
	end
	
	local autopilot_dest = spider.autopilot_destination
	if autopilot_dest and (autopilot_dest.x ~= destination_pos.x or autopilot_dest.y ~= destination_pos.y) then
		status_table.finished = status_table.finished + 1
		status_table.success = true
		storage.path_requests[path_result.id] = nil
		
		if status_table.finished == status_table.total_requests then
			storage.pathfinder_statuses[spider.unit_number][start_tick] = nil
		end
		return
	end
	
	if path_result.try_again_later then
		local retry_id = surface.request_path{
			start = request_data.start_position,
			goal = destination_pos,
			force = spider.force,
			bounding_box = {{-0.01, -0.01}, {0.01, 0.01}},
			collision_mask = request_data.collision_mask,
			radius = 20,
			path_resolution_modifier = -3,
			pathfind_flags = {
				cache = false,
				prefer_straight_paths = false,
				low_priority = true
			}
		}
		
		if retry_id then
			storage.path_requests[retry_id] = request_data
		end
		storage.path_requests[path_result.id] = nil
		return
	end
	
	if not path_result.path or #path_result.path == 0 then
		local current_resolution = request_data.path_resolution_modifier or -3
		
		if current_resolution < 1 then
			local retry_id = surface.request_path{
				start = request_data.start_position,
				goal = destination_pos,
				force = spider.force,
				bounding_box = {{-0.01, -0.01}, {0.01, 0.01}},
				collision_mask = request_data.collision_mask,
				radius = 20,
				path_resolution_modifier = current_resolution + 2,
				pathfind_flags = {
					cache = false,
					prefer_straight_paths = false,
					low_priority = false
				}
			}
			
			if retry_id then
				request_data.path_resolution_modifier = current_resolution + 2
				storage.path_requests[retry_id] = request_data
			end
		else
			status_table.finished = status_table.finished + 1
		end
		
		storage.path_requests[path_result.id] = nil
		
		if status_table.finished == status_table.total_requests then
			logging.warn("Pathing", "All paths failed for spider " .. spider.unit_number)
			rendering.draw_error_text(spider, "No path found!", {0, -2.0})
			spider_data.status = constants.idle
			spider_data.requester_target = nil
			spider_data.provider_target = nil
			storage.pathfinder_statuses[spider.unit_number][start_tick] = nil
		end
		return
	end
	
	-- PATH FOUND - Filter for water gaps
	local waypoints = path_result.path
	local can_traverse_water = request_data.can_traverse_water
	
	-- Filter out waypoints that cross water gaps that are too wide
	local filtered_waypoints = filter_water_waypoints(surface, waypoints, spider.position, can_traverse_water, spider)
	
	if #filtered_waypoints == 0 then
		logging.warn("Pathing", "All waypoints filtered (water gaps too wide)")
		status_table.finished = status_table.finished + 1
		storage.path_requests[path_result.id] = nil
		
		if status_table.finished == status_table.total_requests then
			rendering.draw_error_text(spider, "Water gap too wide!", {0, -2.0})
			spider_data.status = constants.idle
			spider_data.requester_target = nil
			spider_data.provider_target = nil
			storage.pathfinder_statuses[spider.unit_number][start_tick] = nil
		end
		return
	end
	
	logging.info("Pathing", "Path found for spider " .. spider.unit_number .. 
	            " (" .. #filtered_waypoints .. "/" .. #waypoints .. " waypoints after filtering)")
	
	spider.autopilot_destination = nil
	
	-- Find nearest waypoint to spider
	local spider_pos = spider.position
	local min_distance = math.huge
	local start_index = 1
	
	for i, wp in ipairs(filtered_waypoints) do
		local pos = wp.position or wp
		local dist = math.sqrt((pos.x - spider_pos.x)^2 + (pos.y - spider_pos.y)^2)
		if dist < min_distance then
			min_distance = dist
			start_index = i
		end
	end
	
	-- Apply waypoints with minimum spacing
	local last_pos = spider_pos
	local min_spacing = (spider.prototype.height + 0.5) * 7.5
	
	for i = start_index + 1, #filtered_waypoints do
		local wp = filtered_waypoints[i].position or filtered_waypoints[i]
		local dist = math.sqrt((wp.x - last_pos.x)^2 + (wp.y - last_pos.y)^2)
		
		if dist > min_spacing then
			spider.add_autopilot_destination(wp)
			last_pos = wp
		end
	end
	
	spider.add_autopilot_destination(destination_pos)
	
	status_table.finished = status_table.finished + 1
	status_table.success = true
	
	storage.path_requests[path_result.id] = nil
	
	if status_table.finished == status_table.total_requests then
		storage.pathfinder_statuses[spider.unit_number][start_tick] = nil
	end
end

return pathing