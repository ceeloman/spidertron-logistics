-- Journey and status management for spiders

local constants = require('lib.constants')
local beacon_assignment = require('lib.beacon_assignment')
local pathing = require('lib.pathing')
local utils = require('lib.utils')
local logging = require('lib.logging')
local logistics = require('lib.logistics')

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
		spider_data.route = nil
		spider_data.route_type = nil
		spider_data.current_route_index = nil
		journey.end_journey(unit_number, true)
		return false
	end
	
	return true
end

-- Save current task state for resumption
function journey.save_task_state(unit_number)
	local spider_data = storage.spiders[unit_number]
	if not spider_data then return false end
	if spider_data.status == constants.idle then return false end
	
	-- Only save if we have an active task (not dumping)
	if spider_data.status == constants.dumping_items then
		return false
	end
	
	-- Save route with unit numbers instead of entity references
	local saved_route = nil
	if spider_data.route then
		saved_route = {}
		for i, stop in ipairs(spider_data.route) do
			saved_route[i] = {
				type = stop.type,
				entity_unit_number = stop.entity and stop.entity.unit_number or nil,
				position = stop.position,  -- Save position as fallback
				item = stop.item,
				amount = stop.amount,
				index = stop.index,
				completed = stop.completed
			}
		end
	end
	
	-- Save task state
	spider_data.saved_task = {
		status = spider_data.status,
		provider_target_unit_number = spider_data.provider_target and spider_data.provider_target.unit_number or nil,
		requester_target_unit_number = spider_data.requester_target and spider_data.requester_target.unit_number or nil,
		payload_item = spider_data.payload_item,
		payload_item_count = spider_data.payload_item_count,
		route = saved_route,  -- Save route with unit numbers
		route_type = spider_data.route_type,
		current_route_index = spider_data.current_route_index,
		additional_items = spider_data.additional_items  -- Save additional items for multi-item deliveries
	}
	
	return true
end

-- Resume a saved task
function journey.resume_task(unit_number)
	local spider_data = storage.spiders[unit_number]
	if not spider_data then return false end
	if not spider_data.saved_task then return false end
	if spider_data.status ~= constants.idle then return false end
	
	local spider = spider_data.entity
	if not spider or not spider.valid then
		spider_data.saved_task = nil
		return false
	end
	
	local saved = spider_data.saved_task
	
	-- Restore entity references from unit numbers
	local provider = nil
	if saved.provider_target_unit_number then
		provider = spider.surface.find_entity_by_unit_number(saved.provider_target_unit_number)
		if not provider or not provider.valid then
			spider_data.saved_task = nil
			return false
		end
	end
	
	local requester = nil
	if saved.requester_target_unit_number then
		requester = spider.surface.find_entity_by_unit_number(saved.requester_target_unit_number)
		if not requester or not requester.valid then
			spider_data.saved_task = nil
			return false
		end
	end
	
	-- Restore route entities from unit numbers
	local restored_route = nil
	if saved.route then
		restored_route = {}
		for i, stop_data in ipairs(saved.route) do
			local entity = nil
			if stop_data.entity_unit_number then
				entity = spider.surface.find_entity_by_unit_number(stop_data.entity_unit_number)
			end
			if entity and entity.valid then
				restored_route[i] = {
					type = stop_data.type,
					entity = entity,
					position = entity.position,
					item = stop_data.item,
					amount = stop_data.amount,
					index = stop_data.index,
					completed = stop_data.completed
				}
			else
				-- Entity invalid, can't restore route
				spider_data.saved_task = nil
				return false
			end
		end
	end
	
	-- Restore task state
	spider_data.status = saved.status
	spider_data.provider_target = provider
	spider_data.requester_target = requester
	spider_data.payload_item = saved.payload_item
	spider_data.payload_item_count = saved.payload_item_count
	spider_data.route = restored_route
	spider_data.route_type = saved.route_type
	spider_data.current_route_index = saved.current_route_index
	spider_data.additional_items = saved.additional_items
	
	-- Clear saved task
	spider_data.saved_task = nil
	
	-- Restore allocations if needed
	if saved.status == constants.picking_up and provider and saved.payload_item and saved.payload_item_count then
		local provider_data = storage.providers[provider.unit_number]
		if provider_data and not provider_data.is_robot_chest then
			if not provider_data.allocated_items then
				provider_data.allocated_items = {}
			end
			provider_data.allocated_items[saved.payload_item] = (provider_data.allocated_items[saved.payload_item] or 0) + saved.payload_item_count
		end
	end
	
	if saved.status == constants.dropping_off and requester and saved.payload_item and saved.payload_item_count then
		local requester_data = storage.requesters[requester.unit_number]
		if requester_data then
			if not requester_data.incoming_items then
				requester_data.incoming_items = {}
			end
			requester_data.incoming_items[saved.payload_item] = (requester_data.incoming_items[saved.payload_item] or 0) + saved.payload_item_count
		end
	end
	
	-- Resume pathfinding
	local target = nil
	if saved.status == constants.picking_up and provider then
		target = provider
	elseif saved.status == constants.dropping_off and requester then
		target = requester
	elseif saved.route and saved.current_route_index then
		-- Resume route from current index
		local next_stop = saved.route[saved.current_route_index]
		if next_stop and next_stop.entity and next_stop.entity.valid then
			target = next_stop.entity
		end
	end
	
	if target then
		local pathing_success = pathing.set_smart_destination(spider, target.position, target)
		if not pathing_success then
			-- Pathfinding failed, clear task
			journey.end_journey(unit_number, true)
			return false
		end
		return true
	end
	
	-- No valid target, clear task
	journey.end_journey(unit_number, true)
	return false
end

function journey.end_journey(unit_number, find_beacon, save_for_resume)
	local spider_data = storage.spiders[unit_number]
	if not spider_data then return end
	if spider_data.status == constants.idle then return end
	local spider = spider_data.entity
	
	-- Save task state if requested (for resumption after interruption)
	if save_for_resume then
		journey.save_task_state(unit_number)
	end
	
	-- If spider has a route, clear it (unless we're saving for resume)
	if spider_data.route and not save_for_resume then
		spider_data.route = nil
		spider_data.route_type = nil
		spider_data.current_route_index = nil
	end
	
	local item = spider_data.payload_item
	local item_count = spider_data.payload_item_count
	
	local beacon_starting_point = spider
	
	-- Only clear allocations if not saving for resume
	if not save_for_resume then
		local requester = spider_data.requester_target
		if requester and requester.valid then
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
				local provider_data = storage.providers[provider.unit_number]
				if provider_data and provider_data.allocated_items and item then
					local allocated_items = provider_data.allocated_items
					allocated_items[item] = (allocated_items[item] or 0) - item_count
					if allocated_items[item] <= 0 then allocated_items[item] = nil end
				end
			end
		end
	end
	
	-- Determine beacon starting point for pathfinding
	local beacon_starting_point = spider
	local requester = spider_data.requester_target
	if requester and requester.valid then
		beacon_starting_point = requester
	end
	
	if spider_data.status == constants.picking_up then
		local provider = spider_data.provider_target
		if provider and provider.valid then
			beacon_starting_point = provider
		end
	end
	
	local beacon_starting_point = spider
	local requester = spider_data.requester_target
	if requester and requester.valid then
		beacon_starting_point = requester
	end
	
	if spider_data.status == constants.picking_up then
		local provider = spider_data.provider_target
		if provider and provider.valid then
			beacon_starting_point = provider
		end
	end
	
	if find_beacon and spider.valid then
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
	
	-- Only clear targets if not saving for resume
	if not save_for_resume then
		spider_data.provider_target = nil
		spider_data.requester_target = nil
		spider_data.payload_item = nil
		spider_data.payload_item_count = 0
	end
	
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
	
	-- Set to idle (needed for resumption check)
	spider_data.status = constants.idle
	-- Clear retry counters
	spider_data.pickup_retry_count = nil
	spider_data.dropoff_retry_count = nil
	-- Note: saved_task is preserved if save_for_resume was true, allowing resumption
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
				-- Migrate to new format
				local old_count = requester_data.request_size or 0
				requester_data.requested_items[requester_data.requested_item] = {
					count = old_count,
					buffer_threshold = 0.8
				}
			end
		end
		
		-- Check all requested items
		for item_name, item_data in pairs(requester_data.requested_items) do
			-- Handle migration from old format (number) to new format (table)
			local requested_count
			if type(item_data) == "number" then
				-- Old format: migrate to new format
				requested_count = item_data
				requester_data.requested_items[item_name] = {
					count = requested_count,
					buffer_threshold = 0.8
				}
			else
				-- New format: extract count
				requested_count = item_data.count or 0
			end
			
			if item_name and item_name ~= '' and requested_count > 0 and contains[item_name] and requester.can_insert(item_name) then
				-- Use should_request_item to check if item should be requested
				if logistics.should_request_item(requester_data, item_name) then
					requesters[i] = requester
					requester_items[requester.unit_number] = item_name
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
	
	-- Handle new format for requested_items
	local item_data = requester_data.requested_items[item]
	local requested_count
	if type(item_data) == "number" then
		-- Old format: migrate to new format
		requested_count = item_data
		requester_data.requested_items[item] = {
			count = requested_count,
			buffer_threshold = 0.2
		}
	else
		-- New format: extract count
		requested_count = item_data and item_data.count or 0
	end
	
	local current_amount = requester.get_item_count(item)
	local already_had = requested_count - current_amount - incoming
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
	
	-- Check if any storage chests exist at all
	if not storage_chests or #storage_chests == 0 then
		-- No storage chests available - print message and return without setting dumping_items status
		return false
	end
	
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
		-- No suitable storage chest found (all are full or filtered) - print message and return without setting dumping_items status
		return false
	end
end

return journey

