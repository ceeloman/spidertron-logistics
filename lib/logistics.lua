-- Core logistics functions: spiders, requesters, providers, and assignment

local constants = require('lib.constants')
local beacon_assignment = require('lib.beacon_assignment')
local rendering = require('lib.rendering')
local utils = require('lib.utils')

local logistics = {}

function logistics.spiders()
	local valid = {}
	
	for _, spider_data in pairs(storage.spiders) do
		local spider = spider_data.entity
		if not spider.valid then goto valid end
		if not spider_data.active then goto valid end  -- Check logistics activation state
		if spider_data.status ~= constants.idle then goto valid end
		if spider.get_driver() ~= nil then goto valid end
		
		local network = beacon_assignment.spidertron_network(spider)
		if network == nil then
			rendering.draw_missing_roboport_icon(spider, {0, -1.75})
			goto valid
		end
		
		-- Only active spiders participate in logistics
		if spider_data.active then
			local network_key = network.beacon_unit_number
			if not valid[network_key] then
				valid[network_key] = {}
			end
			valid[network_key][#valid[network_key] + 1] = spider
		end
		::valid::
	end
	
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
			
			-- Use beacon_unit_number as network key
			local network_key = network.beacon_unit_number
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
		if not provider.valid then goto continue end
			
		if provider.to_be_deconstructed() then goto continue end
		
		local network = beacon_assignment.spidertron_network(provider)
		if not network then
			rendering.draw_missing_roboport_icon(provider)
			goto continue
		end
		
		local inventory = provider.get_inventory(defines.inventory.chest)
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
		
		if next(contains) == nil then goto continue end
		provider_data.contains = contains
		
		-- Use beacon_unit_number as network key
		local network_key = network.beacon_unit_number
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
				local nearest_beacon = beacon_assignment.find_nearest_beacon(chest.surface, chest.position, chest.force)
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
				
				-- Add to result by beacon network
				local network_key = nearest_beacon.unit_number
				if not result[network_key] then
					result[network_key] = {robot_provider_data}
				else
					result[network_key][#result[network_key] + 1] = robot_provider_data
				end
				
				::next_chest::
			end
		end
	end
	
	return result
end

function logistics.assign_spider(spiders, requester_data, provider_data, can_provide)
	local provider = provider_data.entity
	if not provider.valid then return false end
	local item = requester_data.requested_item
	
	local position = provider.position
	local x, y = position.x, position.y
	local spider
	local best_distance
	local spider_index
	local remove = table.remove
	
	for i, canidate in ipairs(spiders) do
		-- Check if spider can insert item into trunk inventory
		local trunk = canidate.get_inventory(defines.inventory.spider_trunk)
		if trunk and trunk.can_insert({name = item, count = 1}) then
			local canidate_position = canidate.position
			local dist = utils.distance(x, y, canidate_position.x, canidate_position.y)
			
			if not spider or best_distance > dist then
				spider = canidate
				best_distance = dist
				spider_index = i
			end
		end
	end
	if not spider then return false end
	
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
	end
	
	if not requester_data.incoming_items then
		requester_data.incoming_items = {}
	end
	requester_data.incoming_items[item] = (requester_data.incoming_items[item] or 0) + can_provide
	requester_data.real_amount = amount - can_provide
	spider_data.status = constants.picking_up
	spider_data.requester_target = requester_data.entity
	spider_data.provider_target = provider
	spider_data.payload_item = item
	spider_data.payload_item_count = can_provide
	spider.add_autopilot_destination(provider.position)

	remove(spiders, spider_index)
	return true
end

return logistics

