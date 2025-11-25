-- Registration functions for entities

local constants = require('lib.constants')
local beacon_assignment = require('lib.beacon_assignment')

local registration = {}

function registration.register_provider(provider)
	storage.providers[provider.unit_number] = {
		entity = provider,
		allocated_items = {},
		pickup_count = 0,
		dropoff_count = 0,
		beacon_owner = nil
	}
	script.register_on_object_destroyed(provider)
	-- Assign to nearest beacon
	beacon_assignment.assign_chest_to_nearest_beacon(provider, nil, "register_provider")
end

function registration.register_requester(requester, tags)
	-- Migrate old format to new format if needed
	local requested_items = {}
	if tags and tags.requested_items then
		-- New format: multiple items (from blueprint or tags)
		if type(tags.requested_items) == "table" then
			-- Convert from list format to table format
			for _, item_data in ipairs(tags.requested_items) do
				if item_data.name and item_data.count then
					requested_items[item_data.name] = item_data.count
				end
			end
		else
			-- Already in table format
			requested_items = tags.requested_items
		end
	elseif tags and tags.requested_item then
		-- Old format: single item
		requested_items[tags.requested_item] = tags.request_size or 0
	end
	
	storage.requesters[requester.unit_number] = {
		entity = requester,
		requested_items = requested_items,  -- New: {[item_name] = count, ...}
		incoming_items = {},
		pickup_count = 0,
		dropoff_count = 0,
		beacon_owner = nil
	}
	script.register_on_object_destroyed(requester)
	-- Assign to nearest beacon
	beacon_assignment.assign_chest_to_nearest_beacon(requester, nil, "register_requester")
end

function registration.register_spider(spider)
	storage.spiders[spider.unit_number] = {
		entity = spider,
		status = constants.idle,
		active = false,  -- Spiders spawn inactive by default
		requester_target = nil,
		provider_target = nil,
		payload_item = nil,
		payload_item_count = 0,
		-- Stuck detection
		last_position = nil,
		last_position_tick = nil,
		stuck_count = 0
	}
	script.register_on_object_destroyed(spider)
end

function registration.register_beacon(beacon)
	storage.beacons[beacon.unit_number] = {
		entity = beacon,
		assigned_chests = {}
	}
	script.register_on_object_destroyed(beacon)
	-- Assign all existing chests on surface to this beacon
	beacon_assignment.assign_all_chests_to_beacon(beacon)
end

return registration

