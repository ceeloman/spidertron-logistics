-- Journey and status management for spiders

local constants = require('lib.constants')
local beacon_assignment = require('lib.beacon_assignment')
local pathing = require('lib.pathing')
local utils = require('lib.utils')
local logging = require('lib.logging')

local journey = {}

function journey.end_journey(unit_number, find_beacon)
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
		local current_network = beacon_assignment.spidertron_network(beacon_starting_point)
		if current_network and current_network.beacon and current_network.beacon.valid then
			pathing.set_smart_destination(spider, current_network.beacon.position, current_network.beacon)
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
				-- Spider has items remaining, try to dump them
				logging.warn("Journey", "Spider " .. unit_number .. " has items remaining after journey end, attempting to dump")
				journey.attempt_dump_items(unit_number)
				return  -- Don't set to idle, let dumping_items status handle it
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
	local network_beacon = network and network.beacon_unit_number
	
	for _, requester_data in pairs(storage.requesters) do
		local requester = requester_data.entity
		if not requester.valid then goto continue end
		if network_beacon and requester_data.beacon_owner ~= network_beacon then goto continue end
		
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

-- Attempt to dump items from spider into a storage chest
function journey.attempt_dump_items(unit_number)
	local spider_data = storage.spiders[unit_number]
	if not spider_data then return false end
	
	local spider = spider_data.entity
	if not spider or not spider.valid then return false end
	
	local trunk = spider.get_inventory(defines.inventory.spider_trunk)
	if not trunk then return false end
	
	local contents = trunk.get_contents()
	if not contents or next(contents) == nil then
		-- No items to dump, set to idle
		spider_data.status = constants.idle
		return true
	end
	
	-- Get spider's network
	local network = beacon_assignment.spidertron_network(spider)
	if not network then
		logging.warn("Dump", "Spider " .. unit_number .. " has no network, cannot find storage chest")
		return false
	end
	
	local surface = spider.surface
	local spider_pos = spider.position
	local network_beacon = network.beacon_unit_number
	
	-- Find nearest storage chest in the network
	local nearest_storage = nil
	local nearest_distance = nil
	
	-- Search for storage chests in the network
	-- Only search on the spider's surface and force for efficiency
	local storage_chests = surface.find_entities_filtered{
		name = 'storage-chest',
		force = spider.force,
		to_be_deconstructed = false
	}
	
	logging.info("Dump", "=== SEARCHING FOR STORAGE CHESTS ===")
	logging.info("Dump", "Spider at (" .. math.floor(spider_pos.x) .. "," .. math.floor(spider_pos.y) .. ") on surface: " .. surface.name .. ", force: " .. spider.force.name)
	logging.info("Dump", "Spider has " .. (contents and next(contents) and "items" or "no items") .. " in inventory")
	logging.info("Dump", "Found " .. #storage_chests .. " storage chests on surface")
	
	-- Log what items the spider has
	local item_list = {}
	for item_name, count in pairs(contents) do
		if item_name and type(item_name) == "string" and item_name ~= "" then
			local item_count = 0
			if type(count) == "number" then
				item_count = count
			elseif type(count) == "table" then
				for quality, qty in pairs(count) do
					if type(qty) == "number" then
						item_count = item_count + qty
					end
				end
			end
			if item_count > 0 then
				table.insert(item_list, item_name .. " x" .. item_count)
			end
		end
	end
	if #item_list > 0 then
		logging.info("Dump", "Spider inventory contents: " .. table.concat(item_list, ", "))
	end
	
	for i, chest in ipairs(storage_chests) do
		logging.info("Dump", "--- Checking storage chest #" .. i .. " at (" .. math.floor(chest.position.x) .. "," .. math.floor(chest.position.y) .. ") ---")
		
		-- Check if chest is on the same surface and force as the spider
		logging.info("Dump", "  Surface check: chest=" .. chest.surface.name .. " vs spider=" .. surface.name .. " (match: " .. tostring(chest.surface == spider.surface) .. ")")
		logging.info("Dump", "  Force check: chest=" .. chest.force.name .. " vs spider=" .. spider.force.name .. " (match: " .. tostring(chest.force == spider.force) .. ")")
		
		if chest.surface ~= spider.surface or chest.force ~= spider.force then
			logging.warn("Dump", "  REJECTED: Storage chest is on different surface/force")
			goto next_chest
		end
		logging.info("Dump", "  ✓ Same surface and force")
		
		-- Check if chest is in a logistic network (robot chests need this)
		local robot_network = chest.logistic_network
		if not robot_network then 
			logging.warn("Dump", "  REJECTED: Storage chest has no logistic network")
			goto next_chest 
		end
		logging.info("Dump", "  ✓ Chest is in logistic network")
		
		-- Get chest inventory
		local chest_inventory = chest.get_inventory(defines.inventory.chest)
		if not chest_inventory then 
			logging.warn("Dump", "  REJECTED: Cannot get chest inventory")
			goto next_chest 
		end
		logging.info("Dump", "  ✓ Chest inventory accessible")
		
		-- Check chest state
		local chest_contents = chest_inventory.get_contents()
		local chest_item_count = 0
		if chest_contents then
			for item, count in pairs(chest_contents) do
				if type(count) == "number" then
					chest_item_count = chest_item_count + count
				elseif type(count) == "table" then
					for quality, qty in pairs(count) do
						if type(qty) == "number" then
							chest_item_count = chest_item_count + qty
						end
					end
				end
			end
		end
		-- get_bar() returns total slots including bar, so subtract 1 for actual capacity
		local chest_capacity = (chest_inventory.get_bar() or 0) - 1
		if chest_capacity < 0 then chest_capacity = 0 end
		logging.info("Dump", "  Chest state: " .. chest_item_count .. " items, capacity: " .. chest_capacity .. " slots")
		
		-- Check if chest has item filters (storage chests can have filters)
		local has_filters = false
		if chest_inventory.is_filtered and chest_inventory.is_filtered() then
			has_filters = true
			logging.info("Dump", "  Chest has item filters set")
		else
			logging.info("Dump", "  Chest has no item filters")
		end
		
		-- Check if chest can accept items
		-- For storage chests, we use simpler checks instead of relying on can_insert
		-- which might have issues or check distance
		local can_accept = false
		local accepted_items = {}
		
		-- Check if chest has empty slots (not item count vs capacity)
		local empty_slots = chest_inventory.count_empty_stacks(false, false)  -- Don't include filtered or bar
		local has_space = empty_slots > 0
		logging.info("Dump", "  Chest has " .. empty_slots .. " empty slots out of " .. chest_capacity .. " total slots (" .. chest_item_count .. " items)")
		
		-- If chest is empty and has no filters, it can accept any item
		if chest_item_count == 0 and not has_filters and chest_capacity > 0 then
			logging.info("Dump", "  ✓ Chest is empty with no filters - can accept any item")
			can_accept = true
			-- List all items spider has
			for item_name, count in pairs(contents) do
				if item_name and type(item_name) == "string" and item_name ~= "" then
					local item_count = 0
					if type(count) == "number" and count > 0 then
						item_count = count
					elseif type(count) == "table" then
						for quality, qty in pairs(count) do
							if type(qty) == "number" and qty > 0 then
								item_count = item_count + qty
							end
						end
					end
					if item_count > 0 then
						table.insert(accepted_items, item_name)
					end
				end
			end
		elseif has_space and not has_filters then
			-- Chest has space and no filters - can accept items
			logging.info("Dump", "  ✓ Chest has space and no filters - can accept items")
			can_accept = true
			-- List all items spider has
			for item_name, count in pairs(contents) do
				if item_name and type(item_name) == "string" and item_name ~= "" then
					local item_count = 0
					if type(count) == "number" and count > 0 then
						item_count = count
					elseif type(count) == "table" then
						for quality, qty in pairs(count) do
							if type(qty) == "number" and qty > 0 then
								item_count = item_count + qty
							end
						end
					end
					if item_count > 0 then
						table.insert(accepted_items, item_name)
					end
				end
			end
		else
			-- Chest might have filters or be full - need to check each item
			logging.info("Dump", "  Checking individual items (chest has filters or is partially full)")
			for item_name, count in pairs(contents) do
				if not item_name or type(item_name) ~= "string" or item_name == "" then goto next_item end
				
				local item_count = 0
				if type(count) == "number" and count > 0 then
					item_count = count
				elseif type(count) == "table" then
					for quality, qty in pairs(count) do
						if type(qty) == "number" and qty > 0 then
							item_count = item_count + qty
						end
					end
				end
				
				if item_count > 0 then
					-- If chest has filters, check if this item matches a filter
					if has_filters then
						-- Check if item matches any filter slot
						local matches_filter = false
						for slot = 1, chest_capacity do
							local filter = chest_inventory.get_filter(slot)
							if filter and filter.name == item_name then
								matches_filter = true
								break
							end
						end
						if matches_filter then
							can_accept = true
							table.insert(accepted_items, item_name)
							logging.info("Dump", "    ✓ Item " .. item_name .. " matches a filter")
						else
							logging.warn("Dump", "    ✗ Item " .. item_name .. " does not match any filter")
						end
					elseif has_space then
						-- No filters and has space - can accept
						can_accept = true
						table.insert(accepted_items, item_name)
						logging.info("Dump", "    ✓ Item " .. item_name .. " can be accepted (no filters, has space)")
					end
				end
				::next_item::
			end
		end
		
		if not can_accept then 
			logging.warn("Dump", "  REJECTED: Storage chest cannot accept any items from spider")
			goto next_chest 
		end
		logging.info("Dump", "  ✓ Chest can accept items: " .. table.concat(accepted_items, ", "))
		
		-- Calculate distance
		local distance = utils.distance(spider_pos, chest.position)
		if not nearest_storage or distance < nearest_distance then
			nearest_storage = chest
			nearest_distance = distance
			logging.debug("Dump", "Found candidate storage chest at (" .. math.floor(chest.position.x) .. "," .. math.floor(chest.position.y) .. ") distance " .. string.format("%.2f", distance))
		end
		
		::next_chest::
	end
	
	if nearest_storage then
		-- Found a storage chest, set destination
		logging.info("Dump", "Spider " .. unit_number .. " dumping items to storage chest at (" .. math.floor(nearest_storage.position.x) .. "," .. math.floor(nearest_storage.position.y) .. ")")
		spider_data.status = constants.dumping_items
		spider_data.dump_target = nearest_storage
		local pathing_success = pathing.set_smart_destination(spider, nearest_storage.position, nearest_storage)
		if not pathing_success then
			logging.warn("Dump", "Pathfinding to storage chest failed for spider " .. unit_number)
			-- Will show flashing icon instead
			spider_data.dump_target = nil
			return false
		end
		return true
	else
		-- No storage chest found, will show flashing icon
		logging.warn("Dump", "No storage chest found for spider " .. unit_number .. " to dump items")
		spider_data.status = constants.dumping_items
		spider_data.dump_target = nil
		return false
	end
end

return journey

