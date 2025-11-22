-- Beacon-chest assignment system

local constants = require('lib.constants')
local utils = require('lib.utils')

local beacon_assignment = {}

function beacon_assignment.find_nearest_beacon(surface, position, force)
	local beacons = surface.find_entities_filtered{
		name = constants.spidertron_logistic_beacon,
		force = force,
		to_be_deconstructed = false
	}
	
	if #beacons == 0 then return nil end
	
	local nearest = beacons[1]
	local nearest_distance = utils.distance(position, nearest.position)
	
	for i = 2, #beacons do
		local beacon = beacons[i]
		local dist = utils.distance(position, beacon.position)
		if dist < nearest_distance then
			nearest = beacon
			nearest_distance = dist
		end
	end
	
	return nearest
end

function beacon_assignment.assign_chest_to_beacon(chest_unit_number, beacon_unit_number)
	storage.beacon_assignments[chest_unit_number] = beacon_unit_number
	
	local beacon_data = storage.beacons[beacon_unit_number]
	if beacon_data and beacon_data.assigned_chests then
		-- Check if already in list
		local found = false
		for _, unit_num in ipairs(beacon_data.assigned_chests) do
			if unit_num == chest_unit_number then
				found = true
				break
			end
		end
		if not found then
			table.insert(beacon_data.assigned_chests, chest_unit_number)
		end
	end
end

function beacon_assignment.unassign_chest_from_beacon(chest_unit_number)
	local beacon_unit_number = storage.beacon_assignments[chest_unit_number]
	if beacon_unit_number then
		local beacon_data = storage.beacons[beacon_unit_number]
		if beacon_data and beacon_data.assigned_chests then
			for i = #beacon_data.assigned_chests, 1, -1 do
				if beacon_data.assigned_chests[i] == chest_unit_number then
					table.remove(beacon_data.assigned_chests, i)
					break
				end
			end
		end
		storage.beacon_assignments[chest_unit_number] = nil
	end
end

function beacon_assignment.assign_all_chests_to_beacon(beacon)
	local surface = beacon.surface
	local force = beacon.force
	local beacon_unit_number = beacon.unit_number
	
	-- Find all provider and requester chests on the surface
	local providers = surface.find_entities_filtered{
		name = constants.spidertron_provider_chest,
		force = force,
		to_be_deconstructed = false
	}
	
	local requesters = surface.find_entities_filtered{
		name = constants.spidertron_requester_chest,
		force = force,
		to_be_deconstructed = false
	}
	
	-- Assign all chests to this beacon (unlimited range)
	for _, provider in ipairs(providers) do
		local provider_data = storage.providers[provider.unit_number]
		if provider_data then
			beacon_assignment.unassign_chest_from_beacon(provider.unit_number)
			beacon_assignment.assign_chest_to_beacon(provider.unit_number, beacon_unit_number)
			provider_data.beacon_owner = beacon_unit_number
		end
	end
	
	for _, requester in ipairs(requesters) do
		local requester_data = storage.requesters[requester.unit_number]
		if requester_data then
			beacon_assignment.unassign_chest_from_beacon(requester.unit_number)
			beacon_assignment.assign_chest_to_beacon(requester.unit_number, beacon_unit_number)
			requester_data.beacon_owner = beacon_unit_number
		end
	end
end

function beacon_assignment.assign_chest_to_nearest_beacon(chest)
	local surface = chest.surface
	local force = chest.force
	local position = chest.position
	
	local nearest_beacon = beacon_assignment.find_nearest_beacon(surface, position, force)
	if nearest_beacon then
		local chest_unit_number = chest.unit_number
		beacon_assignment.unassign_chest_from_beacon(chest_unit_number)
		beacon_assignment.assign_chest_to_beacon(chest_unit_number, nearest_beacon.unit_number)
		
		-- Update chest data
		if storage.providers[chest_unit_number] then
			storage.providers[chest_unit_number].beacon_owner = nearest_beacon.unit_number
		elseif storage.requesters[chest_unit_number] then
			storage.requesters[chest_unit_number].beacon_owner = nearest_beacon.unit_number
		end
	end
end

function beacon_assignment.spidertron_network(entity)
	-- Get the beacon owner for this entity
	local beacon_owner = nil
	
	if entity.name == constants.spidertron_provider_chest then
		local provider_data = storage.providers[entity.unit_number]
		if provider_data then
			beacon_owner = provider_data.beacon_owner
			-- If no beacon owner, try to assign to nearest beacon
			if not beacon_owner then
				beacon_assignment.assign_chest_to_nearest_beacon(entity)
				beacon_owner = provider_data.beacon_owner
			end
		end
	elseif entity.name == constants.spidertron_requester_chest then
		local requester_data = storage.requesters[entity.unit_number]
		if requester_data then
			beacon_owner = requester_data.beacon_owner
			-- If no beacon owner, try to assign to nearest beacon
			if not beacon_owner then
				beacon_assignment.assign_chest_to_nearest_beacon(entity)
				beacon_owner = requester_data.beacon_owner
			end
		end
	elseif entity.name == constants.spidertron_logistic_beacon then
		beacon_owner = entity.unit_number
	else
		-- For spiders, find nearest beacon
		local nearest_beacon = beacon_assignment.find_nearest_beacon(entity.surface, entity.position, entity.force)
		if nearest_beacon then
			beacon_owner = nearest_beacon.unit_number
		end
	end
	
	if not beacon_owner then return nil end
	
	-- Return a network representation based on beacon
	local beacon_data = storage.beacons[beacon_owner]
	if not beacon_data or not beacon_data.entity or not beacon_data.entity.valid then return nil end
	
	-- Use beacon unit_number as network identifier
	return {
		beacon_unit_number = beacon_owner,
		beacon = beacon_data.entity,
		surface = entity.surface,
		force = entity.force
	}
end

return beacon_assignment

