-- utils.lua
-- Utility functions for spidertron logistics system
-- Adapted from another mod, some functions marked as redundant or needing modification

-- ============================================================================
-- DISTANCE CALCULATIONS
-- ============================================================================

-- REDUNDANT: We already have a distance() function in control.lua
--[[
function calculate_distance(pos1, pos2)
    return ((pos1.x - pos2.x)^2 + (pos1.y - pos2.y)^2)^0.5
end
]]

-- ============================================================================
-- WATER DETECTION
-- ============================================================================

-- USEFUL: Check if a position is on or near water
-- MODIFIED: Will be used to check spider collision mask for water capability
function is_position_on_water(surface, position, check_radius)
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

-- MODIFY: Check if spider can traverse water based on collision mask
-- TODO: Implement check_spider_water_capability(spider) function
-- This should check the spider's prototype collision_mask for water-tile

-- POTENTIALLY USEFUL: Find safe position away from water
-- NOTE: May be useful for pathfinding fallback, but spiders should handle this via pathfinding
--[[
function find_safe_position_away_from_water(surface, entity, start_position, max_search_radius)
    max_search_radius = max_search_radius or 20  -- Default: search up to 20 tiles away
    
    -- First, try to find a non-colliding position using the game's built-in function
    if surface.find_non_colliding_position then
        local safe_pos = surface.find_non_colliding_position(entity.name, start_position, max_search_radius, 0.5)
        if safe_pos then
            -- Verify it's not on water
            if not is_position_on_water(surface, safe_pos, 1.5) then
                return safe_pos
            end
        end
    end
    
    -- Fallback: Search in expanding circles for a safe position
    local random = game.create_random_generator()
    for radius = 2, max_search_radius, 2 do
        -- Try multiple random positions at this radius
        for attempt = 1, 8 do
            local angle = random(0, 360)
            local test_pos = {
                x = start_position.x + math.cos(math.rad(angle)) * radius,
                y = start_position.y + math.sin(math.rad(angle)) * radius
            }
            
            -- Check if this position is safe (not on water and can place entity)
            if not is_position_on_water(surface, test_pos, 1.5) then
                if surface.find_non_colliding_position then
                    local safe_pos = surface.find_non_colliding_position(entity.name, test_pos, 2, 0.5)
                    if safe_pos and not is_position_on_water(surface, safe_pos, 1.5) then
                        return safe_pos
                    end
                else
                    -- Fallback: just return the position if it's not on water
                    return test_pos
                end
            end
        end
    end
    
    -- If we couldn't find a safe position, return nil
    return nil
end
]]

-- ============================================================================
-- CLIFF DETECTION
-- ============================================================================

-- USEFUL: Check if a position is near a corner cliff (2+ cliffs at different angles)
-- MODIFIED: Will be used to detect if small spiders should avoid cliffs
function is_position_near_corner_cliff(surface, position, check_radius)
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

-- USEFUL: Check if a waypoint path segment is traveling parallel to a cliff
-- MODIFIED: Will be used in pathfinding to avoid getting stuck along cliffs
function is_waypoint_parallel_to_cliff(surface, waypoint_pos, prev_pos, next_pos, check_radius)
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

-- USEFUL: Check if a waypoint is crossing a straight cliff (2-3 cliffs in a line)
-- MODIFIED: Larger spiders can cross straight cliffs, this helps identify them
function is_waypoint_crossing_straight_cliff(surface, waypoint_pos, prev_pos, next_pos, check_radius)
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

-- ============================================================================
-- ENEMY DETECTION
-- ============================================================================

-- TODO: Add function to detect enemies along path
-- This should be used to prefer routes avoiding enemies for logistic spiders
-- function detect_enemies_along_path(surface, start_pos, end_pos, check_radius)

-- ============================================================================
-- PATHFINDING & WAYPOINTS
-- ============================================================================

-- VERY USEFUL: Request multiple paths for waypoint system
-- MODIFIED: This will be used for long-distance pathing with waypoints
-- TODO: Adapt for spidertron logistics - remove party-specific code, use for beacon-to-beacon pathing
function request_multiple_paths(position, target_pos, surface, spider_unit_number)
    -- Validate inputs
    if not position or not position.x or not position.y then
        return false
    end
    if not target_pos or not target_pos.x or not target_pos.y then
        return false
    end
    if not surface or not surface.valid then
        return false
    end

    -- TODO: Get spider entity to check collision mask
    -- local spider = game.get_entity_by_unit_number(spider_unit_number)
    -- local collision_mask = get_spider_collision_mask(spider)

    local path_collision_mask = {
        layers = {
            water_tile = true,
            cliff = true  -- Prefer avoiding cliffs in pathfinding
        },
        colliding_with_tiles_only = true,
        consider_tile_transitions = true
    }

    local start_offsets = {
        {x = 0, y = 0},
        -- Can add more offsets for path diversity
    }

    storage.path_requests = storage.path_requests or {}
    for i, offset in ipairs(start_offsets) do
        local start_pos = {x = position.x + offset.x, y = position.y + offset.y}
        local chunk_x = math.floor(target_pos.x / 32)
        local chunk_y = math.floor(target_pos.y / 32)
        
        -- Validate chunk
        if not surface.is_chunk_generated({x = chunk_x, y = chunk_y}) then
            return false
        end

        -- TODO: Use spider's force instead of hardcoded "player"
        local request_id = surface.request_path{
            start = start_pos,
            goal = target_pos,
            force = "player",  -- TODO: Get from spider entity
            bounding_box = {{-0.5, -0.5}, {0.5, 0.5}},  -- TODO: Get from spider prototype
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
            local request_data = {
                chunk_x = chunk_x,
                chunk_y = chunk_y,
                target_pos = target_pos,
                resolution = -3,
                start_offset_index = i,
                total_requests = #start_offsets,
                spider_unit_number = spider_unit_number
            }
            storage.path_requests[request_id] = request_data
            return true
        end
    end
    return false
end

-- POTENTIALLY USEFUL: Schedule autopilot destinations for waypoint system
-- MODIFIED: May be useful for multi-waypoint pathing
--[[
function schedule_autopilot_destination(spider, destination, tick, should_scan)
    local entity = spider.entity
    local unit_number = entity.unit_number
    
    if not storage.scheduled_autopilots then
        storage.scheduled_autopilots = {}
    end
    
    storage.scheduled_autopilots[unit_number] = {
        destination = destination,
        tick = tick,
        should_scan = should_scan or false
    }
end
]]

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

-- USEFUL: Get a random position within a radius
function get_random_position_in_radius(position, radius)
    local angle = math.random() * 2 * math.pi
    local length = radius * math.random() ^ 0.25
    local x = position.x + length * math.cos(angle)
    local y = position.y + length * math.sin(angle)
    return { x = x, y = y }
end

-- USEFUL: Get chunk position from tile position
function get_chunk_pos(position)
    return {
        x = math.floor(position.x / 32),
        y = math.floor(position.y / 32),
    }
end

-- USEFUL: Table map function
function table.map(tbl, func)
    local result = {}
    for _, v in ipairs(tbl) do
        table.insert(result, func(v))
    end
    return result
end

-- ============================================================================
-- NOT NEEDED FOR LOGISTICS MOD
-- ============================================================================

-- NOT NEEDED: Color updates (for combat bots)
--[[
function update_color(entity, state)
    -- ... (removed)
end
]]

-- NOT NEEDED: Random destination generation (for scouting)
--[[
function generate_random_destinations(...)
    -- ... (removed)
end
]]

-- NOT NEEDED: Autopilot queue processing (too complex for logistics)
--[[
function process_autopilot_queue(event)
    -- ... (removed)
end
]]

-- NOT NEEDED: Waking state cleanup (for combat bots)
--[[
function cleanup_waking_state(creeper)
    -- ... (removed)
end
]]

-- NOT NEEDED: Unvisited chunk finding (for scouting)
--[[
function get_unvisited_chunk(position, party)
    -- ... (removed)
end
]]

-- ============================================================================
-- TERRITORY/CHUNK TRACKING (POTENTIALLY USEFUL FOR BEACON ASSIGNMENT)
-- ============================================================================

-- POTENTIALLY USEFUL: Chunk territory tracking
-- MODIFIED: May be useful for tracking beacon coverage areas
--[[
function get_territory_for_surface(surface)
    if not surface or not surface.valid then
        return nil
    end
    local surface_id = surface.index
    storage.territory = storage.territory or {}
    storage.territory[surface_id] = storage.territory[surface_id] or {}
    return storage.territory[surface_id]
end

function get_chunk_data(surface, chunk_x, chunk_y)
    local territory = get_territory_for_surface(surface)
    if not territory then return nil end
    
    local chunk_key = chunk_x .. "," .. chunk_y
    return territory[chunk_key] or {safe = nil, visits = 0, last_checked = 0}
end

function mark_chunk_visited(surface, chunk_x, chunk_y, is_safe, tick)
    local territory = get_territory_for_surface(surface)
    if not territory then return end
    
    local chunk_key = chunk_x .. "," .. chunk_y
    local chunk_data = territory[chunk_key] or {safe = nil, visits = 0, last_checked = 0}
    
    chunk_data.visits = chunk_data.visits + 1
    chunk_data.last_checked = tick or game.tick
    
    if is_safe ~= nil then
        chunk_data.safe = is_safe
    end
    
    territory[chunk_key] = chunk_data
end
]]

-- ============================================================================
-- TODO: FUNCTIONS TO IMPLEMENT
-- ============================================================================

-- TODO: Check if spider can traverse water based on collision mask
-- function check_spider_water_capability(spider)
--     local prototype = spider.prototype
--     local collision_mask = prototype.collision_mask
--     -- Check if collision_mask includes "water-tile"
--     -- Return true if spider can traverse water, false otherwise
-- end

-- TODO: Check spider size for cliff collision
-- function check_spider_cliff_capability(spider)
--     local prototype = spider.prototype
--     local collision_box = prototype.collision_box
--     local size = math.max(collision_box.right_bottom.x - collision_box.left_top.x,
--                          collision_box.right_bottom.y - collision_box.left_top.y)
--     -- Return true if spider is large enough to cross cliffs
-- end

-- TODO: Detect enemies along path
-- function detect_enemies_along_path(surface, start_pos, end_pos, check_radius)
--     -- Find enemy entities between start and end positions
--     -- Return count or list of enemies
-- end

-- TODO: Get spider collision mask for pathfinding
-- function get_spider_collision_mask(spider)
--     -- Return appropriate collision mask based on spider's capabilities
-- end

