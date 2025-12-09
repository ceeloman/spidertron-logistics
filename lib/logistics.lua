-- Core logistics functions: spiders, requesters, providers, and assignment

local constants = require('lib.constants')
local beacon_assignment = require('lib.beacon_assignment')
local rendering = require('lib.rendering')
local utils = require('lib.utils')
local pathing = require('lib.pathing')
local terrain = require('lib.terrain')
local logging = require('lib.logging')

local logistics = {}

-- Robot chest cache management
function logistics.update_robot_chest_cache(chest)
	if not chest or not chest.valid then return end
	
	-- Check if this is a robot chest type
	local robot_chest_types = {
		'storage-chest',
		'active-provider-chest',
		'passive-provider-chest'
	}
	
	local is_robot_chest = false
	for _, chest_type in ipairs(robot_chest_types) do
		if chest.name == chest_type then
			is_robot_chest = true
			break
		end
	end
	
	if not is_robot_chest then return end
	
	-- Initialize cache if needed
	if not storage.robot_chest_cache then
		storage.robot_chest_cache = {}
	end
	
	local chest_unit_number = chest.unit_number
	local robot_network = chest.logistic_network
	if not robot_network then
		-- Remove from cache if not in network
		storage.robot_chest_cache[chest_unit_number] = nil
		return
	end
	
	-- Find nearest beacon
	local nearest_beacon = beacon_assignment.find_nearest_beacon(chest.surface, chest.position, chest.force, nil, "robot_chest_cache_update")
	if not nearest_beacon then
		storage.robot_chest_cache[chest_unit_number] = nil
		return
	end
	
	-- Check if chest has items
	local inventory = chest.get_inventory(defines.inventory.chest)
	if not inventory then
		storage.robot_chest_cache[chest_unit_number] = nil
		return
	end
	
	local contents = inventory.get_contents()
	if not contents or next(contents) == nil then
		storage.robot_chest_cache[chest_unit_number] = nil
		return
	end
	
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
	
	if next(contains) == nil then
		storage.robot_chest_cache[chest_unit_number] = nil
		return
	end
	
	-- Update or create cache entry
	storage.robot_chest_cache[chest_unit_number] = {
		entity = chest,
		beacon_owner = nearest_beacon.unit_number,
		robot_network = robot_network,
		contains = contains,
		last_updated = game.tick
	}
end

function logistics.remove_robot_chest_from_cache(chest_unit_number)
	if storage.robot_chest_cache then
		storage.robot_chest_cache[chest_unit_number] = nil
	end
end

function logistics.spiders()
	local valid = {}
	local total_spiders = 0
	local inactive_count = 0
	local busy_count = 0
	local no_network_count = 0
	
	for unit_number, spider_data in pairs(storage.spiders) do
		total_spiders = total_spiders + 1
		local spider = spider_data.entity
		if not spider or not spider.valid then
			-- Clean up invalid spider reference immediately
			storage.spiders[unit_number] = nil
			goto valid
		end
		if not spider_data.active then 
			inactive_count = inactive_count + 1
			goto valid 
		end  -- Check logistics activation state
		if spider_data.status ~= constants.idle then 
			busy_count = busy_count + 1
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
	
	
	return valid
end

local function requester_sort_function(a, b)
	local a_filled = a.percentage_filled
	local b_filled = b.percentage_filled
	return a_filled == b_filled and a.random_sort_order < b.random_sort_order or a_filled < b_filled
end

function logistics.should_request_item(requester_data, item_name)
	if not requester_data.requested_items or not requester_data.requested_items[item_name] then
		return false
	end
	
	local item_data = requester_data.requested_items[item_name]
	
	-- Handle migration from old format (number) to new format (table)
	local requested_count
	local buffer_threshold
	if type(item_data) == "number" then
		-- Old format: migrate to new format
		requested_count = item_data
		buffer_threshold = 0.8
		requester_data.requested_items[item_name] = {
			count = requested_count,
			buffer_threshold = buffer_threshold,
			min_buffer_threshold = 0
		}
	else
		-- New format: extract count and buffer_threshold
		requested_count = item_data.count or 0
		buffer_threshold = item_data.buffer_threshold or 0.8
	end
	
	if requested_count <= 0 then return false end
	
	-- Get current amount in chest (use cache if available)
	local current_amount = 0
	local current_tick = game.tick
	if requester_data.cached_item_counts and requester_data.cache_tick then
		local cache_age = current_tick - requester_data.cache_tick
		if cache_age < constants.inventory_cache_ttl then
			current_amount = requester_data.cached_item_counts[item_name] or 0
		else
			-- Cache expired, refresh
			requester_data.cached_item_counts = nil
		end
	end
	
	if not requester_data.cached_item_counts then
		-- Refresh cache
		local inventory = requester_data.entity.get_inventory(defines.inventory.chest)
		if inventory then
			local contents = inventory.get_contents()
			requester_data.cached_item_counts = {}
			if contents then
				for item, count_or_qualities in pairs(contents) do
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
					requester_data.cached_item_counts[item] = total
				end
			end
			requester_data.cache_tick = current_tick
		end
		current_amount = requester_data.cached_item_counts[item_name] or 0
	end
	
	-- Get incoming items (items already assigned to spiders for delivery)
	local incoming = 0
	if requester_data.incoming_items and requester_data.incoming_items[item_name] then
		incoming = requester_data.incoming_items[item_name]
	end
	
	-- Calculate percentage filled (including incoming items)
	local total_amount = current_amount + incoming
	local percentage_filled = total_amount / requested_count
	
	-- Request if below buffer threshold
	return percentage_filled < buffer_threshold
end

function logistics.requesters()
	local result = {}
	local random = math.random
	local sort = table.sort
	
	for unit_number, requester_data in pairs(storage.requesters) do
		local requester = requester_data.entity
		if not requester or not requester.valid then
			-- Clean up invalid requester reference immediately
			storage.requesters[unit_number] = nil
			goto continue
		end
		if requester.to_be_deconstructed() then goto continue end
		
		local network = beacon_assignment.spidertron_network(requester)
		if network == nil then
			-- On-demand validation: if no beacon, try to assign one
			if not requester_data.beacon_owner then
				beacon_assignment.assign_chest_to_nearest_beacon(requester, nil, "on_demand_validation")
				network = beacon_assignment.spidertron_network(requester)
			end
			if network == nil then
				rendering.draw_missing_roboport_icon(requester)
				goto continue
			end
		end
		
		-- Migrate old format if needed
		if not requester_data.requested_items then
			requester_data.requested_items = {}
			if requester_data.requested_item then
				-- Migrate to new format
				local old_count = requester_data.request_size or 0
				requester_data.requested_items[requester_data.requested_item] = {
					count = old_count,
					buffer_threshold = 0.8,
					min_buffer_threshold = 0
				}
			end
		end
		
		-- Process each requested item
		for item_name, item_data in pairs(requester_data.requested_items) do
			-- Handle migration from old format (number) to new format (table)
			local requested_count
			local buffer_threshold
			local min_buffer_threshold
			if type(item_data) == "number" then
				-- Old format: migrate to new format
				requested_count = item_data
				buffer_threshold = 0.8
				min_buffer_threshold = 0
				requester_data.requested_items[item_name] = {
					count = requested_count,
					buffer_threshold = buffer_threshold,
					min_buffer_threshold = min_buffer_threshold
				}
			else
				-- New format: extract values
				requested_count = item_data.count or 0
				buffer_threshold = item_data.buffer_threshold or 0.8
				min_buffer_threshold = item_data.min_buffer_threshold or 0
			end
			
			if not item_name or item_name == '' or requested_count <= 0 then goto next_item end
			if not requester.can_insert(item_name) then goto next_item end
			
			-- Use should_request_item to check if item should be requested
			if not logistics.should_request_item(requester_data, item_name) then goto next_item end
			
			if not requester_data.incoming_items then
				requester_data.incoming_items = {}
			end
			local incoming = requester_data.incoming_items[item_name] or 0
			-- Use cached item count if available
			local already_had = 0
			if requester_data.cached_item_counts then
				already_had = requester_data.cached_item_counts[item_name] or 0
			else
				already_had = requester.get_item_count(item_name)
			end
			
			-- Calculate real_amount needed (request up to full requested_count)
			local real_amount = requested_count - incoming - already_had
			if real_amount <= 0 then goto next_item end
			
			-- Create a request entry for this item
			local item_request = {
				entity = requester,
				requester_data = requester_data,
				requested_item = item_name,
				request_size = requested_count,
				real_amount = real_amount,
				incoming = incoming,
				already_had = already_had,
				percentage_filled = (incoming + already_had) / requested_count,
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
	for unit_number, provider_data in pairs(storage.providers) do
		local provider = provider_data.entity
		if not provider or not provider.valid then
			-- Clean up invalid provider reference immediately
			storage.providers[unit_number] = nil
			goto continue
		end
			
		if provider.to_be_deconstructed() then 
			goto continue 
		end
		
		local network = beacon_assignment.spidertron_network(provider)
		if not network then
			-- On-demand validation: if no beacon, try to assign one
			if not provider_data.beacon_owner then
				beacon_assignment.assign_chest_to_nearest_beacon(provider, nil, "on_demand_validation")
				network = beacon_assignment.spidertron_network(provider)
			end
			if not network then
				logging.warn("Providers", "Provider chest at (" .. math.floor(provider.position.x) .. "," .. math.floor(provider.position.y) .. ") has no network/beacon assigned")
				rendering.draw_missing_roboport_icon(provider)
				goto continue
			end
		end
		
		local inventory = provider.get_inventory(defines.inventory.chest)
		if not inventory then
			logging.warn("Providers", "Provider chest at (" .. math.floor(provider.position.x) .. "," .. math.floor(provider.position.y) .. ") has no inventory")
			goto continue
		end
		
		-- Use cached inventory data if available and fresh
		local contains = nil
		local current_tick = game.tick
		if provider_data.cached_contents and provider_data.cache_tick then
			local cache_age = current_tick - provider_data.cache_tick
			if cache_age < constants.inventory_cache_ttl then
				contains = provider_data.cached_contents
			end
		end
		
		-- Refresh cache if needed
		if not contains then
			local contents = inventory.get_contents()
			contains = {}
			
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
			
			-- Update cache
			provider_data.cached_contents = contains
			provider_data.cache_tick = current_tick
		end
		
		if next(contains) == nil then 
			goto continue 
		end
		
		-- Build item list string for logging
		local item_list = {}
		for item_name, count in pairs(contains) do
			table.insert(item_list, item_name .. " x" .. count)
		end
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
	
	-- Now add robot logistic chests from cache
	-- Initialize robot chest cache if needed
	if not storage.robot_chest_cache then
		storage.robot_chest_cache = {}
	end
	
	-- Use cached robot chest data instead of scanning every cycle
	for chest_unit_number, cached_data in pairs(storage.robot_chest_cache) do
		local chest = cached_data.entity
		-- Validate cached chest still exists and is valid
		if not chest or not chest.valid then
			storage.robot_chest_cache[chest_unit_number] = nil
			goto next_cached_chest
		end
		
		-- Check if chest is in a logistic network
		local robot_network = chest.logistic_network
		if not robot_network then goto next_cached_chest end
		
		-- Use cached beacon owner or find new one
		local nearest_beacon = nil
		if cached_data.beacon_owner then
			local beacon_data = storage.beacons[cached_data.beacon_owner]
			if beacon_data and beacon_data.entity and beacon_data.entity.valid then
				nearest_beacon = beacon_data.entity
			end
		end
		
		if not nearest_beacon then
			nearest_beacon = beacon_assignment.find_nearest_beacon(chest.surface, chest.position, chest.force, nil, "logistics_scan_provider")
			if nearest_beacon then
				cached_data.beacon_owner = nearest_beacon.unit_number
			else
				goto next_cached_chest
			end
		end
		
		-- Use cached contains data (will be updated by inventory change events)
		local contains = cached_data.contains
		if not contains or next(contains) == nil then goto next_cached_chest end
		
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
		
		::next_cached_chest::
	end
	
	-- Now add requester chests with excess items (if allow_excess_provider is enabled)
	local requester_excess_count = 0
	for _, requester_data in pairs(storage.requesters) do
		local requester = requester_data.entity
		if not requester.valid then goto next_requester end
		if requester.to_be_deconstructed() then goto next_requester end
		
		local network = beacon_assignment.spidertron_network(requester)
		if not network then goto next_requester end
		
		-- Check if requester has requested items configured
		if not requester_data.requested_items then goto next_requester end
		
		local inventory = requester.get_inventory(defines.inventory.chest)
		if not inventory then goto next_requester end
		
		-- Build contains map with excess items only
		-- Iterate through requested_items instead of chest contents to ensure we use correct item names
		local excess_contains = {}
		for item_name, item_data in pairs(requester_data.requested_items) do
			-- Get the actual count in the chest for this item
			local total_count = inventory.get_item_count(item_name) or 0
			
			if total_count > 0 then
				-- Handle migration from old format
				local requested_count
				local allow_excess
				if type(item_data) == "number" then
					requested_count = item_data
					allow_excess = true  -- Default to true for old format
				else
					requested_count = item_data.count or 0
					allow_excess = item_data.allow_excess_provider ~= nil and item_data.allow_excess_provider or true
				end
				
				-- Only add excess items if allow_excess_provider is true
				if allow_excess and total_count > requested_count then
					local excess_amount = total_count - requested_count
					if excess_amount > 0 then
						excess_contains[item_name] = excess_amount
					end
				end
			end
		end
		
		-- Only add this requester as a provider if it has excess items
		if next(excess_contains) ~= nil then
			requester_excess_count = requester_excess_count + 1
			
			-- Create provider data for requester with excess items
			local requester_provider_data = {
				entity = requester,
				allocated_items = {},
				pickup_count = 0,
				dropoff_count = 0,
				beacon_owner = requester_data.beacon_owner,
				is_requester_excess = true,  -- Flag to identify requester excess providers
				contains = excess_contains
			}
			
			-- Add to result by surface network
			local network_key = network.network_key
			if not result[network_key] then
				result[network_key] = {requester_provider_data}
			else
				result[network_key][#result[network_key] + 1] = requester_provider_data
			end
		end
		
		::next_requester::
	end
	
	return result
end

function logistics.assign_spider(spiders, requester_data, provider_data, can_provide)
	local provider = provider_data.entity
	if not provider.valid then 
		return false 
	end
	local item = requester_data.requested_item
	local requester = requester_data.entity
	
	
	local position = provider.position
	local x, y = position.x, position.y
	local spider
	local best_distance
	local spider_index
	local remove = table.remove
	
	local surface = provider.surface
	
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
		return false
	end
	
	if #requester_near_nests > 0 then
		return false
	end
	
	
	for i, canidate in ipairs(spiders) do
		-- Check if spider can insert item into trunk inventory
		local trunk = canidate.get_inventory(defines.inventory.spider_trunk)
		if trunk and trunk.can_insert({name = item, count = 1}) then
			-- Check if spider can traverse water (legs with "player" collision layer can't traverse water)
			local can_water = pathing.can_spider_traverse_water(canidate)
			
			-- If spider can't traverse water, check if a path can be found
			-- Uses the same logic as Spidertron Enhancements mod
			if not can_water then
				local provider_pos = provider.position
				local requester_pos = requester.position
				
				-- Check if path can be found from provider to requester
				if not pathing.can_find_path(surface, provider_pos, requester_pos, canidate) then
					goto next_spider
				end
			end
			
			local canidate_position = canidate.position
			local dist = utils.distance(x, y, canidate_position.x, canidate_position.y)
			
			if not spider or best_distance > dist then
				spider = canidate
				best_distance = dist
				spider_index = i
			end
		else
		end
		::next_spider::
	end
	if not spider then 
		return false 
	end
	
	
	local spider_data = storage.spiders[spider.unit_number]
	local amount = requester_data.real_amount
	
	if can_provide > amount then can_provide = amount end
	
	-- Validate trunk capacity: ensure we don't assign more than the spider can carry
	local trunk = spider.get_inventory(defines.inventory.spider_trunk)
	if trunk then
		game.print("[ASSIGN DEBUG] Validating trunk capacity for spider " .. spider.unit_number .. ", item=" .. item .. ", can_provide=" .. can_provide)
		local already_has = spider.get_item_count(item) or 0
		local stack_size = utils.stack_size(item)
		
		-- Calculate available space in trunk
		local space_in_existing = 0
		for i = 1, #trunk do
			local stack = trunk[i]
			if stack and stack.valid_for_read and stack.name == item then
				space_in_existing = space_in_existing + (stack_size - stack.count)
			end
		end
		
		local empty_slots = trunk.count_empty_stacks(false, false)
		local space_in_empty = empty_slots * stack_size
		local max_can_carry = space_in_existing + space_in_empty
		
		game.print("[ASSIGN DEBUG] Trunk capacity check: already_has=" .. already_has .. ", stack_size=" .. stack_size .. ", space_in_existing=" .. space_in_existing .. ", empty_slots=" .. empty_slots .. ", max_can_carry=" .. max_can_carry)
		
		-- Limit can_provide to what the spider can actually carry
		if can_provide > max_can_carry then
			game.print("[ASSIGN DEBUG] Limiting can_provide from " .. can_provide .. " to " .. max_can_carry)
			can_provide = max_can_carry
		end
		
		-- If spider can't carry anything, don't assign
		if can_provide <= 0 then
			game.print("[ASSIGN DEBUG] Spider can't carry anything, rejecting assignment")
			return false
		end
		game.print("[ASSIGN DEBUG] Trunk capacity validation passed, final can_provide=" .. can_provide)
	end
	
	-- Only track allocated_items for custom provider chests and requester excess providers
	-- Robot chests don't use allocation (robots handle their own allocation)
	if not provider_data.is_robot_chest then
		if not provider_data.allocated_items then
			provider_data.allocated_items = {}
		end
		provider_data.allocated_items[item] = (provider_data.allocated_items[item] or 0) + can_provide
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
	
	
	-- Set destination using pathing
	local pathing_success = pathing.set_smart_destination(spider, provider.position, provider)
	
	if not pathing_success then
		-- Pathfinding request failed - cancel the assignment
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
	
	-- Check for additional items from the same requester (or nearby requesters) that are at 85%+ filled
	-- This allows spiders to pick up remaining amounts on the same trip
	logistics.add_nearby_items_to_delivery(spider, spider_data, requester, requester_data, item, can_provide, provider_data)
	

	remove(spiders, spider_index)
	return true
end

-- Helper function to check how much a provider can supply for an item
function logistics.can_provider_supply(provider_data, item_name)
	local provider = provider_data.entity
	if not provider or not provider.valid then return 0 end
	
	local item_count = 0
	local allocated = 0
	
	if provider_data.is_robot_chest then
		if provider_data.contains and provider_data.contains[item_name] then
			item_count = provider_data.contains[item_name]
		else
			item_count = provider.get_inventory(defines.inventory.chest).get_item_count(item_name) or 0
		end
		allocated = 0
	elseif provider_data.is_requester_excess then
		-- For requester excess providers, use the contains field which has the excess amount
		if provider_data.contains and provider_data.contains[item_name] then
			item_count = provider_data.contains[item_name]
		else
			item_count = 0
		end
		if provider_data.allocated_items then
			allocated = provider_data.allocated_items[item_name] or 0
		end
	else
		item_count = provider.get_inventory(defines.inventory.chest).get_item_count(item_name) or 0
		if provider_data.allocated_items then
			allocated = provider_data.allocated_items[item_name] or 0
		end
	end
	
	return math.max(0, item_count - allocated)
end

-- Find additional items from the same requester (or nearby) that are at 85%+ filled
-- and add them to the spider's delivery if there's space
function logistics.add_nearby_items_to_delivery(spider, spider_data, primary_requester, primary_requester_data, primary_item, primary_amount, provider_data)
	local trunk = spider.get_inventory(defines.inventory.spider_trunk)
	if not trunk then return end
	
	-- Check same requester for other items at 85%+ filled
	if primary_requester_data.requested_items then
		for item_name, item_data in pairs(primary_requester_data.requested_items) do
			-- Skip the primary item we're already delivering
			if item_name ~= primary_item then
				local requested_count = type(item_data) == "number" and item_data or (item_data.count or 0)
				if requested_count > 0 then
					local current_amount = primary_requester.get_inventory(defines.inventory.chest).get_item_count(item_name) or 0
					local incoming = (primary_requester_data.incoming_items and primary_requester_data.incoming_items[item_name]) or 0
					local percentage_filled = (current_amount + incoming) / requested_count
					
					-- If at 85%+ filled, add remaining amount to delivery
					if percentage_filled >= 0.85 then
						local remaining_needed = requested_count - current_amount - incoming
						if remaining_needed > 0 then
							-- Check if spider can carry this item
							if trunk.can_insert({name = item_name, count = 1}) then
								-- Try to find a provider for this item
								local network = beacon_assignment.spidertron_network(primary_requester)
								if network then
									local providers = logistics.providers()
									local providers_for_network = providers[network.network_key]
									if providers_for_network then
										-- Find best provider for this additional item (prefer same provider if it has the item)
										local best_provider_entity = nil
										local best_provider_data = nil
										local best_amount = 0
										
										-- First check if the primary provider has this item
										if provider_data.contains and provider_data.contains[item_name] then
											local can_provide = logistics.can_provider_supply(provider_data, item_name)
											if can_provide > 0 then
												best_provider_entity = provider_data.entity
												best_provider_data = provider_data
												best_amount = math.min(can_provide, remaining_needed)
											end
										end
										
										-- If primary provider doesn't have it, find another provider
										if not best_provider_entity then
											for _, provider_data_check in ipairs(providers_for_network) do
												local provider_entity = provider_data_check.entity
												if provider_entity and provider_entity.valid then
													local can_provide = logistics.can_provider_supply(provider_data_check, item_name)
													if can_provide > 0 then
														local distance = utils.distance(provider_entity.position, primary_requester.position)
														-- Prefer providers close to the primary requester
														if not best_provider_entity or distance < utils.distance(best_provider_entity.position, primary_requester.position) then
															best_provider_entity = provider_entity
															best_provider_data = provider_data_check
															best_amount = math.min(can_provide, remaining_needed)
														end
													end
												end
											end
										end
										
										if best_provider_entity and best_provider_data and best_amount > 0 then
											-- Mark as incoming
											if not primary_requester_data.incoming_items then
												primary_requester_data.incoming_items = {}
											end
											primary_requester_data.incoming_items[item_name] = (primary_requester_data.incoming_items[item_name] or 0) + best_amount
											
											-- Allocate from provider
											if not best_provider_data.is_robot_chest then
												if not best_provider_data.allocated_items then
													best_provider_data.allocated_items = {}
												end
												best_provider_data.allocated_items[item_name] = (best_provider_data.allocated_items[item_name] or 0) + best_amount
											end
											
											-- Store additional items in spider_data (we'll need to handle multiple items in journey.lua)
											if not spider_data.additional_items then
												spider_data.additional_items = {}
											end
											table.insert(spider_data.additional_items, {
												item = item_name,
												amount = best_amount,
												requester = primary_requester,
												provider = best_provider_entity
											})
										end
									end
								end
							end
						end
					end
				end
			end
		end
	end
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
		return false
	end
	
	-- Find best spider for the route (closest to first stop)
	local first_stop = route[1]
	if not first_stop or not first_stop.entity or not first_stop.entity.valid then
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
	else
	end
	
	-- Set destination using pathing
	local pathing_success = pathing.set_smart_destination(spider, first_stop_entity.position, first_stop_entity)
	
	if not pathing_success then
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


