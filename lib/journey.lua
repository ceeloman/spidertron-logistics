-- Journey and status management for spiders

local constants = require('lib.constants')
local beacon_assignment = require('lib.beacon_assignment')

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
		if requester_data then
			requester_data.incoming_items[item] = requester_data.incoming_items[item] - item_count
		end
	end
	
	if spider_data.status == constants.picking_up then
		local provider = spider_data.provider_target
		if provider and provider.valid then
			beacon_starting_point = provider
			
			local allocated_items = storage.providers[provider.unit_number].allocated_items
			allocated_items[item] = allocated_items[item] - item_count
			if allocated_items[item] == 0 then allocated_items[item] = nil end
		end
	end
	
	if find_beacon and spider.valid and spider.get_driver() == nil then
		local current_network = beacon_assignment.spidertron_network(beacon_starting_point)
		if current_network and current_network.beacon and current_network.beacon.valid then
			spider.add_autopilot_destination(current_network.beacon.position)
		end
	end
	
	spider_data.provider_target = nil
	spider_data.requester_target = nil
	spider_data.payload_item = nil
	spider_data.payload_item_count = 0
	spider_data.status = constants.idle
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
	spider.add_autopilot_destination(requester.position)
end

return journey

