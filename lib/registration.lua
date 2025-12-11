-- Registration functions for entities

local constants = require('lib.constants')
local beacon_assignment = require('lib.beacon_assignment')
local logging = require('lib.logging')

local registration = {}

-- Helper function to update entity tags with requested_items
-- NOTE: entity.tags only works for entity ghosts, not regular entities
-- For regular entities, we rely on storage-based copying via pending_clones
-- This function is kept for blueprint support (ghosts can have tags)
function registration.update_requester_entity_tags(requester, requested_items)
	if not requester or not requester.valid then
		return
	end
	
	-- Only try to set tags if this is an entity ghost (tags only work for ghosts)
	-- Regular entities don't support tags, so we skip them
	if requester.type == "entity-ghost" then
		local success, err = pcall(function()
			-- Initialize tags if they don't exist
			if requester.tags == nil then
				requester.tags = {}
			end
			
			if requested_items and next(requested_items) then
				-- Convert to list format for storage in entity tags (same format as blueprints)
				local items_list = {}
				for item_name, item_data in pairs(requested_items) do
					if item_name and item_name ~= '' then
						local count
						if type(item_data) == "table" then
							-- New format: {count = ..., buffer_threshold = ..., allow_excess_provider = ...}
							count = item_data.count or 0
						else
							-- Old format: just a number
							count = item_data or 0
						end
						if count > 0 then
							table.insert(items_list, {name = item_name, count = count})
						end
					end
				end
				-- Set the requested_items tag
				requester.tags.requested_items = items_list
			else
				-- Clear tags if no items requested
				if requester.tags then
					requester.tags.requested_items = nil
				end
			end
		end)
		
		-- Silently fail if tags aren't supported
		if not success then
			-- Entity ghost doesn't support tags, which is fine
			return
		end
	end
	-- For regular entities, tags are not supported - we rely on storage-based copying
end

function registration.register_provider(provider)
	-- logging.info("Registration", "Registering provider chest " .. provider.unit_number .. " at (" .. math.floor(provider.position.x) .. "," .. math.floor(provider.position.y) .. ")")
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
	local provider_data = storage.providers[provider.unit_number]
	if provider_data and provider_data.beacon_owner then
		-- logging.info("Registration", "Provider chest " .. provider.unit_number .. " assigned to beacon " .. provider_data.beacon_owner)
	else
		-- logging.warn("Registration", "Provider chest " .. provider.unit_number .. " NOT assigned to any beacon")
	end
end

function registration.register_requester(requester, tags)
	-- Use storage data directly - check if entity already has data in storage
	-- (This happens when copying via shift-right-click/shift-left-click which uses on_entity_settings_pasted)
	local requested_items = {}
	local existing_data = storage.requesters[requester.unit_number]
	if existing_data and existing_data.requested_items then
		-- Entity already has data in storage (from copy-paste), use it
		requested_items = existing_data.requested_items
	else
		-- No existing data, check tags (from blueprints or entity ghosts)
		if tags then
			if tags.requested_items then
				-- New format: multiple items (from blueprint or tags)
				if type(tags.requested_items) == "table" then
					-- Check if it's a list format (from blueprint/entity tags) or table format
					if tags.requested_items[1] then
						-- List format: [{name = "iron-plate", count = 50}, ...]
						for _, item_data in ipairs(tags.requested_items) do
							if item_data.name and item_data.count then
								-- Convert to table format with defaults
								requested_items[item_data.name] = {
									count = item_data.count,
									buffer_threshold = item_data.buffer_threshold or 0.8,
									allow_excess_provider = item_data.allow_excess_provider ~= nil and item_data.allow_excess_provider or true
								}
							end
						end
					else
						-- Already in table format: {[item_name] = count or {count = ..., ...}, ...}
						for item_name, item_data in pairs(tags.requested_items) do
							if type(item_data) == "table" then
								-- Already in full table format
								requested_items[item_name] = item_data
							else
								-- Number format, convert to table with defaults
								requested_items[item_name] = {
									count = item_data or 0,
									buffer_threshold = 0.8,
									allow_excess_provider = true
								}
							end
						end
					end
				end
			elseif tags.requested_item then
				-- Old format: single item
				requested_items[tags.requested_item] = {
					count = tags.request_size or 0,
					buffer_threshold = 0.8,
					allow_excess_provider = true
				}
			end
		end
	end
	
	-- Only create new storage entry if it doesn't exist (preserve existing data from copy-paste)
	local existing_data = storage.requesters[requester.unit_number]
	if not existing_data then
		storage.requesters[requester.unit_number] = {
			entity = requester,
			requested_items = requested_items,
			incoming_items = {},
			pickup_count = 0,
			dropoff_count = 0,
			beacon_owner = nil
		}
	else
		-- Update existing data with new requested_items if we got them from tags
		if next(requested_items) then
			existing_data.requested_items = requested_items
		end
		-- Ensure entity reference is up to date
		existing_data.entity = requester
	end
	
	-- Log request registration
	if next(requested_items) then
		local request_list = {}
		for item_name, item_data in pairs(requested_items) do
			local count = type(item_data) == "number" and item_data or (item_data.count or 0)
			if count > 0 then
				table.insert(request_list, item_name .. " x" .. count)
			end
		end
		-- if #request_list > 0 then
		-- 	game.print("[REQUEST REGISTERED] Tick " .. game.tick .. ": Requester " .. requester.unit_number .. 
		-- 		" at (" .. math.floor(requester.position.x) .. "," .. math.floor(requester.position.y) .. 
		-- 		") - REGISTERED requests: " .. table.concat(request_list, ", "))
		-- end
	end
	
	-- Save requested_items to entity tags for blueprint support (ghosts can have tags)
	registration.update_requester_entity_tags(requester, requested_items)
	
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

