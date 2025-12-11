-- Route planning for multi-stop logistics routes
-- Handles multi-pickup, multi-delivery, and mixed routes

local utils = require('lib.utils')
local logging = require('lib.logging')
local constants = require('lib.constants')

local route_planning = {}

-- Initialize distance cache if needed
if not storage.distance_cache then
	storage.distance_cache = {}
end

-- Cached distance calculation
local function get_cached_distance(pos1, pos2)
	-- Initialize cache if needed
	if not storage.distance_cache then
		storage.distance_cache = {}
	end
	
	local key1 = string.format("%.1f,%.1f", pos1.x, pos1.y)
	local key2 = string.format("%.1f,%.1f", pos2.x, pos2.y)
	local cache_key = key1 .. "->" .. key2
	local reverse_key = key2 .. "->" .. key1
	
	local cached = storage.distance_cache[cache_key] or storage.distance_cache[reverse_key]
	if cached and cached.cache_tick then
		local cache_age = game.tick - cached.cache_tick
		if cache_age < constants.distance_cache_ttl then
			return cached.distance
		else
			-- Cache expired
			storage.distance_cache[cache_key] = nil
			storage.distance_cache[reverse_key] = nil
		end
	end
	
	-- Calculate and cache
	local distance = utils.distance(pos1, pos2)
	storage.distance_cache[cache_key] = {
		distance = distance,
		cache_tick = game.tick
	}
	return distance
end

-- Calculate total distance for a route (ordered list of positions)
local function calculate_route_distance(positions)
	if #positions < 2 then return 0 end
	
	local total_distance = 0
	for i = 1, #positions - 1 do
		local pos1 = positions[i]
		local pos2 = positions[i + 1]
		total_distance = total_distance + get_cached_distance(pos1, pos2)
	end
	return total_distance
end

-- Optimize route order using nearest neighbor heuristic
-- Returns ordered list of stops
function route_planning.optimize_route_order(stops, start_position)
	if #stops == 0 then return {} end
	if #stops == 1 then return stops end
	
	-- Create a copy of stops to work with
	local remaining = {}
	for i, stop in ipairs(stops) do
		remaining[i] = stop
	end
	
	local ordered = {}
	local current_pos = start_position
	
	-- Nearest neighbor: always go to closest unvisited stop
	while #remaining > 0 do
		local best_index = 1
		local best_distance = get_cached_distance(current_pos, remaining[1].position)
		
		for i = 2, #remaining do
			local dist = get_cached_distance(current_pos, remaining[i].position)
			if dist < best_distance then
				best_distance = dist
				best_index = i
			end
		end
		
		-- Add best stop to ordered route
		local best_stop = remaining[best_index]
		table.insert(ordered, best_stop)
		current_pos = best_stop.position
		
		-- Remove from remaining
		table.remove(remaining, best_index)
	end
	
	return ordered
end

-- Create a route stop structure
function route_planning.create_stop(stop_type, entity, item, amount, index)
	return {
		type = stop_type,  -- "pickup" or "delivery"
		entity = entity,
		position = entity.position,
		item = item,
		amount = amount,
		index = index or 0,  -- Position in route
		completed = false
	}
end

-- Calculate if multi-stop route is faster than parallel routes
-- Returns: is_faster (bool), route_distance (number), parallel_distance (number)
function route_planning.compare_route_vs_parallel(route_stops, spider_position, parallel_routes)
	-- Calculate total distance for multi-stop route
	local route_positions = {spider_position}
	for _, stop in ipairs(route_stops) do
		table.insert(route_positions, stop.position)
	end
	local route_distance = calculate_route_distance(route_positions)
	
	-- Calculate total distance for parallel routes (sum of all routes)
	local parallel_distance = 0
	for _, parallel_route in ipairs(parallel_routes) do
		local parallel_positions = {spider_position}
		for _, stop in ipairs(parallel_route) do
			table.insert(parallel_positions, stop.position)
		end
		parallel_distance = parallel_distance + calculate_route_distance(parallel_positions)
	end
	
	-- Multi-stop is faster if total distance is less
	-- Add a small threshold (10%) to prefer multi-stop when distances are similar
	local is_faster = route_distance < (parallel_distance * 0.9)
	
	return is_faster, route_distance, parallel_distance
end

-- Feature 1: Multi-Pickup for Single Delivery
-- Find multiple providers for same item, create optimized route
function route_planning.find_multi_pickup_route(requester, item, needed_amount, providers, spider_position)
	-- For multi-pickup, we need at least 2 providers (picking from multiple sources)
	if #providers < 2 then
		return nil
	end
	
	local available_providers = {}
	local total_available = 0
	local checked_count = 0
	
	-- Find all providers that have this item (limit to max candidates for performance)
	for _, provider_data in ipairs(providers) do
		-- Early exit: limit number of candidates checked
		if checked_count >= constants.max_route_candidates then
			break
		end
		checked_count = checked_count + 1
		local provider = provider_data.entity
		if not provider or not provider.valid then goto next_provider end
		
		local item_count = 0
		local allocated = 0
		
		-- TODO: Robot chest support removed - previously checked is_robot_chest
		item_count = provider.get_inventory(defines.inventory.chest).get_item_count(item)
		if not provider_data.allocated_items then
			provider_data.allocated_items = {}
		end
		allocated = provider_data.allocated_items[item] or 0
		
		local can_provide = item_count - allocated
		if can_provide > 0 then
			local amount = math.min(can_provide, needed_amount - total_available)
			table.insert(available_providers, {
				provider_data = provider_data,
				provider = provider,
				amount = amount,
				can_provide = can_provide
			})
			total_available = total_available + can_provide
			
			if total_available >= needed_amount then
				-- Early exit: we have enough items
				break
			end
		end
		
		::next_provider::
	end
	
	-- Need at least 2 providers for multi-pickup to make sense
	-- Even if providers are short, still create route (spider will deliver what it can get)
	if #available_providers < 2 then
		return nil
	end
	
	-- Use actual available amount (may be less than needed)
	local actual_amount = math.min(total_available, needed_amount)
	
	-- Create route stops - take what each provider can give
	local pickup_stops = {}
	local remaining_needed = actual_amount
	for _, provider_info in ipairs(available_providers) do
		-- Take what this provider can give, up to what's still needed
		local amount = math.min(provider_info.can_provide, remaining_needed)
		if amount > 0 then
			table.insert(pickup_stops, route_planning.create_stop("pickup", provider_info.provider, item, amount))
			remaining_needed = remaining_needed - amount
		end
		-- Stop if we've allocated enough
		if remaining_needed <= 0 then
			break
		end
	end
	
	-- Optimize pickup order
	local optimized_pickups = route_planning.optimize_route_order(pickup_stops, spider_position)
	
	-- Add delivery stop at end - deliver what we can actually get
	local delivery_stop = route_planning.create_stop("delivery", requester, item, actual_amount)
	
	-- Build complete route
	local route = {}
	for i, stop in ipairs(optimized_pickups) do
		stop.index = i
		table.insert(route, stop)
	end
	delivery_stop.index = #route + 1
	table.insert(route, delivery_stop)
	
	-- Compare with parallel routes (one spider per provider)
	-- Only compare if we have enough items, otherwise multi-pickup is always better
	local parallel_routes = {}
	if total_available >= needed_amount then
		-- We have enough, compare with parallel routes
		local remaining_for_parallel = needed_amount
		for _, provider_info in ipairs(available_providers) do
			if remaining_for_parallel <= 0 then break end
			local amount = math.min(provider_info.can_provide, remaining_for_parallel)
			if amount > 0 then
				local parallel_route = {
					route_planning.create_stop("pickup", provider_info.provider, item, amount),
					route_planning.create_stop("delivery", requester, item, amount)
				}
				table.insert(parallel_routes, parallel_route)
				remaining_for_parallel = remaining_for_parallel - amount
			end
		end
	else
		-- Providers are short - multi-pickup route is always better than multiple single trips
		-- (one trip picking up from all vs multiple trips)
		logging.info("RoutePlanning", "Providers are short (" .. total_available .. "/" .. needed_amount .. "), using multi-pickup route anyway (better than multiple single trips)")
		return route
	end
	
	local is_faster, route_dist, parallel_dist = route_planning.compare_route_vs_parallel(route, spider_position, parallel_routes)
	
	if is_faster then
		logging.info("RoutePlanning", "Multi-pickup route is faster: " .. string.format("%.2f", route_dist) .. " vs " .. string.format("%.2f", parallel_dist))
		return route
	else
		return nil
	end
end

-- Feature 2: Multi-Delivery from Single Pickup
-- Find multiple requesters for same item, create optimized delivery route
function route_planning.find_multi_delivery_route(provider, item, available_amount, requesters, spider_position)
	-- For multi-delivery, we need at least 2 requesters (delivering to multiple destinations)
	if #requesters < 2 then
		return nil
	end
	
	local available_requesters = {}
	local total_needed = 0
	local checked_count = 0
	
	-- Find all requesters that need this item (limit to max candidates for performance)
	-- Note: requesters is a list of item_request objects, not requester_data objects
	for i, item_request in ipairs(requesters) do
		-- Early exit: limit number of candidates checked
		if checked_count >= constants.max_route_candidates then
			break
		end
		checked_count = checked_count + 1
		-- Only process requests for the same item
		if item_request.requested_item ~= item then
			goto next_requester
		end
		
		local requester = item_request.entity
		local requester_data = item_request.requester_data
		
		if not requester or not requester.valid then 
			goto next_requester 
		end
		if not requester.can_insert(item) then 
			goto next_requester 
		end
		
		-- Use real_amount from item_request (already calculated)
		local real_amount = item_request.real_amount
		
		if real_amount > 0 then
			-- Don't limit by available_amount - we want to find ALL requesters that need this item
			-- The amount will be limited later when creating the route
			local amount = real_amount
			table.insert(available_requesters, {
				requester_data = requester_data,
				requester = requester,
				amount = amount,
				real_amount = real_amount
			})
			total_needed = total_needed + amount
			-- Don't break - continue to find all requesters
		end
		
		::next_requester::
	end
	
	-- Need at least 2 requesters for multi-delivery to make sense
	if #available_requesters < 2 or total_needed == 0 then
		return nil
	end
	
	-- Create route stops
	-- Limit amounts based on what's actually available from the provider
	local delivery_stops = {}
	local remaining_available = available_amount
	for _, requester_info in ipairs(available_requesters) do
		if remaining_available <= 0 then break end
		local delivery_amount = math.min(requester_info.amount, remaining_available)
		if delivery_amount > 0 then
			table.insert(delivery_stops, route_planning.create_stop("delivery", requester_info.requester, item, delivery_amount))
			remaining_available = remaining_available - delivery_amount
		end
	end
	
	-- Optimize delivery order
	local optimized_deliveries = route_planning.optimize_route_order(delivery_stops, provider.position)
	
	-- Build complete route (pickup first, then deliveries)
	local route = {}
	local pickup_stop = route_planning.create_stop("pickup", provider, item, available_amount)
	pickup_stop.index = 1
	table.insert(route, pickup_stop)
	
	for i, stop in ipairs(optimized_deliveries) do
		stop.index = i + 1
		table.insert(route, stop)
	end
	
	-- Compare with parallel routes (one spider per requester)
	local parallel_routes = {}
	for _, requester_info in ipairs(available_requesters) do
		local parallel_route = {
			route_planning.create_stop("pickup", provider, item, requester_info.amount),
			route_planning.create_stop("delivery", requester_info.requester, item, requester_info.amount)
		}
		table.insert(parallel_routes, parallel_route)
	end
	
	local is_faster, route_dist, parallel_dist = route_planning.compare_route_vs_parallel(route, spider_position, parallel_routes)
	
	if is_faster then
		logging.info("RoutePlanning", "Multi-delivery route is faster: " .. string.format("%.2f", route_dist) .. " vs " .. string.format("%.2f", parallel_dist))
		return route
	else
		return nil
	end
end

-- Feature 3: Multi-Pickup for Multiple Items
-- One requester needs multiple items, find providers for each
function route_planning.find_multi_item_route(requester, requested_items, providers, spider_position)
	-- Skip route planning for very small networks
	if #providers < constants.min_network_size_for_routes then
		return nil
	end
	
	-- requested_items is {[item_name] = count, ...}
	local item_providers = {}  -- {item_name = {providers...}}
	local total_items = 0
	local checked_count = 0
	
	-- Find providers for each requested item (limit to max candidates for performance)
	for item, needed_amount in pairs(requested_items) do
		-- Early exit: limit number of items checked
		if total_items >= 10 then
			break
		end
		
		if needed_amount <= 0 then goto next_item end
		
		local item_provider_list = {}
		local total_available = 0
		
		for _, provider_data in ipairs(providers) do
			-- Early exit: limit number of providers checked per item
			if checked_count >= constants.max_route_candidates then
				break
			end
			checked_count = checked_count + 1
			local provider = provider_data.entity
			if not provider or not provider.valid then goto next_provider end
			
			local item_count = 0
			local allocated = 0
			
			if provider_data.is_robot_chest then
				if provider_data.contains and provider_data.contains[item] then
					item_count = provider_data.contains[item]
				else
					item_count = provider.get_inventory(defines.inventory.chest).get_item_count(item)
				end
				allocated = 0
			else
				item_count = provider.get_inventory(defines.inventory.chest).get_item_count(item)
				if not provider_data.allocated_items then
					provider_data.allocated_items = {}
				end
				allocated = provider_data.allocated_items[item] or 0
			end
			
			local can_provide = item_count - allocated
			if can_provide > 0 then
				local amount = math.min(can_provide, needed_amount - total_available)
				table.insert(item_provider_list, {
					provider_data = provider_data,
					provider = provider,
					amount = amount,
					can_provide = can_provide
				})
				total_available = total_available + can_provide
				
				if total_available >= needed_amount then
					break
				end
			end
			
			::next_provider::
		end
		
		if #item_provider_list > 0 and total_available >= needed_amount then
			item_providers[item] = item_provider_list
			total_items = total_items + 1
		end
		
		::next_item::
	end
	
	-- Need at least 2 different items for multi-item route
	if total_items < 2 then
		return nil
	end
	
	-- Create pickup stops for all items
	local all_pickup_stops = {}
	for item, provider_list in pairs(item_providers) do
		for _, provider_info in ipairs(provider_list) do
			local amount = math.min(provider_info.amount, requested_items[item])
			table.insert(all_pickup_stops, route_planning.create_stop("pickup", provider_info.provider, item, amount))
		end
	end
	
	-- Optimize pickup order
	local optimized_pickups = route_planning.optimize_route_order(all_pickup_stops, spider_position)
	
	-- Add delivery stop at end (deliver all items to requester)
	local delivery_stop = route_planning.create_stop("delivery", requester, nil, nil)  -- nil item/amount means deliver all
	delivery_stop.items = requested_items  -- Track which items to deliver
	
	-- Build complete route
	local route = {}
	for i, stop in ipairs(optimized_pickups) do
		stop.index = i
		table.insert(route, stop)
	end
	delivery_stop.index = #route + 1
	table.insert(route, delivery_stop)
	
	-- Compare with parallel routes (one spider per item)
	local parallel_routes = {}
	for item, provider_list in pairs(item_providers) do
		for _, provider_info in ipairs(provider_list) do
			local amount = math.min(provider_info.amount, requested_items[item])
			local parallel_route = {
				route_planning.create_stop("pickup", provider_info.provider, item, amount),
				route_planning.create_stop("delivery", requester, item, amount)
			}
			table.insert(parallel_routes, parallel_route)
		end
	end
	
	local is_faster, route_dist, parallel_dist = route_planning.compare_route_vs_parallel(route, spider_position, parallel_routes)
	
	if is_faster then
		logging.info("RoutePlanning", "Multi-item route is faster: " .. string.format("%.2f", route_dist) .. " vs " .. string.format("%.2f", parallel_dist))
		return route
	else
		return nil
	end
end

-- Feature 4: Mixed Multi-Pickup and Multi-Delivery
-- Multiple providers and multiple requesters for same item
function route_planning.find_mixed_route(item, needed_amount, providers, requesters, spider_position)
	-- For mixed routes (multi-pickup + multi-delivery), we need at least 2 providers and 2 requesters
	if #providers < 2 or #requesters < 2 then
		return nil
	end
	
	-- Find all providers that have this item (limit to max candidates for performance)
	local available_providers = {}
	local total_available = 0
	local checked_providers = 0
	for _, provider_data in ipairs(providers) do
		-- Early exit: limit number of providers checked
		if checked_providers >= constants.max_route_candidates then
			break
		end
		checked_providers = checked_providers + 1
		local provider = provider_data.entity
		if not provider or not provider.valid then goto next_provider end
		
		local item_count = 0
		local allocated = 0
		
		-- TODO: Robot chest support removed - previously checked is_robot_chest
		item_count = provider.get_inventory(defines.inventory.chest).get_item_count(item)
		if not provider_data.allocated_items then
			provider_data.allocated_items = {}
		end
		allocated = provider_data.allocated_items[item] or 0
		
		local can_provide = item_count - allocated
		if can_provide > 0 then
			local amount = math.min(can_provide, needed_amount - total_available)
			table.insert(available_providers, {
				provider_data = provider_data,
				provider = provider,
				amount = amount,
				can_provide = can_provide
			})
			total_available = total_available + can_provide
		end
		
		::next_provider::
	end
	
	-- Find all requesters that need this item (limit to max candidates for performance)
	local available_requesters = {}
	local total_needed = 0
	local checked_requesters = 0
	for i, item_request in ipairs(requesters) do
		-- Early exit: limit number of requesters checked
		if checked_requesters >= constants.max_route_candidates then
			break
		end
		checked_requesters = checked_requesters + 1
		if item_request.requested_item == item and item_request.real_amount > 0 then
			local requester = item_request.entity
			local requester_data = item_request.requester_data
			
			if not requester or not requester.valid then 
				goto next_requester
			end
			if not requester.can_insert(item) then 
				goto next_requester 
			end
			
			local amount = math.min(item_request.real_amount, needed_amount - total_needed)
			if amount > 0 then
				table.insert(available_requesters, {
					requester_data = requester_data,
					requester = requester,
					amount = amount,
					real_amount = item_request.real_amount
				})
				total_needed = total_needed + amount
			end
		end
		::next_requester::
	end
	
	-- Need at least 2 providers AND 2 requesters
	if #available_providers < 2 or #available_requesters < 2 then
		return nil
	end
	
	-- Calculate how much we can actually fulfill
	local fulfillable = math.min(total_available, total_needed, needed_amount)
	
	-- Create all pickup stops
	local pickup_stops = {}
	local remaining_to_pickup = fulfillable
	for _, provider_info in ipairs(available_providers) do
		if remaining_to_pickup <= 0 then break end
		local amount = math.min(provider_info.can_provide, remaining_to_pickup)
		if amount > 0 then
			table.insert(pickup_stops, route_planning.create_stop("pickup", provider_info.provider, item, amount))
			remaining_to_pickup = remaining_to_pickup - amount
		end
	end
	
	-- Create all delivery stops
	local delivery_stops = {}
	local remaining_to_deliver = fulfillable
	for _, requester_info in ipairs(available_requesters) do
		if remaining_to_deliver <= 0 then break end
		local amount = math.min(requester_info.real_amount, remaining_to_deliver)
		if amount > 0 then
			table.insert(delivery_stops, route_planning.create_stop("delivery", requester_info.requester, item, amount))
			remaining_to_deliver = remaining_to_deliver - amount
		end
	end
	
	-- Optimize pickup order
	local optimized_pickups = route_planning.optimize_route_order(pickup_stops, spider_position)
	
	-- Optimize delivery order (starting from last pickup location)
	local last_pickup_pos = optimized_pickups[#optimized_pickups].position
	local optimized_deliveries = route_planning.optimize_route_order(delivery_stops, last_pickup_pos)
	
	-- Build complete route: all pickups, then all deliveries
	local route = {}
	for i, stop in ipairs(optimized_pickups) do
		stop.index = i
		table.insert(route, stop)
	end
	for i, stop in ipairs(optimized_deliveries) do
		stop.index = #route + i
		table.insert(route, stop)
	end
	
	-- Compare with parallel routes
	-- Parallel routes: one spider per requester, but each spider may need to visit multiple providers
	-- This accounts for cases where a requester needs items from multiple providers
	local parallel_routes = {}
	local remaining_fulfillable = fulfillable
	local provider_allocations = {}  -- Track how much each provider has been allocated to parallel routes
	for _, provider_info in ipairs(available_providers) do
		provider_allocations[provider_info.provider.unit_number] = 0
	end
	
	for _, requester_info in ipairs(available_requesters) do
		if remaining_fulfillable <= 0 then break end
		local requester_amount = math.min(requester_info.amount, remaining_fulfillable)
		if requester_amount > 0 then
			-- Build a route for this requester, potentially using multiple providers
			local requester_route = {}
			local remaining_for_requester = requester_amount
			
			-- Find providers to fulfill this requester's need (may need multiple)
			-- Sort providers by distance to requester for optimal route
			local sorted_providers = {}
			for _, provider_info in ipairs(available_providers) do
				local allocated = provider_allocations[provider_info.provider.unit_number] or 0
				local available = provider_info.can_provide - allocated
				if available > 0 then
					local dist = get_cached_distance(requester_info.requester.position, provider_info.provider.position)
					table.insert(sorted_providers, {
						provider_info = provider_info,
						distance = dist,
						available = available
					})
				end
			end
			-- Sort by distance (closest first)
			table.sort(sorted_providers, function(a, b) return a.distance < b.distance end)
			
			-- Create pickup stops from providers (may be multiple)
			for _, sorted_prov in ipairs(sorted_providers) do
				if remaining_for_requester <= 0 then break end
				local provider_info = sorted_prov.provider_info
				local allocated = provider_allocations[provider_info.provider.unit_number] or 0
				local available = provider_info.can_provide - allocated
				local pickup_amount = math.min(available, remaining_for_requester)
				
				if pickup_amount > 0 then
					table.insert(requester_route, route_planning.create_stop("pickup", provider_info.provider, item, pickup_amount))
					provider_allocations[provider_info.provider.unit_number] = allocated + pickup_amount
					remaining_for_requester = remaining_for_requester - pickup_amount
				end
			end
			
			-- If we got enough items, add delivery stop
			if remaining_for_requester < requester_amount and #requester_route > 0 then
				local actual_delivery = requester_amount - remaining_for_requester
				table.insert(requester_route, route_planning.create_stop("delivery", requester_info.requester, item, actual_delivery))
				table.insert(parallel_routes, requester_route)
				remaining_fulfillable = remaining_fulfillable - actual_delivery
			end
		end
	end
	
	local is_faster, route_dist, parallel_dist = route_planning.compare_route_vs_parallel(route, spider_position, parallel_routes)
	
	if is_faster then
		logging.info("RoutePlanning", "Mixed multi-pickup/multi-delivery route is faster: " .. string.format("%.2f", route_dist) .. " vs " .. string.format("%.2f", parallel_dist))
		return route
	else
		return nil
	end
end

-- Feature 5: Multi-Item, Multi-Requester Route
-- Multiple providers with different items, multiple requesters needing different items
-- Example: Provider A has Item X, Provider B has Item Y, Requester 1 needs X, Requester 2 needs Y
function route_planning.find_multi_item_multi_requester_route(requesters, providers, spider_position)
	-- For multi-item, multi-requester routes, we need at least:
	-- - 2 different items (checked later)
	-- - 2 requesters (one per item minimum)
	-- - 2 providers (to make it worthwhile)
	-- So we can use a lower threshold than other route types
	if #providers < 2 or #requesters < 2 then
		log("[ROUTE_PLANNING] find_multi_item_multi_requester_route: Too few providers (" .. #providers .. ") or requesters (" .. #requesters .. ")")
		return nil
	end
	
	-- Group requests by item
	local requests_by_item = {}
	for _, item_request in ipairs(requesters) do
		local item = item_request.requested_item
		if item and item_request.real_amount > 0 then
			if not requests_by_item[item] then
				requests_by_item[item] = {}
			end
			table.insert(requests_by_item[item], item_request)
		end
	end
	
	-- Need at least 2 different items for this to make sense
	local item_count = 0
	for item, _ in pairs(requests_by_item) do
		item_count = item_count + 1
		log("[ROUTE_PLANNING] find_multi_item_multi_requester_route: Item " .. item_count .. " = " .. item)
	end
	if item_count < 2 then
		log("[ROUTE_PLANNING] find_multi_item_multi_requester_route: Only " .. item_count .. " item(s), need 2+")
		return nil
	end
	
	-- For each item, find providers and requesters
	local item_routes = {}  -- {item = {providers = {...}, requesters = {...}}}
	for item, item_requests in pairs(requests_by_item) do
		-- Find providers for this item
		local available_providers = {}
		local total_available = 0
		-- TODO: Robot chest support removed - previously tracked robot_chest_count
		for _, provider_data in ipairs(providers) do
			local provider = provider_data.entity
			if not provider or not provider.valid then goto next_provider end
			
			local item_count = 0
			local allocated = 0
			
			-- TODO: Robot chest support removed - previously checked is_robot_chest
			item_count = provider.get_inventory(defines.inventory.chest).get_item_count(item)
			if not provider_data.allocated_items then
				provider_data.allocated_items = {}
			end
			allocated = provider_data.allocated_items[item] or 0
			
			local can_provide = item_count - allocated
			if can_provide > 0 then
				table.insert(available_providers, {
					provider_data = provider_data,
					provider = provider,
					can_provide = can_provide
				})
				total_available = total_available + can_provide
				log("[ROUTE_PLANNING] Provider " .. provider.unit_number .. " (custom) can provide " .. can_provide .. " " .. item)
			end
			
			::next_provider::
		end
		
		log("[ROUTE_PLANNING] Item " .. item .. " - total_providers=" .. #providers .. ", available_providers=" .. #available_providers)
		
		-- Find requesters for this item
		local available_requesters = {}
		local total_needed = 0
		for _, item_request in ipairs(item_requests) do
			local requester = item_request.entity
			local requester_data = item_request.requester_data
			
			if not requester or not requester.valid then goto next_requester end
			if not requester.can_insert(item) then goto next_requester end
			
			local real_amount = item_request.real_amount
			if real_amount > 0 then
				table.insert(available_requesters, {
					requester_data = requester_data,
					requester = requester,
					amount = real_amount,
					real_amount = real_amount
				})
				total_needed = total_needed + real_amount
			end
			
			::next_requester::
		end
		
		-- Need at least 1 provider and 1 requester for this item
		log("[ROUTE_PLANNING] find_multi_item_multi_requester_route: Item " .. item .. " - providers=" .. #available_providers .. ", requesters=" .. #available_requesters .. ", total_available=" .. total_available .. ", total_needed=" .. total_needed)
		if #available_providers > 0 and #available_requesters > 0 then
			item_routes[item] = {
				providers = available_providers,
				requesters = available_requesters,
				total_available = total_available,
				total_needed = total_needed
			}
			log("[ROUTE_PLANNING] find_multi_item_multi_requester_route: Item " .. item .. " added to item_routes")
		else
			log("[ROUTE_PLANNING] find_multi_item_multi_requester_route: Item " .. item .. " SKIPPED - no providers or requesters")
		end
	end
	
	-- Need at least 2 items with both providers and requesters
	local valid_item_count = 0
	for item, _ in pairs(item_routes) do
		valid_item_count = valid_item_count + 1
		log("[ROUTE_PLANNING] find_multi_item_multi_requester_route: Valid item " .. valid_item_count .. " = " .. item)
	end
	if valid_item_count < 2 then
		log("[ROUTE_PLANNING] find_multi_item_multi_requester_route: Only " .. valid_item_count .. " valid item(s), need 2+")
		return nil
	end
	
	-- Build route: pickups first (all items), then deliveries (all items)
	local all_pickup_stops = {}
	local all_delivery_stops = {}
	local provider_allocations = {}  -- Track allocations per provider
	local requester_allocations = {}  -- Track allocations per requester
	local picked_up_amounts = {}  -- Track how much of each item was actually picked up
	
	-- Create pickup stops for all items
	for item, item_route in pairs(item_routes) do
		picked_up_amounts[item] = 0
		local remaining_needed = math.min(item_route.total_needed, item_route.total_available)
		for _, provider_info in ipairs(item_route.providers) do
			if remaining_needed <= 0 then break end
			
			local provider = provider_info.provider
			local provider_key = provider.unit_number
			if not provider_allocations[provider_key] then
				provider_allocations[provider_key] = {}
			end
			local allocated = provider_allocations[provider_key][item] or 0
			local available = math.min(provider_info.can_provide - allocated, remaining_needed)
			
			if available > 0 then
				table.insert(all_pickup_stops, route_planning.create_stop("pickup", provider, item, available))
				provider_allocations[provider_key][item] = allocated + available
				picked_up_amounts[item] = picked_up_amounts[item] + available
				remaining_needed = remaining_needed - available
			end
		end
	end
	
	-- Create delivery stops for all items (based on what was actually picked up)
	for item, item_route in pairs(item_routes) do
		local remaining_picked_up = picked_up_amounts[item] or 0
		for _, requester_info in ipairs(item_route.requesters) do
			if remaining_picked_up <= 0 then break end
			
			local requester = requester_info.requester
			local requester_key = requester.unit_number
			if not requester_allocations[requester_key] then
				requester_allocations[requester_key] = {}
			end
			local allocated = requester_allocations[requester_key][item] or 0
			local needed = requester_info.amount - allocated
			local delivery_amount = math.min(needed, remaining_picked_up)
			
			if delivery_amount > 0 then
				table.insert(all_delivery_stops, route_planning.create_stop("delivery", requester, item, delivery_amount))
				requester_allocations[requester_key][item] = allocated + delivery_amount
				remaining_picked_up = remaining_picked_up - delivery_amount
			end
		end
	end
	
	if #all_pickup_stops == 0 or #all_delivery_stops == 0 then
		return nil
	end
	
	-- Optimize pickup order
	local optimized_pickups = route_planning.optimize_route_order(all_pickup_stops, spider_position)
	
	-- Optimize delivery order (start from last pickup position)
	local last_pickup_pos = optimized_pickups[#optimized_pickups].entity.position
	local optimized_deliveries = route_planning.optimize_route_order(all_delivery_stops, last_pickup_pos)
	
	-- Build complete route
	local route = {}
	for i, stop in ipairs(optimized_pickups) do
		stop.index = i
		table.insert(route, stop)
	end
	for i, stop in ipairs(optimized_deliveries) do
		stop.index = #route + i
		table.insert(route, stop)
	end
	
	-- Compare with parallel routes (one spider per item-requester pair)
	local parallel_routes = {}
	for item, item_route in pairs(item_routes) do
		for _, provider_info in ipairs(item_route.providers) do
			for _, requester_info in ipairs(item_route.requesters) do
				local amount = math.min(provider_info.can_provide, requester_info.amount)
				if amount > 0 then
					local parallel_route = {
						route_planning.create_stop("pickup", provider_info.provider, item, amount),
						route_planning.create_stop("delivery", requester_info.requester, item, amount)
					}
					table.insert(parallel_routes, parallel_route)
				end
			end
		end
	end
	
	local is_faster, route_dist, parallel_dist = route_planning.compare_route_vs_parallel(route, spider_position, parallel_routes)
	
	if is_faster then
		logging.info("RoutePlanning", "Multi-item, multi-requester route is faster: " .. string.format("%.2f", route_dist) .. " vs " .. string.format("%.2f", parallel_dist))
		return route
	else
		return nil
	end
end

return route_planning

