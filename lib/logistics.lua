-- Core logistics functions: spiders, requesters, providers, and assignment

local constants = require('lib.constants')
local beacon_assignment = require('lib.beacon_assignment')
local rendering = require('lib.rendering')
local utils = require('lib.utils')
local pathing = require('lib.pathing')
local terrain = require('lib.terrain')
local logging = require('lib.logging')

local logistics = {}

function logistics.spiders()
	local valid = {}
	local total_spiders = 0
	local inactive_count = 0
	local busy_count = 0
	local no_network_count = 0
	local has_driver_count = 0
	
	for _, spider_data in pairs(storage.spiders) do
		total_spiders = total_spiders + 1
		local spider = spider_data.entity
		if not spider.valid then goto valid end
		if not spider_data.active then 
			inactive_count = inactive_count + 1
			goto valid 
		end  -- Check logistics activation state
		if spider_data.status ~= constants.idle then 
			busy_count = busy_count + 1
			goto valid 
		end
		if spider.get_driver() ~= nil then 
			has_driver_count = has_driver_count + 1
			goto valid 
		end
		
		local network = beacon_assignment.spidertron_network(spider)
		if network == nil then
			no_network_count = no_network_count + 1
			rendering.draw_missing_roboport_icon(spider, {0, -1.75})
			goto valid
		end
		
		-- Only active spiders participate in logistics
		if spider_data.active then
			local network_key = network.network_key
			if not valid[network_key] then
				valid[network_key] = {}
			end
			valid[network_key][#valid[network_key] + 1] = spider
		end
		::valid::
	end
	
	local available_count = 0
	for _, spids in pairs(valid) do
		available_count = available_count + #spids
	end
	
	-- logging.debug("Spiders", "Total: " .. total_spiders .. " | Available: " .. available_count .. " | Inactive: " .. inactive_count .. " | Busy: " .. busy_count .. " | No network: " .. no_network_count .. " | Has driver: " .. has_driver_count)
	
	return valid
end

local function requester_sort_function(a, b)
	local a_filled = a.percentage_filled
	local b_filled = b.percentage_filled
	return a_filled == b_filled and a.random_sort_order < b.random_sort_order or a_filled < b_filled
end

function logistics.requesters()
	local result = {}
	local random = math.random
	local sort = table.sort
	
	for _, requester_data in pairs(storage.requesters) do
		local requester = requester_data.entity
		if not requester.valid then goto continue end
		if requester.to_be_deconstructed() then goto continue end
		
		local network = beacon_assignment.spidertron_network(requester)
		if network == nil then
			rendering.draw_missing_roboport_icon(requester)
			goto continue
		end
		
		-- Migrate old format if needed
		if not requester_data.requested_items then
			requester_data.requested_items = {}
			if requester_data.requested_item then
				requester_data.requested_items[requester_data.requested_item] = requester_data.request_size or 0
			end
		end
		
		-- Process each requested item
		for item, request_size in pairs(requester_data.requested_items) do
			if not item or item == '' or request_size <= 0 then goto next_item end
			if not requester.can_insert(item) then goto next_item end
			
			if not requester_data.incoming_items then
				requester_data.incoming_items = {}
			end
			local incoming = requester_data.incoming_items[item] or 0
			local already_had = requester.get_item_count(item)
			
			local real_amount = request_size - incoming - already_had
			if real_amount <= 0 then goto next_item end
			
			-- Create a request entry for this item
			local item_request = {
				entity = requester,
				requester_data = requester_data,
				requested_item = item,
				request_size = request_size,
				real_amount = real_amount,
				incoming = incoming,
				already_had = already_had,
				percentage_filled = (incoming + already_had) / request_size,
				random_sort_order = random()
			}
			
			-- Use surface-based network key
			local network_key = network.network_key
			if not result[network_key] then
				result[network_key] = {item_request}
			else
				result[network_key][#result[network_key] + 1] = item_request
			end
			
			::next_item::
		end
		
		::continue::
	end
	
	for _, requesters in pairs(result) do
		sort(requesters, requester_sort_function)
	end
	
	return result
end

function logistics.providers()
	local result = {}

	-- First, add custom provider chests (existing logic)
	for _, provider_data in pairs(storage.providers) do
		local provider = provider_data.entity
		if not provider.valid then 
			-- logging.debug("Providers", "Provider chest invalid, skipping")
			goto continue 
		end
			
		if provider.to_be_deconstructed() then 
			-- logging.debug("Providers", "Provider chest marked for deconstruction, skipping")
			goto continue 
		end
		
		local network = beacon_assignment.spidertron_network(provider)
		if not network then
			logging.warn("Providers", "Provider chest at (" .. math.floor(provider.position.x) .. "," .. math.floor(provider.position.y) .. ") has no network/beacon assigned")
			rendering.draw_missing_roboport_icon(provider)
			goto continue
		end
		
		local inventory = provider.get_inventory(defines.inventory.chest)
		if not inventory then
			logging.warn("Providers", "Provider chest at (" .. math.floor(provider.position.x) .. "," .. math.floor(provider.position.y) .. ") has no inventory")
			goto continue
		end
		
		local contents = inventory.get_contents()
		local contains = {}
		
		-- Handle Factorio 2.0 ItemWithQualityCounts format
		if contents then
			for item_name, count_or_qualities in pairs(contents) do
				if type(count_or_qualities) == "number" then
					-- Old format: direct count
					contains[item_name] = count_or_qualities
				elseif type(count_or_qualities) == "table" then
					-- New format: ItemWithQualityCounts - sum all qualities
					local total = 0
					for quality, qty in pairs(count_or_qualities) do
						if type(qty) == "number" then
							total = total + qty
						end
					end
					contains[item_name] = total
				end
			end
		end
		
		if next(contains) == nil then 
			-- logging.debug("Providers", "Provider chest at (" .. math.floor(provider.position.x) .. "," .. math.floor(provider.position.y) .. ") is empty, skipping")
			goto continue 
		end
		
		-- Build item list string for logging
		local item_list = {}
		for item_name, count in pairs(contains) do
			table.insert(item_list, item_name .. " x" .. count)
		end
		-- logging.debug("Providers", "Provider chest at (" .. math.floor(provider.position.x) .. "," .. math.floor(provider.position.y) .. ") has items: " .. table.concat(item_list, ", "))
		provider_data.contains = contains
		
		-- Use surface-based network key
		local network_key = network.network_key
		if not result[network_key] then
			result[network_key] = {provider_data}
		else
			result[network_key][#result[network_key] + 1] = provider_data
		end
		
		::continue::
	end
	
	-- Now add robot logistic chests
	-- Robot chest types to scan for (buffer-chest placeholder for future)
	local robot_chest_types = {
		'storage-chest',
		'active-provider-chest',
		'passive-provider-chest'
		-- 'buffer-chest' -- placeholder for future
	}
	
	-- Scan all surfaces for robot chests and assign them to beacon networks
	for _, surface in pairs(game.surfaces) do
		for _, chest_type in ipairs(robot_chest_types) do
			local chests = surface.find_entities_filtered{
				name = chest_type,
				to_be_deconstructed = false
			}
			
			for _, chest in ipairs(chests) do
				-- Check if chest is in a logistic network
				local robot_network = chest.logistic_network
				if not robot_network then goto next_chest end
				
				-- Find nearest beacon for this chest
				local nearest_beacon = beacon_assignment.find_nearest_beacon(chest.surface, chest.position, chest.force, nil, "logistics_scan_provider")
				if not nearest_beacon then goto next_chest end
				
				-- Check if chest has items
				local inventory = chest.get_inventory(defines.inventory.chest)
				local contents = inventory.get_contents()
				if not contents or next(contents) == nil then goto next_chest end
				
				-- Get available items from the chest
				local contains = {}
				for item_name, count_or_qualities in pairs(contents) do
					local total = 0
					if type(count_or_qualities) == "number" then
						total = count_or_qualities
					elseif type(count_or_qualities) == "table" then
						for quality, qty in pairs(count_or_qualities) do
							if type(qty) == "number" then
								total = total + qty
							end
						end
					end
					if total > 0 then
						contains[item_name] = total
					end
				end
				
				if next(contains) == nil then goto next_chest end
				
				-- Create provider data for robot chest
				local robot_provider_data = {
					entity = chest,
					allocated_items = {},  -- Robot chests don't use allocation tracking
					pickup_count = 0,
					dropoff_count = 0,
					beacon_owner = nearest_beacon.unit_number,
					is_robot_chest = true,  -- Flag to identify robot chests
					robot_network = robot_network,
					contains = contains
				}
				
				-- Add to result by surface network
				local network = beacon_assignment.spidertron_network(chest)
				if network then
					local network_key = network.network_key
					if not result[network_key] then
						result[network_key] = {robot_provider_data}
					else
						result[network_key][#result[network_key] + 1] = robot_provider_data
					end
				end
				
				::next_chest::
			end
		end
	end
	
	return result
end

function logistics.assign_spider(spiders, requester_data, provider_data, can_provide)
	local provider = provider_data.entity
	if not provider.valid then 
		-- logging.warn("Assignment", "Provider entity is invalid")
		return false 
	end
	local item = requester_data.requested_item
	local requester = requester_data.entity
	
	-- logging.info("Assignment", "=== ASSIGNING SPIDER JOB ===")
	-- logging.info("Assignment", "Item: " .. item .. " x" .. can_provide)
	-- logging.info("Assignment", "Provider: " .. (provider_data.is_robot_chest and "ROBOT CHEST" or "CUSTOM CHEST") .. " at (" .. math.floor(provider.position.x) .. "," .. math.floor(provider.position.y) .. ")")
	-- logging.info("Assignment", "Requester: at (" .. math.floor(requester.position.x) .. "," .. math.floor(requester.position.y) .. ")")
	-- logging.info("Assignment", "Available spiders: " .. #spiders)
	
	local position = provider.position
	local x, y = position.x, position.y
	local spider
	local best_distance
	local spider_index
	local remove = table.remove
	
	-- Check if provider or requester is on water
	local surface = provider.surface
	local provider_tile = surface.get_tile(math.floor(provider.position.x), math.floor(provider.position.y))
	local requester_tile = surface.get_tile(math.floor(requester.position.x), math.floor(requester.position.y))
	
	local provider_is_water = false
	local requester_is_water = false
	
	if provider_tile and provider_tile.valid then
		local tile_name = provider_tile.name:lower()
		provider_is_water = tile_name:find("water") or tile_name:find("lava") or tile_name:find("lake") or tile_name:find("ammoniacal")
	end
	
	if requester_tile and requester_tile.valid then
		local tile_name = requester_tile.name:lower()
		requester_is_water = tile_name:find("water") or tile_name:find("lava") or tile_name:find("lake") or tile_name:find("ammoniacal")
	end
	
	-- Check if provider or requester is in dangerous territory (within 80 tiles of enemy nests)
	-- This matches the NEST_AVOIDANCE_DISTANCE used in pathing
	local DANGEROUS_TERRITORY_DISTANCE = 80
	local provider_near_nests = surface.find_entities_filtered{
		position = provider.position,
		radius = DANGEROUS_TERRITORY_DISTANCE,
		type = {"unit-spawner", "turret"},  -- Nests and worms
		force = "enemy"
	}
	local requester_near_nests = surface.find_entities_filtered{
		position = requester.position,
		radius = DANGEROUS_TERRITORY_DISTANCE,
		type = {"unit-spawner", "turret"},  -- Nests and worms
		force = "enemy"
	}
	
	if #provider_near_nests > 0 then
		-- logging.warn("Assignment", "Provider at (" .. math.floor(provider.position.x) .. "," .. math.floor(provider.position.y) .. ") is in dangerous territory (within " .. DANGEROUS_TERRITORY_DISTANCE .. " tiles of " .. #provider_near_nests .. " enemy nest(s)) - REJECTING assignment")
		return false
	end
	
	if #requester_near_nests > 0 then
		-- logging.warn("Assignment", "Requester at (" .. math.floor(requester.position.x) .. "," .. math.floor(requester.position.y) .. ") is in dangerous territory (within " .. DANGEROUS_TERRITORY_DISTANCE .. " tiles of " .. #requester_near_nests .. " enemy nest(s)) - REJECTING assignment")
		return false
	end
	
	-- logging.debug("Assignment", "Finding spider from " .. #spiders .. " available spiders")
	
	for i, canidate in ipairs(spiders) do
		-- Check if spider can insert item into trunk inventory
		local trunk = canidate.get_inventory(defines.inventory.spider_trunk)
		if trunk and trunk.can_insert({name = item, count = 1}) then
			-- Check if spider can traverse water (if destination is on water)
			local can_water = pathing.can_spider_traverse_water(canidate)
			
			-- DEBUG: Log spider's collision mask
			local prototype = canidate.prototype
			local collision_mask_str = "none"
			if prototype and prototype.collision_mask then
				local mask_parts = {}
				for _, layer in ipairs(prototype.collision_mask) do
					table.insert(mask_parts, tostring(layer))
				end
				collision_mask_str = table.concat(mask_parts, ", ")
			end
			-- logging.info("Assignment", "Spider " .. canidate.unit_number .. " (" .. canidate.name .. "): can_water=" .. tostring(can_water) .. ", collision_mask=[" .. collision_mask_str .. "]")
			
			-- Skip spiders that can't traverse water if destination is on water
			if (provider_is_water or requester_is_water) and not can_water then
				-- logging.warn("Assignment", "Spider " .. canidate.unit_number .. " skipped (can't traverse water, destination on water)")
				goto next_spider
			end
			
			local canidate_position = canidate.position
			local dist = utils.distance(x, y, canidate_position.x, canidate_position.y)
			
			if not spider or best_distance > dist then
				spider = canidate
				best_distance = dist
				spider_index = i
				-- logging.info("Assignment", "  -> Currently best spider (distance: " .. string.format("%.2f", dist) .. ")")
			end
		else
			-- logging.debug("Assignment", "Spider " .. canidate.unit_number .. " cannot insert " .. item .. " (inventory full)")
		end
		::next_spider::
	end
	if not spider then 
		-- logging.warn("Assignment", "No suitable spider found (inventory full or no spiders available)")
		return false 
	end
	
	-- logging.info("Assignment", "Selected spider " .. spider.unit_number .. " at distance " .. string.format("%.2f", best_distance) .. " from provider")
	-- logging.info("Assignment", "Spider current position: (" .. math.floor(spider.position.x) .. "," .. math.floor(spider.position.y) .. ")")
	
	local spider_data = storage.spiders[spider.unit_number]
	local amount = requester_data.real_amount
	
	if can_provide > amount then can_provide = amount end
	
	-- Only track allocated_items for custom provider chests
	-- Robot chests don't use allocation (robots handle their own allocation)
	if not provider_data.is_robot_chest then
		if not provider_data.allocated_items then
			provider_data.allocated_items = {}
		end
		provider_data.allocated_items[item] = (provider_data.allocated_items[item] or 0) + can_provide
		-- logging.debug("Assignment", "Allocated " .. can_provide .. " " .. item .. " from custom provider")
	end
	
	if not requester_data.incoming_items then
		requester_data.incoming_items = {}
	end
	requester_data.incoming_items[item] = (requester_data.incoming_items[item] or 0) + can_provide
	requester_data.real_amount = amount - can_provide
	
	-- Update spider data
	spider_data.status = constants.picking_up
	spider_data.requester_target = requester
	spider_data.provider_target = provider
	spider_data.payload_item = item
	spider_data.payload_item_count = can_provide
	
	-- logging.info("Assignment", "Spider " .. spider.unit_number .. " STATUS SET TO: picking_up")
	-- logging.info("Assignment", "Setting destination to provider at (" .. math.floor(provider.position.x) .. "," .. math.floor(provider.position.y) .. ")")
	
	-- Set destination using pathing
	local pathing_success = pathing.set_smart_destination(spider, provider.position, provider)
	
	if not pathing_success then
		-- Pathfinding request failed - cancel the assignment
		-- logging.warn("Assignment", "Pathfinding request failed, cancelling assignment for spider " .. spider.unit_number)
		-- Revert spider status
		spider_data.status = constants.idle
		spider_data.requester_target = nil
		spider_data.provider_target = nil
		spider_data.payload_item = nil
		spider_data.payload_item_count = 0
		-- Revert allocation
		if not provider_data.is_robot_chest and provider_data.allocated_items then
			provider_data.allocated_items[item] = (provider_data.allocated_items[item] or 0) - can_provide
			if provider_data.allocated_items[item] <= 0 then
				provider_data.allocated_items[item] = nil
			end
		end
		-- Revert incoming items
		requester_data.incoming_items[item] = (requester_data.incoming_items[item] or 0) - can_provide
		if requester_data.incoming_items[item] <= 0 then
			requester_data.incoming_items[item] = nil
		end
		-- Don't remove spider from list, let it be available for next attempt
		return false
	end
	
	-- logging.info("Assignment", "=== SPIDER JOB ASSIGNED SUCCESSFULLY ===")
	-- logging.info("Assignment", "Spider " .. spider.unit_number .. " will pick up " .. can_provide .. " " .. item .. " and deliver to requester")

	remove(spiders, spider_index)
	return true
end

-- Check if assignment should be delayed to batch more items
function logistics.should_delay_assignment(requester_data, provider_data, can_provide, real_amount, percentage_filled)
	-- Check priority/urgency - if requester is critical, never delay
	if percentage_filled < constants.critical_fill_threshold then
		return false  -- Urgent request, don't delay
	end
	
	-- Check availability ratio
	local availability_ratio = can_provide / real_amount
	if availability_ratio < constants.min_availability_ratio then
		-- Low availability, should delay
		-- But also check distance to see if we should wait longer
		local provider = provider_data.entity
		local requester = requester_data.entity
		local distance = utils.distance(provider.position, requester.position)
		
		-- Calculate minimum items needed based on distance
		-- Longer distances = need more items to justify the trip
		-- Scale applies to all distances, with base as a reference point
		local min_items_for_distance
		if distance > constants.distance_delay_base then
			-- For long distances: use full scaling from base
			local extra_distance = distance - constants.distance_delay_base
			min_items_for_distance = 1 + (extra_distance * constants.distance_delay_multiplier)
		else
			-- For short distances: use reduced scaling to ensure delays still happen
			-- At distance 0: need 1 item, at distance 200: need ~11 items
			min_items_for_distance = 1 + (distance * constants.distance_delay_multiplier * 0.5)
		end
		
		-- Delay if we have fewer items than the distance-based minimum
		if can_provide < min_items_for_distance then
			logging.debug("Assignment", "Delaying assignment: can_provide=" .. can_provide .. 
				", real_amount=" .. real_amount .. ", ratio=" .. string.format("%.2f", availability_ratio) ..
				", distance=" .. string.format("%.1f", distance) .. 
				", min_items=" .. string.format("%.1f", min_items_for_distance))
			return true
		end
	end
	
	return false  -- Don't delay
end

-- Assign spider with a multi-stop route
function logistics.assign_spider_with_route(spiders, route, route_type)
	if not route or #route == 0 then
		-- logging.warn("Assignment", "Cannot assign route: route is empty")
		return false
	end
	
	-- Find best spider for the route (closest to first stop)
	local first_stop = route[1]
	if not first_stop or not first_stop.entity or not first_stop.entity.valid then
		-- logging.warn("Assignment", "Cannot assign route: first stop is invalid")
		return false
	end
	
	local first_position = first_stop.entity.position
	local spider
	local best_distance
	local spider_index
	local remove = table.remove
	
	for i, candidate in ipairs(spiders) do
		-- Check if spider can handle the route (basic inventory check)
		local trunk = candidate.get_inventory(defines.inventory.spider_trunk)
		if trunk then
			local candidate_position = candidate.position
			local dist = utils.distance(first_position.x, first_position.y, candidate_position.x, candidate_position.y)
			
			if not spider or best_distance > dist then
				spider = candidate
				best_distance = dist
				spider_index = i
			end
		end
	end
	
	if not spider then
		-- logging.warn("Assignment", "No suitable spider found for route")
		return false
	end
	
	local spider_data = storage.spiders[spider.unit_number]
	
	-- Allocate items from providers and track incoming items for requesters
	for _, stop in ipairs(route) do
		if stop.type == "pickup" and stop.entity and stop.entity.valid then
			local provider_data = storage.providers[stop.entity.unit_number]
			if provider_data and not provider_data.is_robot_chest then
				if not provider_data.allocated_items then
					provider_data.allocated_items = {}
				end
				provider_data.allocated_items[stop.item] = (provider_data.allocated_items[stop.item] or 0) + stop.amount
			end
		elseif stop.type == "delivery" and stop.entity and stop.entity.valid then
			local requester_data = storage.requesters[stop.entity.unit_number]
			if requester_data then
				if not requester_data.incoming_items then
					requester_data.incoming_items = {}
				end
				if stop.item then
					-- Single item delivery
					requester_data.incoming_items[stop.item] = (requester_data.incoming_items[stop.item] or 0) + stop.amount
				elseif stop.items then
					-- Multi-item delivery
					for item, amount in pairs(stop.items) do
						requester_data.incoming_items[item] = (requester_data.incoming_items[item] or 0) + amount
					end
				end
			end
		end
	end
	
	-- Update spider data with route
	spider_data.status = constants.picking_up
	spider_data.route = route
	spider_data.route_type = route_type
	spider_data.current_route_index = 1
	
	-- Set initial destination to first stop
	local first_stop_entity = route[1].entity
	spider_data.provider_target = first_stop_entity  -- Will be updated as route progresses
	spider_data.requester_target = nil  -- Will be set when we reach delivery stops
	
	-- Set payload info from first pickup
	if route[1].type == "pickup" then
		spider_data.payload_item = route[1].item
		spider_data.payload_item_count = route[1].amount
		-- logging.info("RouteAssign", "Spider " .. spider.unit_number .. " assigned to " .. route_type .. " route")
		-- logging.info("RouteAssign", "  Route has " .. #route .. " stops")
		-- logging.info("RouteAssign", "  First stop: " .. route[1].type .. " at (" .. math.floor(first_stop_entity.position.x) .. "," .. math.floor(first_stop_entity.position.y) .. ")")
		-- logging.info("RouteAssign", "  First pickup: " .. route[1].item .. " x" .. route[1].amount)
	else
		-- logging.warn("RouteAssign", "First stop is not a pickup!")
	end
	
	-- Set destination using pathing
	-- logging.info("RouteAssign", "Setting destination to first stop...")
	local pathing_success = pathing.set_smart_destination(spider, first_stop_entity.position, first_stop_entity)
	
	if not pathing_success then
		-- logging.warn("Assignment", "Pathfinding request failed for route, cancelling assignment")
		-- Revert allocations
		for _, stop in ipairs(route) do
			if stop.type == "pickup" and stop.entity and stop.entity.valid then
				local provider_data = storage.providers[stop.entity.unit_number]
				if provider_data and not provider_data.is_robot_chest and provider_data.allocated_items then
					provider_data.allocated_items[stop.item] = (provider_data.allocated_items[stop.item] or 0) - stop.amount
					if provider_data.allocated_items[stop.item] <= 0 then
						provider_data.allocated_items[stop.item] = nil
					end
				end
			elseif stop.type == "delivery" and stop.entity and stop.entity.valid then
				local requester_data = storage.requesters[stop.entity.unit_number]
				if requester_data and requester_data.incoming_items then
					if stop.item then
						requester_data.incoming_items[stop.item] = (requester_data.incoming_items[stop.item] or 0) - stop.amount
						if requester_data.incoming_items[stop.item] <= 0 then
							requester_data.incoming_items[stop.item] = nil
						end
					elseif stop.items then
						for item, amount in pairs(stop.items) do
							requester_data.incoming_items[item] = (requester_data.incoming_items[item] or 0) - amount
							if requester_data.incoming_items[item] <= 0 then
								requester_data.incoming_items[item] = nil
							end
						end
					end
				end
			end
		end
		-- Revert spider status
		spider_data.status = constants.idle
		spider_data.route = nil
		spider_data.route_type = nil
		spider_data.current_route_index = nil
		spider_data.provider_target = nil
		spider_data.requester_target = nil
		spider_data.payload_item = nil
		spider_data.payload_item_count = 0
		return false
	end
	
	remove(spiders, spider_index)
	return true
end

return logistics


