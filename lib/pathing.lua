-- Pathfinding with terrain awareness (water, cliffs, enemies)
-- Uses Factorio's pathfinding API to generate waypoints and queue them

local terrain = require('lib.terrain')
local constants = require('lib.constants')
local logging = require('lib.logging')
local rendering = require('lib.rendering')

-- Initialize pathfinding cache if needed
if not storage.pathfinding_cache then
	storage.pathfinding_cache = {}
end

-- Generate cache key from start and end positions (rounded to nearest 5 tiles for cache efficiency)
local function get_pathfinding_cache_key(start_pos, end_pos)
	local start_x = math.floor(start_pos.x / 5) * 5
	local start_y = math.floor(start_pos.y / 5) * 5
	local end_x = math.floor(end_pos.x / 5) * 5
	local end_y = math.floor(end_pos.y / 5) * 5
	return string.format("%.0f,%.0f->%.0f,%.0f", start_x, start_y, end_x, end_y)
end

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
		return true
	end
	
	-- Get the first leg's collision mask (all legs should have the same collision mask)
	local first_leg = legs[1]
	if not first_leg or not first_leg.valid then
		return false
	end
	
	local leg_prototype = first_leg.prototype
	if not leg_prototype then
		return false
	end
	
	-- Get the leg's collision mask
	local leg_collision_mask = leg_prototype.collision_mask
	if not leg_collision_mask or not leg_collision_mask.layers then
		return false
	end
	
	-- Check if legs collide with "player", "water_tile", or "lava_tile" layers
	-- Water/lava tiles have "player" in their collision mask (base game) or "water_tile"/"lava_tile" (modded)
	-- If legs have any of these in collision mask, they will collide with water/lava = cannot traverse
	if leg_collision_mask.layers["player"] or leg_collision_mask.layers["water_tile"] or leg_collision_mask.layers["lava_tile"] then
		return false
	else
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

-- Get leg size/reach from leg prototype
-- Uses collision box to estimate leg reach distance
local function get_leg_size(spider)
	if not spider or not spider.valid then return 0 end
	
	local success, legs = pcall(function()
		return spider.get_spider_legs()
	end)
	
	if not success or not legs or #legs == 0 then
		return 0  -- No legs
	end
	
	local first_leg = legs[1]
	if not first_leg or not first_leg.valid then
		return 0
	end
	
	local leg_prototype = first_leg.prototype
	if not leg_prototype then
		return 0
	end
	
	-- Try to get leg reach distance if available (Factorio 2.0+)
	if leg_prototype.reach_distance then
		return leg_prototype.reach_distance
	end
	
	-- Fallback: estimate from collision box
	if leg_prototype.collision_box then
		local box = leg_prototype.collision_box
		local width = box.right_bottom.x - box.left_top.x
		local height = box.right_bottom.y - box.left_top.y
		-- Leg reach is typically much larger than collision box
		-- Estimate: collision box size * 10 (rough approximation)
		return math.max(width, height) * 10
	end
	
	-- Default fallback
	return 15.0
end

-- Get the maximum water gap width that a spider can step over
-- Now based on leg size/reach
local function get_spider_water_gap_tolerance(spider)
	if not spider or not spider.valid then return 15.0 end
	
	local leg_size = get_leg_size(spider)
	if leg_size > 0 then
		return leg_size
	end
	
	-- Fallback to default
	return 15.0
end

-- Get minimum distance to keep from buildings based on leg size
-- Minimum 0.5 tiles, plus leg size for safety
local function get_building_avoidance_distance(spider)
	if not spider or not spider.valid then return 0.5 end
	
	local leg_size = get_leg_size(spider)
	-- Minimum 0.5 tiles, plus half leg size for clearance
	return 0.5 + (leg_size / 2)
end

-- Calculate distance from a point to the edge of a collision box
-- Returns the distance from point to nearest edge of the collision box
local function distance_to_collision_box_edge(point, building)
	if not building or not building.valid then
		return math.huge
	end
	
	local prototype = building.prototype
	if not prototype or not prototype.collision_box then
		return math.huge
	end
	
	local box = prototype.collision_box
	local building_pos = building.position
	
	-- Transform collision box to world coordinates
	-- Collision box is relative to entity position
	local box_left = building_pos.x + box.left_top.x
	local box_right = building_pos.x + box.right_bottom.x
	local box_top = building_pos.y + box.left_top.y
	local box_bottom = building_pos.y + box.right_bottom.y
	
	-- Calculate distance to nearest edge
	-- If point is inside box, distance is to nearest edge
	-- If point is outside box, distance is to nearest corner or edge
	local dx = 0
	local dy = 0
	
	if point.x < box_left then
		dx = box_left - point.x
	elseif point.x > box_right then
		dx = point.x - box_right
	end
	
	if point.y < box_top then
		dy = box_top - point.y
	elseif point.y > box_bottom then
		dy = point.y - box_bottom
	end
	
	-- Distance to nearest edge (or corner if outside)
	return math.sqrt(dx^2 + dy^2)
end

-- Check if spider can cross an object based on leg size
local function can_spider_cross_object(spider, object_size)
	if not spider or not spider.valid then return false end
	
	local leg_size = get_leg_size(spider)
	-- Can cross if leg reach is at least 1.5x the object size
	return leg_size >= (object_size * 1.5)
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
	else
	end
	
	-- If spider can't cross cliffs, ensure cliff is in collision mask
	if not can_cliffs then
		base_collision_mask["cliff"] = true
	end
	
	-- Keep as dictionary format for request_path (API requires dictionary, not array)
	-- layers must be a dictionary where keys are layer names and values are always true
	local layer_names = {}
	for layer_name, _ in pairs(base_collision_mask) do
		table.insert(layer_names, layer_name)
	end
	
	return {
		layers = base_collision_mask,  -- Keep as dictionary, not array
		colliding_with_tiles_only = true,
		consider_tile_transitions = true
	}
end

-- Initialize pathfinding cache if needed
if not storage.pathfinding_cache then
	storage.pathfinding_cache = {}
end

-- Generate cache key from start and end positions (rounded to nearest 5 tiles for cache efficiency)
local function get_pathfinding_cache_key(start_pos, end_pos)
	local start_x = math.floor(start_pos.x / 5) * 5
	local start_y = math.floor(start_pos.y / 5) * 5
	local end_x = math.floor(end_pos.x / 5) * 5
	local end_y = math.floor(end_pos.y / 5) * 5
	return string.format("%.0f,%.0f->%.0f,%.0f", start_x, start_y, end_x, end_y)
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
	
	-- Check if destination is too close - skip pathfinding, use direct autopilot
	local distance = math.sqrt((start_pos.x - destination_pos.x)^2 + (start_pos.y - destination_pos.y)^2)
	if distance < 10 then
		spider.add_autopilot_destination(destination_pos)
		return true
	end
	
	-- Check pathfinding cache (initialize if needed)
	if not storage.pathfinding_cache then
		storage.pathfinding_cache = {}
	end
	local cache_key = get_pathfinding_cache_key(start_pos, destination_pos)
	local cached_path = storage.pathfinding_cache[cache_key]
	local current_tick = game.tick
	
	if cached_path and cached_path.waypoints and cached_path.cache_tick then
		local cache_age = current_tick - cached_path.cache_tick
		if cache_age < constants.pathfinding_cache_ttl then
			-- Use cached path
			spider.autopilot_destination = nil
			for _, wp in ipairs(cached_path.waypoints) do
				spider.add_autopilot_destination(wp)
			end
			spider.add_autopilot_destination(destination_pos)
			return true
		else
			-- Cache expired, remove it
			storage.pathfinding_cache[cache_key] = nil
		end
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
	
	-- Check if spider can traverse water/lava (legs have "player", "water_tile", or "lava_tile" layer = can't traverse)
	local can_traverse_water = not (leg_collision_mask.layers and (leg_collision_mask.layers["player"] or leg_collision_mask.layers["water_tile"] or leg_collision_mask.layers["lava_tile"]))
	
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
	
	-- Build detailed log message about spider water traversal capability
	local leg_name = first_leg.name or "unknown"
	local leg_collision_layers = {}
	if leg_collision_mask.layers then
		for layer_name, _ in pairs(leg_collision_mask.layers) do
			table.insert(leg_collision_layers, layer_name)
		end
	end
	local leg_collision_layers_str = table.concat(leg_collision_layers, ", ")
	if leg_collision_layers_str == "" then
		leg_collision_layers_str = "none"
	end
	
	--              " | Leg: " .. leg_name .. 
	--              " | Leg collision mask layers: [" .. leg_collision_layers_str .. "]")
	
	-- Request paths from multiple leg positions (limit to 2 requests max for UPS efficiency)
	-- Use first and middle leg instead of all odd legs to reduce pathfinding load
	local request_ids = {}
	local leg_count = #legs
	local legs_to_use = {}
	
	-- Always use first leg
	if leg_count > 0 then
		table.insert(legs_to_use, legs[1])
	end
	
	-- Use middle leg if available (better coverage than just first)
	if leg_count > 2 then
		local middle_index = math.floor(leg_count / 2)
		if middle_index % 2 == 0 then
			middle_index = middle_index + 1  -- Prefer odd index
		end
		if middle_index <= leg_count and middle_index ~= 1 then
			table.insert(legs_to_use, legs[middle_index])
		end
	end
	
	-- Limit to 2 requests max to reduce pathfinding overhead
	for i = 1, math.min(2, #legs_to_use) do
		local leg = legs_to_use[i]
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
					else
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
	
	
	-- If gap is small enough, allow crossing (land bridge scenario)
	-- Also allow if there's no water at all (max_consecutive_water == 0)
	if max_consecutive_water == 0 then
		-- No water detected - path is safe
		return false  -- Don't block
	elseif water_gap_width <= gap_tolerance then
		return false  -- Can step over, don't block
	end
	
	-- If there's any water that's too wide, block the path
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

-- Calculate detour point around nest, choosing safer side of path (checks water safety)
local function calculate_nest_detour(surface, nest_pos, prev_waypoint, next_waypoint, DETOUR_DISTANCE, spider, can_water)
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
	
	-- Helper function to check if a detour point and path segments are safe
	local function is_detour_safe(detour_pos)
		-- Check if detour point itself is on water (if spider can't traverse water)
		if not can_water and terrain.is_position_directly_on_water(surface, detour_pos) then
			return false, "detour_on_water"
		end
		
		-- Check if path segments cross water (if spider can't traverse water)
		if not can_water and spider then
			-- Check prev → detour segment
			if line_segment_crosses_water(surface, prev_waypoint, detour_pos, can_water, spider) then
				return false, "prev_to_detour_crosses_water"
			end
			-- Check detour → next segment
			if line_segment_crosses_water(surface, detour_pos, next_waypoint, can_water, spider) then
				return false, "detour_to_next_crosses_water"
			end
		end
		
		return true, "safe"
	end
	
	-- Check safety of both detour options
	local left_safe, left_reason = is_detour_safe(left_detour)
	local right_safe, right_reason = is_detour_safe(right_detour)
	
	-- Calculate total path length for both options (prev → detour → next)
	local left_dist = math.sqrt((left_detour.x - prev_waypoint.x)^2 + (left_detour.y - prev_waypoint.y)^2) +
	                  math.sqrt((next_waypoint.x - left_detour.x)^2 + (next_waypoint.y - left_detour.y)^2)
	
	local right_dist = math.sqrt((right_detour.x - prev_waypoint.x)^2 + (right_detour.y - prev_waypoint.y)^2) +
	                   math.sqrt((next_waypoint.x - right_detour.x)^2 + (next_waypoint.y - right_detour.y)^2)
	
	-- Choose the safer route, preferring safety over distance
	if left_safe and right_safe then
		-- Both are safe, choose shorter one
		if left_dist <= right_dist then
			return left_detour
		else
			return right_detour
		end
	elseif left_safe then
		-- Only left is safe
		return left_detour
	elseif right_safe then
		-- Only right is safe
		return right_detour
	else
		-- Both are unsafe - try to find a safe alternative by searching nearby
		
		-- Try searching in a spiral pattern around the nest for a safe detour point
		local search_radius = DETOUR_DISTANCE
		local max_search_radius = DETOUR_DISTANCE * 1.5  -- Allow up to 50% further
		local search_step = 5.0  -- Search every 5 tiles
		
		for radius = search_radius, max_search_radius, search_step do
			-- Try multiple angles around the nest
			for angle_offset = 0, 2 * math.pi, math.pi / 4 do  -- 8 directions
				-- Try both left and right sides with angle offset
				for side = -1, 1, 2 do  -- -1 = left, 1 = right
					local angle = math.atan2(left_dy, left_dx) + (side * angle_offset)
					local test_detour = {
						x = nest_pos.x + math.cos(angle) * radius,
						y = nest_pos.y + math.sin(angle) * radius,
						locked = true
					}
					
					local test_safe, _ = is_detour_safe(test_detour)
					if test_safe then
						return test_detour
					end
				end
			end
		end
		
		-- If no safe alternative found, try to find closest land point to the shorter unsafe detour
		-- This is a fallback - better than nothing
		local preferred_detour = (left_dist <= right_dist) and left_detour or right_detour
		local safe_land_point = find_closest_land_point(surface, preferred_detour, 10)
		
		if safe_land_point then
			-- Check if the path to/from the safe land point is also safe
			local land_detour = {x = safe_land_point.x, y = safe_land_point.y, locked = true}
			local land_safe, _ = is_detour_safe(land_detour)
			if land_safe then
				return land_detour
			end
		end
		
		-- Last resort: return the shorter unsafe detour (better than no detour)
		-- The pathfinder will handle it, or it will be caught later
		return (left_dist <= right_dist) and left_detour or right_detour
	end
end

-- Insert detour waypoints around nearby enemy nests
local function insert_nest_detours(surface, waypoints, spider, can_water)
	local NEST_AVOIDANCE_DISTANCE = 80  -- Stay at least 80 tiles from nests
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
				
				-- Calculate detour point (now with safety checks)
				local detour_point = calculate_nest_detour(surface, nest.position, prev_wp, next_wp, NEST_AVOIDANCE_DISTANCE, spider, can_water)
				
				if detour_point then
					-- Final validation: check if the detour point is safe before inserting
					-- This double-checks in case the detour calculation missed something
					local is_safe = true
					if not can_water and spider then
						-- Check if detour point is on water
						if terrain.is_position_directly_on_water(surface, detour_point) then
							is_safe = false
						else
							-- Check if path segments are safe
							if line_segment_crosses_water(surface, prev_wp, detour_point, can_water, spider) then
								is_safe = false
							elseif line_segment_crosses_water(surface, detour_point, next_wp, can_water, spider) then
								is_safe = false
							end
						end
					end
					
					if is_safe then
						table.insert(new_waypoints, detour_point)
					else
						-- Detour is unsafe, skip it and keep original waypoint
						-- This might cause the spider to get closer to the nest, but it's better than pathing into water
						table.insert(new_waypoints, curr_wp)
					end
				else
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
			break
		else
		end
	end
	
	return waypoints
end

-- Calculate detour point around building
local function calculate_building_detour(surface, building, prev_waypoint, next_waypoint, DETOUR_DISTANCE, spider)
	-- Get building size
	local prototype = building.prototype
	if not prototype or not prototype.collision_box then
		return nil
	end
	
	local box = prototype.collision_box
	local building_width = box.right_bottom.x - box.left_top.x
	local building_height = box.right_bottom.y - box.left_top.y
	local building_size = math.max(building_width, building_height)
	
	local building_pos = building.position
	
	-- Calculate the path direction vector (from prev to next)
	local path_dx = next_waypoint.x - prev_waypoint.x
	local path_dy = next_waypoint.y - prev_waypoint.y
	local path_len = math.sqrt(path_dx^2 + path_dy^2)
	
	if path_len < 0.1 then
		return nil
	end
	
	-- Normalize path direction
	path_dx = path_dx / path_len
	path_dy = path_dy / path_len
	
	-- Calculate perpendicular vectors (left and right of path)
	local left_dx = -path_dy
	local left_dy = path_dx
	local right_dx = path_dy
	local right_dy = -path_dx
	
	-- Calculate detour distance from building center
	-- We want the detour to be DETOUR_DISTANCE away from the collision box edge
	-- So from center, it's building_size/2 (to edge) + DETOUR_DISTANCE
	local detour_radius = building_size/2 + DETOUR_DISTANCE
	
	-- Calculate detour points on left and right sides
	local left_detour = {
		x = building_pos.x + left_dx * detour_radius,
		y = building_pos.y + left_dy * detour_radius,
		locked = true
	}
	
	local right_detour = {
		x = building_pos.x + right_dx * detour_radius,
		y = building_pos.y + right_dy * detour_radius,
		locked = true
	}
	
	-- Check if detour points are safe (not colliding with other buildings)
	local function is_detour_safe(detour_pos)
		-- Check if detour point collides with any large building
		local nearby = surface.find_entities_filtered{
			position = detour_pos,
			radius = 3.0,
			force = spider.force,
			to_be_deconstructed = false
		}
		
		for _, entity in ipairs(nearby) do
			if entity ~= building and entity.type ~= "spider-vehicle" then
				local proto = entity.prototype
				if proto and proto.collision_box then
					local box = proto.collision_box
					local size = math.max(box.right_bottom.x - box.left_top.x, box.right_bottom.y - box.left_top.y)
					if size >= 2.0 then  -- Avoid any building 2+ tiles
						local dist = math.sqrt((entity.position.x - detour_pos.x)^2 + (entity.position.y - detour_pos.y)^2)
						local min_dist = get_building_avoidance_distance(spider) + size/2
						if dist < min_dist then
							return false
						end
					end
				end
			end
		end
		
		return true
	end
	
	-- Choose the safer/shorter route
	local left_safe = is_detour_safe(left_detour)
	local right_safe = is_detour_safe(right_detour)
	
	local left_dist = math.sqrt((left_detour.x - prev_waypoint.x)^2 + (left_detour.y - prev_waypoint.y)^2) +
	                  math.sqrt((next_waypoint.x - left_detour.x)^2 + (next_waypoint.y - left_detour.y)^2)
	
	local right_dist = math.sqrt((right_detour.x - prev_waypoint.x)^2 + (right_detour.y - prev_waypoint.y)^2) +
	                   math.sqrt((next_waypoint.x - right_detour.x)^2 + (next_waypoint.y - right_detour.y)^2)
	
	if left_safe and right_safe then
		return (left_dist <= right_dist) and left_detour or right_detour
	elseif left_safe then
		return left_detour
	elseif right_safe then
		return right_detour
	else
		-- Both unsafe, return shorter one anyway (better than nothing)
		return (left_dist <= right_dist) and left_detour or right_detour
	end
end

-- Insert detour waypoints around large buildings
local function insert_building_detours(surface, waypoints, spider)
	local MIN_BUILDING_SIZE = 2.0  -- Minimum collision box size to consider (2x2 tiles)
	local MAX_ITERATIONS = 2  -- Prevent infinite loops
	
	-- Get building avoidance distance based on leg size
	local BUILDING_AVOIDANCE_DISTANCE = get_building_avoidance_distance(spider)
	
	for iteration = 1, MAX_ITERATIONS do
		local violations_found = false
		local new_waypoints = {}
		local i = 1
		
		while i <= #waypoints do
			local curr_wp = waypoints[i]
			
			-- Find large buildings near this waypoint
			local nearby_buildings = surface.find_entities_filtered{
				position = curr_wp,
				radius = BUILDING_AVOIDANCE_DISTANCE + 10,  -- Search wider area
				force = spider.force,  -- Only avoid friendly buildings
				to_be_deconstructed = false
			}
			
			-- Filter for large buildings only
			local large_buildings = {}
			for _, building in ipairs(nearby_buildings) do
				-- Skip the spider itself and its target entities
				if building.type == "spider-vehicle" then
					goto next_building
				end
				
				local prototype = building.prototype
				if prototype and prototype.collision_box then
					local box = prototype.collision_box
					local width = box.right_bottom.x - box.left_top.x
					local height = box.right_bottom.y - box.left_top.y
					local size = math.max(width, height)
					
					if size >= MIN_BUILDING_SIZE then
						-- Calculate distance from waypoint to building's collision box edge
						local dist_to_edge = distance_to_collision_box_edge(curr_wp, building)
						-- Need to stay at least BUILDING_AVOIDANCE_DISTANCE away from building edge
						if dist_to_edge < BUILDING_AVOIDANCE_DISTANCE then
							table.insert(large_buildings, building)
						end
					end
				end
				::next_building::
			end
			
			if #large_buildings > 0 then
				-- Found a large building too close - need to insert detour
				violations_found = true
				local building = large_buildings[1]  -- Use closest building
				
				-- Find the previous safe waypoint
				local prev_wp = new_waypoints[#new_waypoints] or {x = curr_wp.x - 10, y = curr_wp.y - 10}
				
				-- Find the next safe waypoint (skip ahead past building)
				local next_wp = nil
				for j = i + 1, #waypoints do
					local test_wp = waypoints[j]
					-- Calculate distance from waypoint to building's collision box edge
					local dist_to_edge = distance_to_collision_box_edge(test_wp, building)
					if dist_to_edge >= BUILDING_AVOIDANCE_DISTANCE then
						next_wp = test_wp
						i = j - 1  -- Jump to this waypoint
						break
					end
				end
				
				if not next_wp then
					-- No safe waypoint found after building, use last waypoint
					next_wp = waypoints[#waypoints]
					i = #waypoints
				end
				
				-- Calculate detour point around building
				local detour_point = calculate_building_detour(surface, building, prev_wp, next_wp, BUILDING_AVOIDANCE_DISTANCE, spider)
				
				if detour_point then
					table.insert(new_waypoints, detour_point)
				else
					-- Failed to calculate detour, keep original waypoint
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
			break
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
				table.insert(adjusted, {x = waypoint_pos.x, y = waypoint_pos.y, locked = true})
			else
				-- Not a land bridge, try to move it away from water
				
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
					table.insert(adjusted, {x = best_pos.x, y = best_pos.y, locked = false})
				else
					-- Can't find a safe position - this waypoint is constrained by water
					-- Keep it as-is and lock it (might be on a land bridge)
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
	
	-- if moved_count > 0 or locked_count > 0 then
	-- end
	
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
			--             string.format("%.1f", gap_width) .. " tiles (max: " .. max_gap .. ") - FILTERED")
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
	
	-- Convert waypoints to proper format if needed
	local processed_waypoints = {}
	for i, wp in ipairs(filtered_waypoints) do
		local pos = wp.position or wp
		table.insert(processed_waypoints, {x = pos.x, y = pos.y, locked = false})
	end
	
	-- Get spider capabilities
	local can_cliffs = can_spider_cross_cliffs(spider)
	
	-- Process waypoints: adjust near water, insert nest detours, insert building detours, simplify, then smooth
	processed_waypoints = adjust_waypoints_near_water(surface, processed_waypoints, spider, can_traverse_water)
	processed_waypoints = insert_nest_detours(surface, processed_waypoints, spider, can_traverse_water)
	processed_waypoints = insert_building_detours(surface, processed_waypoints, spider)
	processed_waypoints = simplify_waypoints(surface, processed_waypoints, spider.position, can_traverse_water, can_cliffs)
	processed_waypoints = smooth_waypoints(processed_waypoints, spider.position, surface, can_traverse_water, spider)
	
	--             " (" .. #processed_waypoints .. "/" .. #waypoints .. " waypoints after processing)")
	
	spider.autopilot_destination = nil
	
	-- Find nearest waypoint to spider
	local spider_pos = spider.position
	local min_distance = math.huge
	local start_index = 1
	
	for i, wp in ipairs(processed_waypoints) do
		local pos = wp.position or wp
		local dist = math.sqrt((pos.x - spider_pos.x)^2 + (pos.y - spider_pos.y)^2)
		if dist < min_distance then
			min_distance = dist
			start_index = i
		end
	end
	
	-- Cache the successful path for future use
	local cache_key = get_pathfinding_cache_key(spider.position, destination_pos)
	local waypoints_to_cache = {}
	for i = start_index + 1, #processed_waypoints do
		local wp = processed_waypoints[i]
		table.insert(waypoints_to_cache, {x = wp.x, y = wp.y})
	end
	storage.pathfinding_cache[cache_key] = {
		waypoints = waypoints_to_cache,
		cache_tick = game.tick
	}
	
	-- Apply waypoints with minimum spacing, ensuring paths between waypoints don't cross water
	local last_pos = spider_pos
	local min_spacing = (spider.prototype.height + 0.5) * 7.5
	
	for i = start_index + 1, #processed_waypoints do
		local wp = processed_waypoints[i]
		local wp_pos = {x = wp.x, y = wp.y}
		local dist = math.sqrt((wp_pos.x - last_pos.x)^2 + (wp_pos.y - last_pos.y)^2)
		
		if dist > min_spacing then
			-- Check if path from last_pos to this waypoint would cross water
			if not can_traverse_water and line_segment_crosses_water(surface, last_pos, wp_pos, can_traverse_water, spider) then
				-- Path would cross water - add intermediate waypoints to avoid it
				-- Sample points along the path more densely to find safe land points
				local steps = math.max(5, math.ceil(dist / 3.0))  -- Check every ~3 tiles for better coverage
				local last_safe_pos = last_pos
				local found_land_point = false
				
				for step = 1, steps do
					local t = step / steps
					local check_x = last_pos.x + (wp_pos.x - last_pos.x) * t
					local check_y = last_pos.y + (wp_pos.y - last_pos.y) * t
					local check_pos = {x = check_x, y = check_y}
					
					-- Check if this point is on water (check both radius and exact tile)
					local is_water = terrain.is_position_on_water(surface, check_pos, 0.5)
					if not is_water then
						-- Also check the exact tile
						local check_tile = surface.get_tile(math.floor(check_x), math.floor(check_y))
						if check_tile and check_tile.valid then
							local tile_name = check_tile.name:lower()
							is_water = tile_name:find("water") or tile_name:find("lava") or tile_name:find("lake") or tile_name:find("ammoniacal")
						end
					end
					
					if not is_water then
						-- This point is on land - check if path from last_safe_pos to here is safe
						local dist_to_safe = math.sqrt((check_pos.x - last_safe_pos.x)^2 + (check_pos.y - last_safe_pos.y)^2)
						if dist_to_safe >= min_spacing * 0.5 and not line_segment_crosses_water(surface, last_safe_pos, check_pos, can_traverse_water, spider) then
							-- Add intermediate waypoint on land
							spider.add_autopilot_destination(check_pos)
							last_safe_pos = check_pos
							found_land_point = true
						end
					end
				end
				
				-- Check if we can reach the final waypoint from the last safe position
				if not line_segment_crosses_water(surface, last_safe_pos, wp_pos, can_traverse_water, spider) then
					spider.add_autopilot_destination(wp_pos)
					last_pos = wp_pos
				elseif found_land_point then
					-- We found at least one safe intermediate point, but can't reach final waypoint
					-- Keep the last safe position and skip this waypoint
					last_pos = last_safe_pos
				else
					-- No safe intermediate points found - skip this waypoint entirely
					-- This waypoint might be unreachable due to water
				end
			else
				-- Path is safe, add waypoint normally
				spider.add_autopilot_destination(wp_pos)
				last_pos = wp_pos
			end
		end
	end
	
	-- Check final destination path
	if not can_traverse_water and line_segment_crosses_water(surface, last_pos, destination_pos, can_traverse_water, spider) then
		-- Path to destination would cross water - add intermediate waypoints
		local dist = math.sqrt((destination_pos.x - last_pos.x)^2 + (destination_pos.y - last_pos.y)^2)
		local steps = math.max(3, math.ceil(dist / 5.0))
		local last_safe_pos = last_pos
		
		for step = 1, steps do
			local t = step / steps
			local check_x = last_pos.x + (destination_pos.x - last_pos.x) * t
			local check_y = last_pos.y + (destination_pos.y - last_pos.y) * t
			local check_pos = {x = check_x, y = check_y}
			
			-- Check if this point is on water (check both radius and exact tile)
			local is_water = terrain.is_position_on_water(surface, check_pos, 0.5)
			if not is_water then
				-- Also check the exact tile
				local check_tile = surface.get_tile(math.floor(check_x), math.floor(check_y))
				if check_tile and check_tile.valid then
					local tile_name = check_tile.name:lower()
					is_water = tile_name:find("water") or tile_name:find("lava") or tile_name:find("lake") or tile_name:find("ammoniacal")
				end
			end
			
			if not is_water then
				local dist_to_safe = math.sqrt((check_pos.x - last_safe_pos.x)^2 + (check_pos.y - last_safe_pos.y)^2)
				if dist_to_safe >= min_spacing * 0.5 and not line_segment_crosses_water(surface, last_safe_pos, check_pos, can_traverse_water, spider) then
					spider.add_autopilot_destination(check_pos)
					last_safe_pos = check_pos
				end
			end
		end
		
		-- Only add final destination if path is safe
		if not line_segment_crosses_water(surface, last_safe_pos, destination_pos, can_traverse_water, spider) then
			spider.add_autopilot_destination(destination_pos)
		end
	else
		spider.add_autopilot_destination(destination_pos)
	end
	
	status_table.finished = status_table.finished + 1
	status_table.success = true
	
	storage.path_requests[path_result.id] = nil
	
	if status_table.finished == status_table.total_requests then
		storage.pathfinder_statuses[spider.unit_number][start_tick] = nil
	end
end

-- Public wrapper for line_segment_crosses_water
function pathing.line_segment_crosses_water(surface, start_pos, end_pos, can_water, spider)
	return line_segment_crosses_water(surface, start_pos, end_pos, can_water, spider)
end

-- Check if a path can be found from start_pos to end_pos for a spider
-- Uses the same logic as Spidertron Enhancements mod
-- Returns true if path can be found, false if not
-- This is a synchronous check that requests a path and validates the request
function pathing.can_find_path(surface, start_pos, end_pos, spider)
	if not spider or not spider.valid then
		return false
	end
	
	-- Check if destination is too close (pathfinding not needed)
	local distance = math.sqrt((end_pos.x - start_pos.x)^2 + (end_pos.y - start_pos.y)^2)
	if distance < 10 then
		return true
	end
	
	-- Get spider legs
	local success, legs = pcall(function()
		return spider.get_spider_legs()
	end)
	
	if not success or not legs or #legs == 0 then
		-- No legs = can traverse anywhere
		return true
	end
	
	local first_leg = legs[1]
	if not first_leg or not first_leg.valid then
		return true
	end
	
	-- Find valid position nearby target position (in case clicked on water)
	local target_position = surface.find_non_colliding_position(
		first_leg.name,
		end_pos,
		10,
		2
	)
	target_position = target_position or end_pos
	
	-- Get leg collision mask
	local leg_prototype = first_leg.prototype
	if not leg_prototype or not leg_prototype.collision_mask then
		return true
	end
	
	local leg_collision_mask = leg_prototype.collision_mask
	
	-- Build path collision mask (same as Spidertron Enhancements)
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
	
	-- Request a path from the first leg position
	-- Use odd-numbered leg (same as Spidertron Enhancements)
	local leg_to_use = legs[1]
	for i, leg in pairs(legs) do
		if i % 2 == 1 then
			leg_to_use = leg
			break
		end
	end
	
	local request_id = surface.request_path{
		bounding_box = {{-0.01, -0.01}, {0.01, 0.01}},
		collision_mask = path_collision_mask,
		start = {x = leg_to_use.position.x, y = leg_to_use.position.y},
		goal = target_position,
		force = spider.force,
		path_resolution_modifier = -3,
		pathfind_flags = {
			prefer_straight_paths = false,
			cache = false,
			low_priority = false
		},
		entity_to_ignore = leg_to_use
	}
	
	-- If request_id is nil, pathfinding request failed
	-- This means the pathfinder couldn't even start the request
	if not request_id then
		return false
	end
	
	-- Request succeeded - the pathfinder will handle it asynchronously
	-- For assignment purposes, if the request succeeds, we assume a path might be found
	-- The actual pathfinding will be validated when set_smart_destination is called
	-- Note: This is a best-effort check - the actual path may still fail, but that will
	-- be handled when the spider tries to pathfind during assignment
	
	return true
end

return pathing
