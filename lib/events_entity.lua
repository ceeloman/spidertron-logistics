-- Entity lifecycle event handlers for spidertron logistics

local constants = require('lib.constants')
local beacon_assignment = require('lib.beacon_assignment')
local journey = require('lib.journey')
local registration = require('lib.registration')
local gui = require('lib.gui')

local events_entity = {}

local function handle_entity_removal(event)
	local entity = event.entity or event.created_entity
	local unit_number = event.unit_number or (entity and entity.unit_number)
	
	if not unit_number then return end
	
	-- Note: Robot chest cache removal was removed in version 3.0.2
	-- Robot chests are no longer supported as providers
	
	if storage.spiders[unit_number] then
		journey.end_journey(unit_number, false)
		storage.spiders[unit_number] = nil
	elseif storage.requesters[unit_number] then
		beacon_assignment.unassign_chest_from_beacon(unit_number)
		storage.requesters[unit_number] = nil
	elseif storage.providers[unit_number] then
		beacon_assignment.unassign_chest_from_beacon(unit_number)
		storage.providers[unit_number] = nil
	elseif storage.beacons[unit_number] then
		-- Reassign all chests from this beacon to other beacons
		local beacon_data = storage.beacons[unit_number]
		if beacon_data and beacon_data.assigned_chests then
			-- Make a copy of the list since we'll be modifying it
			local chests_to_reassign = {}
			for _, chest_unit_number in ipairs(beacon_data.assigned_chests) do
				table.insert(chests_to_reassign, chest_unit_number)
			end
			
			-- CRITICAL: Remove beacon from storage BEFORE reassignment
			-- This ensures find_nearest_beacon won't find it in storage validation
			storage.beacons[unit_number] = nil
			
			-- First, unassign all chests from this beacon
			for _, chest_unit_number in ipairs(chests_to_reassign) do
				beacon_assignment.unassign_chest_from_beacon(chest_unit_number)
			end
			
			-- Then, reassign each chest to the nearest available beacon (excluding the destroyed one)
			-- Use assign_chest_to_nearest_beacon which properly handles both providers and requesters
			for _, chest_unit_number in ipairs(chests_to_reassign) do
				local chest = nil
				local chest_type = "unknown"
				
				if storage.providers[chest_unit_number] then
					chest = storage.providers[chest_unit_number].entity
					chest_type = "provider"
				elseif storage.requesters[chest_unit_number] then
					chest = storage.requesters[chest_unit_number].entity
					chest_type = "requester"
				else
				end
				
				if chest and chest.valid then
					-- Use assign_chest_to_nearest_beacon which properly handles both providers and requesters
					-- Pass the destroyed beacon's unit_number to exclude it from the search
					beacon_assignment.assign_chest_to_nearest_beacon(chest, unit_number, "beacon_removal")
					
					-- Assignment handled by assign_chest_to_nearest_beacon
				end
			end
		else
			-- No chests to reassign, just clean up
			storage.beacons[unit_number] = nil
		end
	end
end

local function built(event)
	local entity = event.created_entity or event.entity

	if entity.type == 'spider-vehicle' and entity.prototype.order ~= 'z[programmable]' then
		registration.register_spider(entity)
	elseif entity.name == constants.spidertron_requester_chest then
		-- Merge tags from event and entity (entity.tags for copy-paste, event.tags for blueprints)
		local tags = event.tags or {}
		if entity.tags then
			-- Merge entity tags into event tags (entity tags take precedence)
			for key, value in pairs(entity.tags) do
				tags[key] = value
			end
			if entity.tags.requested_items then
				local item_count = 0
				if type(entity.tags.requested_items) == "table" then
					if entity.tags.requested_items[1] then
						-- List format
						item_count = #entity.tags.requested_items
					else
						-- Table format
						for _ in pairs(entity.tags.requested_items) do
							item_count = item_count + 1
						end
					end
				end
			end
		end
		if tags.requested_items then
			local item_count = 0
			if type(tags.requested_items) == "table" then
				if tags.requested_items[1] then
					-- List format
					item_count = #tags.requested_items
				else
					-- Table format
					for _ in pairs(tags.requested_items) do
						item_count = item_count + 1
					end
				end
			end
		end
		registration.register_requester(entity, tags)
	elseif entity.name == constants.spidertron_provider_chest then
		registration.register_provider(entity)
	elseif entity.name == constants.spidertron_logistic_beacon then
		registration.register_beacon(entity)
	end
	-- Note: Robot chest detection on build was removed in version 3.0.2
	-- Robot chests (storage-chest, active-provider-chest, passive-provider-chest) are no longer supported as providers
end

function events_entity.register()
	script.on_event(defines.events.on_entity_settings_pasted, function(event)
		local source, destination = event.source, event.destination
		
		if destination.name == constants.spidertron_requester_chest then
			local destination_data = storage.requesters[destination.unit_number]
			if not destination_data then
				return -- Destination not registered yet
			end
			
			if source.name == constants.spidertron_requester_chest then 
				local source_data = storage.requesters[source.unit_number]
				if source_data then
					-- Copy requested_items
					if not destination_data.requested_items then
						destination_data.requested_items = {}
					end
					if source_data.requested_items then
						-- Deep copy (handle both number and table formats)
						destination_data.requested_items = {}
						for item, item_data in pairs(source_data.requested_items) do
							if type(item_data) == "table" then
								-- Table format: {count = ..., buffer_threshold = ..., allow_excess_provider = ...}
								destination_data.requested_items[item] = {
									count = item_data.count or 0,
									buffer_threshold = item_data.buffer_threshold or 0.8,
									allow_excess_provider = item_data.allow_excess_provider ~= nil and item_data.allow_excess_provider or true
								}
							else
								-- Number format: just a count
								destination_data.requested_items[item] = item_data
							end
						end
					elseif source_data.requested_item then
						-- Migrate old format
						destination_data.requested_items[source_data.requested_item] = {
							count = source_data.request_size or 0,
							buffer_threshold = 0.8,
							allow_excess_provider = true
						}
					end
				end
			else
				destination_data.requested_items = {}
			end
			
			-- Update entity tags so requests are copied when entity is copied
			if destination_data.entity and destination_data.entity.valid then
				registration.update_requester_entity_tags(destination_data.entity, destination_data.requested_items)
			end
			
			-- Update GUI if it's open for this requester
			local gui_data = storage.requester_guis[event.player_index]
			if gui_data and gui_data.last_opened_requester == destination_data then
				-- Only update GUI if it's actually open and valid
				if gui_data.item_slots and gui_data.item_slots[1] and gui_data.item_slots[1].flow and gui_data.item_slots[1].flow.valid then
					gui.update_requester_gui(gui_data, destination_data)
				end
			end
		elseif destination.type == 'spider-vehicle' and destination.prototype.order ~= 'z[programmable]' then
			local spider = destination
			
			local unit_number = spider.unit_number
			if storage.spiders[unit_number] then
				journey.end_journey(unit_number, false)
				storage.spiders[unit_number] = nil
			end
			
			registration.register_spider(spider)
		end
	end)

	script.on_event(defines.events.on_entity_died, handle_entity_removal)
	script.on_event(defines.events.on_pre_player_mined_item, handle_entity_removal)
	script.on_event(defines.events.on_robot_pre_mined, handle_entity_removal)
	if defines.events.script_raised_destroy then
		script.on_event(defines.events.script_raised_destroy, handle_entity_removal)
	end

	script.on_event(defines.events.on_built_entity, built)
	script.on_event(defines.events.on_robot_built_entity, built)
	if defines.events.script_raised_built then
		script.on_event(defines.events.script_raised_built, built)
	end
	if defines.events.script_raised_revive then
		script.on_event(defines.events.script_raised_revive, built)
	end
end

return events_entity

