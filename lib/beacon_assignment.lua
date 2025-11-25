-- Beacon-chest assignment system

local constants = require('lib.constants')
local utils = require('lib.utils')
local logging = require('lib.logging')

local beacon_assignment = {}

function beacon_assignment.find_nearest_beacon(surface, position, force, exclude_unit_number, context)
	context = context or "unknown"
	local beacons = surface.find_entities_filtered{
		name = constants.spidertron_logistic_beacon,
		force = force,
		to_be_deconstructed = false
	}
	
	if #beacons == 0 then
		logging.debug("Beacon", "[" .. context .. "] No beacons found on surface for position (" .. math.floor(position.x) .. "," .. math.floor(position.y) .. ")")
		return nil
	end
	
	logging.debug("Beacon", "[" .. context .. "] Found " .. #beacons .. " beacons on surface" .. (exclude_unit_number and " (excluding " .. exclude_unit_number .. ")" or ""))
	
	local nearest = nil
	local nearest_distance = math.huge
	local skipped_count = 0
	local excluded_count = 0
	local invalid_count = 0
	
	for i = 1, #beacons do
		local beacon = beacons[i]
		
		-- Skip excluded beacon
		if exclude_unit_number and beacon.unit_number == exclude_unit_number then
			logging.debug("Beacon", "[" .. context .. "] Skipping excluded beacon " .. beacon.unit_number)
			excluded_count = excluded_count + 1
			goto next_beacon
		end
		
		-- Skip if beacon is not valid (being destroyed)
		if not beacon.valid then
			logging.debug("Beacon", "[" .. context .. "] Skipping invalid beacon entity " .. (beacon.unit_number or "unknown"))
			invalid_count = invalid_count + 1
			goto next_beacon
		end
		
		-- Skip if beacon is not in storage (being destroyed or not registered)
		if not storage.beacons[beacon.unit_number] then
			logging.debug("Beacon", "[" .. context .. "] Skipping beacon " .. beacon.unit_number .. " not in storage")
			skipped_count = skipped_count + 1
			goto next_beacon
		end
		
		-- Skip if beacon entity in storage is not valid
		if not storage.beacons[beacon.unit_number].entity or not storage.beacons[beacon.unit_number].entity.valid then
			logging.debug("Beacon", "[" .. context .. "] Skipping beacon " .. beacon.unit_number .. " with invalid entity in storage")
			invalid_count = invalid_count + 1
			goto next_beacon
		end
		
		local dist = utils.distance(position, beacon.position)
		if dist < nearest_distance then
			nearest = beacon
			nearest_distance = dist
		end
		
		::next_beacon::
	end
	
	logging.debug("Beacon", "[" .. context .. "] Search results: " .. #beacons .. " total, " .. excluded_count .. " excluded, " .. invalid_count .. " invalid, " .. skipped_count .. " not in storage")
	
	if nearest then
		logging.debug("Beacon", "[" .. context .. "] Found nearest beacon " .. nearest.unit_number .. " at distance " .. string.format("%.2f", nearest_distance))
		return nearest
	else
		logging.warn("Beacon", "[" .. context .. "] No valid beacons found on surface for position (" .. math.floor(position.x) .. "," .. math.floor(position.y) .. ")")
		return nil
	end
end

function beacon_assignment.find_nearest_provider_chest(surface, position, force)
	local providers = surface.find_entities_filtered{
		name = constants.spidertron_provider_chest,
		force = force,
		to_be_deconstructed = false
	}
	
	if #providers == 0 then
		return nil
	end
	
	local nearest = providers[1]
	local nearest_distance = utils.distance(position, nearest.position)
	
	for i = 2, #providers do
		local provider = providers[i]
		local dist = utils.distance(position, provider.position)
		if dist < nearest_distance then
			nearest = provider
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
		logging.info("Beacon", "Unassigning chest " .. chest_unit_number .. " from beacon " .. beacon_unit_number)
		local beacon_data = storage.beacons[beacon_unit_number]
		if beacon_data and beacon_data.assigned_chests then
			for i = #beacon_data.assigned_chests, 1, -1 do
				if beacon_data.assigned_chests[i] == chest_unit_number then
					table.remove(beacon_data.assigned_chests, i)
					logging.info("Beacon", "Removed chest " .. chest_unit_number .. " from beacon " .. beacon_unit_number .. "'s assigned_chests list")
					break
				end
			end
		end
		storage.beacon_assignments[chest_unit_number] = nil
		
		-- Clear beacon_owner from chest data
		if storage.providers[chest_unit_number] then
			storage.providers[chest_unit_number].beacon_owner = nil
			logging.info("Beacon", "Cleared beacon_owner from provider chest " .. chest_unit_number)
		elseif storage.requesters[chest_unit_number] then
			storage.requesters[chest_unit_number].beacon_owner = nil
			logging.info("Beacon", "Cleared beacon_owner from requester chest " .. chest_unit_number)
		end
	else
		logging.debug("Beacon", "Chest " .. chest_unit_number .. " was not assigned to any beacon (nothing to unassign)")
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
	
	-- Reassign all chests to their nearest beacon (which might be this one)
	-- This ensures chests get assigned to the closest beacon, not just this one
	for _, provider in ipairs(providers) do
		-- Use assign_chest_to_nearest_beacon to find the actual nearest beacon
		beacon_assignment.assign_chest_to_nearest_beacon(provider, nil, "assign_all_chests_to_beacon")
	end
	
	for _, requester in ipairs(requesters) do
		-- Use assign_chest_to_nearest_beacon to find the actual nearest beacon
		beacon_assignment.assign_chest_to_nearest_beacon(requester, nil, "assign_all_chests_to_beacon")
	end
end

function beacon_assignment.assign_chest_to_nearest_beacon(chest, exclude_beacon_unit_number, context)
	local surface = chest.surface
	local force = chest.force
	local position = chest.position
	local chest_unit_number = chest.unit_number
	local chest_type = "unknown"
	context = context or "unknown"
	
	-- Determine chest type
	if storage.providers[chest_unit_number] then
		chest_type = "provider"
	elseif storage.requesters[chest_unit_number] then
		chest_type = "requester"
	end
	
	logging.info("Beacon", "[" .. context .. "] assign_chest_to_nearest_beacon: " .. chest_type .. " chest " .. chest_unit_number .. " at (" .. math.floor(position.x) .. "," .. math.floor(position.y) .. ")" .. (exclude_beacon_unit_number and " (excluding beacon " .. exclude_beacon_unit_number .. ")" or ""))
	
	local nearest_beacon = beacon_assignment.find_nearest_beacon(surface, position, force, exclude_beacon_unit_number, context)
	if nearest_beacon then
		logging.info("Beacon", "Found nearest beacon " .. nearest_beacon.unit_number .. " for " .. chest_type .. " chest " .. chest_unit_number)
		
		-- Ensure beacon is registered in storage
		if not storage.beacons[nearest_beacon.unit_number] then
			logging.info("Beacon", "Registering unregistered beacon " .. nearest_beacon.unit_number)
			-- Register the beacon if it's not already registered
			storage.beacons[nearest_beacon.unit_number] = {
				entity = nearest_beacon,
				assigned_chests = {}
			}
			script.register_on_object_destroyed(nearest_beacon)
		end
		
		beacon_assignment.unassign_chest_from_beacon(chest_unit_number)
		beacon_assignment.assign_chest_to_beacon(chest_unit_number, nearest_beacon.unit_number)
		
		-- Update chest data
		if storage.providers[chest_unit_number] then
			storage.providers[chest_unit_number].beacon_owner = nearest_beacon.unit_number
			logging.info("Beacon", "Provider chest " .. chest_unit_number .. " beacon_owner set to " .. nearest_beacon.unit_number)
		elseif storage.requesters[chest_unit_number] then
			storage.requesters[chest_unit_number].beacon_owner = nearest_beacon.unit_number
			logging.info("Beacon", "Requester chest " .. chest_unit_number .. " beacon_owner set to " .. nearest_beacon.unit_number)
		else
			logging.warn("Beacon", "Chest " .. chest_unit_number .. " not found in storage after assignment - cannot set beacon_owner")
		end
	else
		logging.warn("Beacon", "No beacon found for " .. chest_type .. " chest " .. chest_unit_number .. " at (" .. math.floor(position.x) .. "," .. math.floor(position.y) .. ")")
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
				beacon_assignment.assign_chest_to_nearest_beacon(entity, nil, "spidertron_network_provider")
				beacon_owner = provider_data.beacon_owner
			end
		end
	elseif entity.name == constants.spidertron_requester_chest then
		local requester_data = storage.requesters[entity.unit_number]
		if requester_data then
			beacon_owner = requester_data.beacon_owner
			-- If no beacon owner, try to assign to nearest beacon
			if not beacon_owner then
				beacon_assignment.assign_chest_to_nearest_beacon(entity, nil, "spidertron_network_requester")
				beacon_owner = requester_data.beacon_owner
			end
		end
	elseif entity.name == constants.spidertron_logistic_beacon then
		beacon_owner = entity.unit_number
	else
		-- For spiders, find nearest beacon
		local nearest_beacon = beacon_assignment.find_nearest_beacon(entity.surface, entity.position, entity.force, nil, "spidertron_network_spider")
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

