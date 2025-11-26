-- Journey and status management for spiders

local constants = require('lib.constants')
local beacon_assignment = require('lib.beacon_assignment')
local pathing = require('lib.pathing')
local utils = require('lib.utils')
local logging = require('lib.logging')

local journey = {}

-- Advance to next stop in route
function journey.advance_route(unit_number)
	local spider_data = storage.spiders[unit_number]
	if not spider_data or not spider_data.route then
		return false
	end
	
	local spider = spider_data.entity
	if not spider or not spider.valid then
		return false
	end
	
	local route = spider_data.route
	local current_index = spider_data.current_route_index or 1
	
	-- Mark current stop as completed
	if route[current_index] then
		route[current_index].completed = true
	end
	
	-- Move to next stop
	current_index = current_index + 1
	spider_data.current_route_index = current_index
	
	-- Check if route is complete
	if current_index > #route then
		-- logging.info("Journey", "Route complete for spider " .. unit_number)
		-- Clear route and end journey
		spider_data.route = nil
		spider_data.route_type = nil
		spider_data.current_route_index = nil
		journey.end_journey(unit_number, true)
		return false
	end
	
	-- Get next stop
	local next_stop = route[current_index]
	if not next_stop or not next_stop.entity or not next_stop.entity.valid then
		-- logging.warn("Journey", "Next stop in route is invalid, ending route")
		spider_data.route = nil
		spider_data.route_type = nil
		spider_data.current_route_index = nil
		journey.end_journey(unit_number, true)
		return false
	end
	
	-- Update spider data for next stop
	if next_stop.type == "pickup" then
		spider_data.status = constants.picking_up
		spider_data.provider_target = next_stop.entity
		spider_data.requester_target = nil
		spider_data.payload_item = next_stop.item
		spider_data.payload_item_count = next_stop.amount
	elseif next_stop.type == "delivery" then
		spider_data.status = constants.dropping_off
		spider_data.requester_target = next_stop.entity
		spider_data.provider_target = nil
		-- Keep payload_item and payload_item_count from previous pickups
		-- For multi-item deliveries, we'll handle all items
	end
	
	-- Set destination to next stop
	local pathing_success = pathing.set_smart_destination(spider, next_stop.entity.position, next_stop.entity)
	if not pathing_success then
		-- logging.warn("Journey", "Pathfinding to next route stop failed, ending route")
		spider_data.route = nil
		spider_data.route_type = nil
		spider_data.current_route_index = nil
		journey.end_journey(unit_number, true)
		return false
	end
	
	-- logging.info("Journey", "Spider " .. unit_number .. " advancing to route stop " .. current_index .. "/" .. #route .. " (" .. next_stop.type .. ")")
	return true
end

function journey.end_journey(unit_number, find_beacon)
	local spider_data = storage.spiders[unit_number]
	if not spider_data then return end
	if spider_data.status == constants.idle then return end
	local spider = spider_data.entity
	
	-- If spider has a route, clear it
	if spider_data.route then
		spider_data.route = nil
		spider_data.route_type = nil
		spider_data.current_route_index = nil
	end
	
	local item = spider_data.payload_item
	local item_count = spider_data.payload_item_count
	
	local beacon_starting_point = spider
	
	local requester = spider_data.requester_target
	if requester and requester.valid then
		beacon_starting_point = requester
		
		local requester_data = storage.requesters[requester.unit_number]
		if requester_data and item then
			if not requester_data.incoming_items then
				requester_data.incoming_items = {}
			end
			requester_data.incoming_items[item] = (requester_data.incoming_items[item] or 0) - item_count
			if requester_data.incoming_items[item] <= 0 then
				requester_data.incoming_items[item] = nil
			end
		end
	end
	
	if spider_data.status == constants.picking_up then
		local provider = spider_data.provider_target
		if provider and provider.valid then
			beacon_starting_point = provider
			
			local provider_data = storage.providers[provider.unit_number]
			if provider_data and provider_data.allocated_items and item then
				local allocated_items = provider_data.allocated_items
				allocated_items[item] = (allocated_items[item] or 0) - item_count
				if allocated_items[item] <= 0 then allocated_items[item] = nil end
			end
		end
	end
	local spider_data = storage.spiders[unit_number]
	if not spider_data then return end
	if spider_data.status == constants.idle then return end
	local spider = spider_data.entity
	
	local item = spider_data.payload_item
	local item_count = spider_data.payload_item_count
	
	local beacon_starting_point = spider
	
	local requester = spider_data.requester_target
	if requester and requester.valid then
		beacon_starting_point = requester
		
		local requester_data = storage.requesters[requester.unit_number]
		if requester_data and item then
			if not requester_data.incoming_items then
				requester_data.incoming_items = {}
			end
			requester_data.incoming_items[item] = (requester_data.incoming_items[item] or 0) - item_count
			if requester_data.incoming_items[item] <= 0 then
				requester_data.incoming_items[item] = nil
			end
		end
	end
	
	if spider_data.status == constants.picking_up then
		local provider = spider_data.provider_target
		if provider and provider.valid then
			beacon_starting_point = provider
			
			local provider_data = storage.providers[provider.unit_number]
			if provider_data and provider_data.allocated_items and item then
				local allocated_items = provider_data.allocated_items
				allocated_items[item] = (allocated_items[item] or 0) - item_count
				if allocated_items[item] <= 0 then allocated_items[item] = nil end
			end
		end
	end
	
	if find_beacon and spider.valid and spider.get_driver() == nil then
		-- Try to find beacon with highest pickup count (most activity) within reasonable distance
		-- This helps distribute spiders to the most active beacons
		local active_beacon = beacon_assignment.find_beacon_with_highest_pickup_count(
			spider.surface, 
			beacon_starting_point.position, 
			spider.force,
			1000  -- Search within 1000 tiles
		)
		
		if active_beacon and active_beacon.valid then
			pathing.set_smart_destination(spider, active_beacon.position, active_beacon)
		else
			-- Fallback to nearest beacon if no active beacon found
		local current_network = beacon_assignment.spidertron_network(beacon_starting_point)
		if current_network and current_network.beacon and current_network.beacon.valid then
			pathing.set_smart_destination(spider, current_network.beacon.position, current_network.beacon)
		else
			-- Fallback: find any beacon on the surface
			local nearest_beacon = beacon_assignment.find_nearest_beacon(spider.surface, beacon_starting_point.position, spider.force, nil, "end_journey_fallback")
			if nearest_beacon then
				pathing.set_smart_destination(spider, nearest_beacon.position, nearest_beacon)
			end
		end
		end
	end
	
	spider_data.provider_target = nil
	spider_data.requester_target = nil
	spider_data.payload_item = nil
	spider_data.payload_item_count = 0
	
	-- Check if spider still has items in inventory after failed delivery
	if spider.valid then
		local trunk = spider.get_inventory(defines.inventory.spider_trunk)
		if trunk then
			local contents = trunk.get_contents()
			if contents and next(contents) ~= nil then
				-- Check if spider has any non-requested items or excess items
				local logistic_requests = utils.get_spider_logistic_requests(spider)
				local has_dumpable = false
				
				for item_name, item_data in pairs(contents) do
					-- Handle new format where item_data is a table with name/count/quality
					local actual_item_name = item_name
					local item_count = 0
					
					if type(item_data) == "table" and item_data.name then
						-- New format: {name = "item", count = 50, quality = "normal"}
						actual_item_name = item_data.name
						item_count = item_data.count or 0
					elseif type(item_data) == "number" then
						-- Old format: item_name => count
						item_count = item_data
					elseif type(item_data) == "table" then
						-- Quality format: {normal = 50, rare = 10}
						for quality, qty in pairs(item_data) do
							if type(qty) == "number" then
								item_count = item_count + qty
							end
						end
					end
					
					if actual_item_name and type(actual_item_name) == "string" and actual_item_name ~= "" and item_count > 0 then
						local requested = logistic_requests[actual_item_name] or 0
						local total = spider.get_item_count(actual_item_name)
						
						if requested == 0 or total > requested then
							has_dumpable = true
							break
						end
					end
				end
				
				if has_dumpable then
					journey.attempt_dump_items(unit_number)
					return  -- Don't set to idle
				end
			end
		end
	end
	
	spider_data.status = constants.idle
	-- Clear retry counters
	spider_data.pickup_retry_count = nil
	spider_data.dropoff_retry_count = nil
end

function journey.deposit_already_had(spider_data)
	local spider = spider_data.entity
	if not spider.valid then return end

	local contains = spider.get_inventory(defines.inventory.spider_trunk).get_contents()
	if next(contains) == nil then return end
	
	local network = beacon_assignment.spidertron_network(spider)
	if not network then return end
	
	local requesters = {}
	local requester_items = {}
	local i = 1
	
	-- Network is now surface-wide, so filter by surface instead of beacon
	for _, requester_data in pairs(storage.requesters) do
		local requester = requester_data.entity
		if not requester.valid then goto continue end
		-- Only consider requesters on the same surface as the spider
		if requester.surface ~= spider.surface or requester.force ~= spider.force then goto continue end
		
		-- Migrate old format if needed
		if not requester_data.requested_items then
			requester_data.requested_items = {}
			if requester_data.requested_item then
				requester_data.requested_items[requester_data.requested_item] = requester_data.request_size or 0
			end
		end
		
		-- Check all requested items
		for item, request_size in pairs(requester_data.requested_items) do
			if item and item ~= '' and request_size > 0 and contains[item] and requester.can_insert(item) then
				local incoming = requester_data.incoming_items[item] or 0
				local already_had = requester.get_item_count(item)
				if already_had + incoming < request_size then
					requesters[i] = requester
					requester_items[requester.unit_number] = item
					i = i + 1
					goto found_item
				end
			end
		end
		::found_item::
		::continue::
	end
	
	if #requesters == 0 then return end
	
	local position = spider.position
	local requester = spider.surface.get_closest({position.x, position.y - 2}, requesters)
	local requester_data = storage.requesters[requester.unit_number]
	local item = requester_items[requester.unit_number]
	
	if not requester_data.incoming_items then
		requester_data.incoming_items = {}
	end
	local incoming = requester_data.incoming_items[item] or 0
	local request_size = requester_data.requested_items[item] or 0
	local already_had = request_size - requester.get_item_count(item) - incoming
	local can_provide = spider.get_item_count(item)
	if can_provide > already_had then can_provide = already_had end
	
	requester_data.incoming_items[item] = incoming + can_provide
		
	spider_data.status = constants.dropping_off
	spider_data.requester_target = requester_data.entity
	spider_data.payload_item = item
	spider_data.payload_item_count = can_provide
	pathing.set_smart_destination(spider, requester.position, requester_data.entity)
end

-- Check if spider has items that need to be dumped
function journey.has_dumpable_items(unit_number)
	local spider_data = storage.spiders[unit_number]
	if not spider_data then 
		return false 
	end
	
	local spider = spider_data.entity
	if not spider or not spider.valid then 
		return false 
	end
	
	local trunk = spider.get_inventory(defines.inventory.spider_trunk)
	if not trunk then 
		return false 
	end
	
	local contents = trunk.get_contents()
	if not contents or next(contents) == nil then
		return false
	end
	
	-- Get spider's logistic requests to avoid dumping requested items
	local logistic_requests = utils.get_spider_logistic_requests(spider)
	
	-- Check if spider has any non-requested items or excess items
	for item_name, item_data in pairs(contents) do
		-- Handle new format where item_data is a table with name/count/quality
		local actual_item_name = item_name
		local item_count = 0
		
		if type(item_data) == "table" and item_data.name then
			-- New format: {name = "item", count = 50, quality = "normal"}
			actual_item_name = item_data.name
			item_count = item_data.count or 0
		elseif type(item_data) == "number" then
			-- Old format: item_name => count
			item_count = item_data
		elseif type(item_data) == "table" then
			-- Quality format: {normal = 50, rare = 10}
			for quality, qty in pairs(item_data) do
				if type(qty) == "number" then
					item_count = item_count + qty
				end
			end
		end
		
		if actual_item_name and type(actual_item_name) == "string" and actual_item_name ~= "" and item_count > 0 then
			local requested = logistic_requests[actual_item_name] or 0
			local total = spider.get_item_count(actual_item_name)
			
			if requested == 0 or total > requested then
				return true
			end
		end
	end
	
	return false
end

-- Attempt to dump items from spider into a storage chest
function journey.attempt_dump_items(unit_number)
	local spider_data = storage.spiders[unit_number]
	if not spider_data then 
		return false 
	end
	
	local spider = spider_data.entity
	if not spider or not spider.valid then 
		return false 
	end
	
	local trunk = spider.get_inventory(defines.inventory.spider_trunk)
	if not trunk then 
		return false 
	end
	
	local contents = trunk.get_contents()
	if not contents or next(contents) == nil then
		spider_data.status = constants.idle
		return true
	end
	
	-- Get spider's network
	local network = beacon_assignment.spidertron_network(spider)
	if not network then
		return false
	end
	
	local surface = spider.surface
	local spider_pos = spider.position
	
	-- Find nearest storage chest on the same surface
	local nearest_storage = nil
	local nearest_distance = nil
	
	-- Search for storage chests in the network
	local storage_chests = surface.find_entities_filtered{
		name = 'storage-chest',
		force = spider.force,
		to_be_deconstructed = false
	}
	
	-- Get logistic requests once
	local logistic_requests = utils.get_spider_logistic_requests(spider)
	
	for i, chest in ipairs(storage_chests) do
		if chest.surface ~= spider.surface or chest.force ~= spider.force then
			goto next_chest
		end
		
		local robot_network = chest.logistic_network
		if not robot_network then 
			goto next_chest 
		end
		
		local chest_inventory = chest.get_inventory(defines.inventory.chest)
		if not chest_inventory then 
			goto next_chest 
		end
		
		-- Check if chest has empty slots
		local empty_slots = chest_inventory.count_empty_stacks(false, false)
		local has_space = empty_slots > 0
		
		if not has_space then
			goto next_chest
		end
		
		-- Check if chest has filters
		local has_filters = chest_inventory.is_filtered and chest_inventory.is_filtered()
		
		-- Check if we can dump any items to this chest
		local can_accept = false
		
		for item_name, item_data in pairs(contents) do
			-- Handle new format where item_data is a table
			local actual_item_name = item_name
			local item_count = 0
			
			if type(item_data) == "table" and item_data.name then
				actual_item_name = item_data.name
				item_count = item_data.count or 0
			elseif type(item_data) == "number" then
				item_count = item_data
			elseif type(item_data) == "table" then
				for quality, qty in pairs(item_data) do
					if type(qty) == "number" then
						item_count = item_count + qty
					end
				end
			end
			
			if item_count > 0 and actual_item_name and actual_item_name ~= "" then
				-- Check if this item should be dumped
				local requested = logistic_requests[actual_item_name] or 0
				local total = spider.get_item_count(actual_item_name)
				
				local should_dump = (requested == 0 or total > requested)
				
				if should_dump then
					-- Check if chest accepts this item
					if has_filters then
						-- Check filter match
						local matches_filter = false
						for slot = 1, #chest_inventory do
							local filter = chest_inventory.get_filter(slot)
							if filter and filter.name == actual_item_name then
								matches_filter = true
								break
							end
						end
						if matches_filter then
							can_accept = true
							break
						end
					else
						-- No filters, accepts anything
						can_accept = true
						break
					end
				end
			end
		end
		
		if not can_accept then 
			goto next_chest 
		end
		
		-- Calculate distance
		local distance = utils.distance(spider_pos, chest.position)
		if not nearest_storage or distance < nearest_distance then
			nearest_storage = chest
			nearest_distance = distance
		end
		
		::next_chest::
	end
	
	if nearest_storage then
		spider_data.status = constants.dumping_items
		spider_data.dump_target = nearest_storage
		local pathing_success = pathing.set_smart_destination(spider, nearest_storage.position, nearest_storage)
		if not pathing_success then
			spider_data.dump_target = nil
			return false
		end
		return true
	else
		spider_data.status = constants.dumping_items
		spider_data.dump_target = nil
		return false
	end
end

return journey

