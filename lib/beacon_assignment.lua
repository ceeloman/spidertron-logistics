-- Beacon-chest assignment system

local constants = require('lib.constants')
local utils = require('lib.utils')
local logging = require('lib.logging')

local beacon_assignment = {}

function beacon_assignment.find_beacon_with_highest_pickup_count(surface, position, force, max_distance)
	max_distance = max_distance or 1000  -- Default to 1000 tiles if not specified
	local beacons = surface.find_entities_filtered{
		name = constants.spidertron_logistic_beacon,
		force = force,
		to_be_deconstructed = false
	}
	
	if #beacons == 0 then
		return nil
	end
	
	local best_beacon = nil
	local best_pickup_count = -1
	local best_distance = math.huge
	
	for i = 1, #beacons do
		local beacon = beacons[i]
		
		-- Skip if beacon is not valid
		if not beacon.valid then goto next_beacon end
		
		-- Skip if beacon is not in storage
		if not storage.beacons[beacon.unit_number] then goto next_beacon end
		
		-- Skip if beacon entity in storage is not valid
		if not storage.beacons[beacon.unit_number].entity or not storage.beacons[beacon.unit_number].entity.valid then goto next_beacon end
		
		-- Check distance
		local dist = utils.distance(position, beacon.position)
		if dist > max_distance then goto next_beacon end
		
		-- Calculate total pickup count for this beacon (sum from all assigned chests)
		local beacon_data = storage.beacons[beacon.unit_number]
		local total_pickups = 0
		
		if beacon_data.assigned_chests then
			for _, chest_unit_number in ipairs(beacon_data.assigned_chests) do
				local provider_data = storage.providers[chest_unit_number]
				local requester_data = storage.requesters[chest_unit_number]
				
				if provider_data then
					total_pickups = total_pickups + (provider_data.pickup_count or 0)
				elseif requester_data then
					total_pickups = total_pickups + (requester_data.pickup_count or 0)
				end
			end
		end
		
		-- Prefer beacon with higher pickup count, or if equal, prefer closer one
		if total_pickups > best_pickup_count or (total_pickups == best_pickup_count and dist < best_distance) then
			best_beacon = beacon
			best_pickup_count = total_pickups
			best_distance = dist
		end
		
		::next_beacon::
	end
	
	return best_beacon
end

function beacon_assignment.find_nearest_beacon(surface, position, force, exclude_unit_number, context)
	context = context or "unknown"
	local beacons = surface.find_entities_filtered{
		name = constants.spidertron_logistic_beacon,
		force = force,
		to_be_deconstructed = false
	}
	
	if #beacons == 0 then
		-- logging.debug("Beacon", "[" .. context .. "] No beacons found on surface for position (" .. math.floor(position.x) .. "," .. math.floor(position.y) .. ")")
		return nil
	end
	
	-- logging.debug("Beacon", "[" .. context .. "] Found " .. #beacons .. " beacons on surface" .. (exclude_unit_number and " (excluding " .. exclude_unit_number .. ")" or ""))
	
	local nearest = nil
	local nearest_distance = math.huge
	local skipped_count = 0
	local excluded_count = 0
	local invalid_count = 0
	
	for i = 1, #beacons do
		local beacon = beacons[i]
		
		-- Skip excluded beacon
		if exclude_unit_number and beacon.unit_number == exclude_unit_number then
			-- logging.debug("Beacon", "[" .. context .. "] Skipping excluded beacon " .. beacon.unit_number)
			excluded_count = excluded_count + 1
			goto next_beacon
		end
		
		-- Skip if beacon is not valid (being destroyed)
		if not beacon.valid then
			-- logging.debug("Beacon", "[" .. context .. "] Skipping invalid beacon entity " .. (beacon.unit_number or "unknown"))
			invalid_count = invalid_count + 1
			goto next_beacon
		end
		
		-- Skip if beacon is not in storage (being destroyed or not registered)
		if not storage.beacons[beacon.unit_number] then
			-- logging.debug("Beacon", "[" .. context .. "] Skipping beacon " .. beacon.unit_number .. " not in storage")
			skipped_count = skipped_count + 1
			goto next_beacon
		end
		
		-- Skip if beacon entity in storage is not valid
		if not storage.beacons[beacon.unit_number].entity or not storage.beacons[beacon.unit_number].entity.valid then
			-- logging.debug("Beacon", "[" .. context .. "] Skipping beacon " .. beacon.unit_number .. " with invalid entity in storage")
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
	
	-- logging.debug("Beacon", "[" .. context .. "] Search results: " .. #beacons .. " total, " .. excluded_count .. " excluded, " .. invalid_count .. " invalid, " .. skipped_count .. " not in storage")
	
	if nearest then
		-- logging.debug("Beacon", "[" .. context .. "] Found nearest beacon " .. nearest.unit_number .. " at distance " .. string.format("%.2f", nearest_distance))
		return nearest
	else
		-- logging.warn("Beacon", "[" .. context .. "] No valid beacons found on surface for position (" .. math.floor(position.x) .. "," .. math.floor(position.y) .. ")")
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
		-- logging.info("Beacon", "Unassigning chest " .. chest_unit_number .. " from beacon " .. beacon_unit_number)
		local beacon_data = storage.beacons[beacon_unit_number]
		if beacon_data and beacon_data.assigned_chests then
			for i = #beacon_data.assigned_chests, 1, -1 do
				if beacon_data.assigned_chests[i] == chest_unit_number then
					table.remove(beacon_data.assigned_chests, i)
					-- logging.info("Beacon", "Removed chest " .. chest_unit_number .. " from beacon " .. beacon_unit_number .. "'s assigned_chests list")
					break
				end
			end
		end
		storage.beacon_assignments[chest_unit_number] = nil
		
		-- Clear beacon_owner from chest data
		if storage.providers[chest_unit_number] then
			storage.providers[chest_unit_number].beacon_owner = nil
			-- logging.info("Beacon", "Cleared beacon_owner from provider chest " .. chest_unit_number)
		elseif storage.requesters[chest_unit_number] then
			storage.requesters[chest_unit_number].beacon_owner = nil
			-- logging.info("Beacon", "Cleared beacon_owner from requester chest " .. chest_unit_number)
		end
	else
		-- logging.debug("Beacon", "Chest " .. chest_unit_number .. " was not assigned to any beacon (nothing to unassign)")
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
	
	-- logging.info("Beacon", "[" .. context .. "] assign_chest_to_nearest_beacon: " .. chest_type .. " chest " .. chest_unit_number .. " at (" .. math.floor(position.x) .. "," .. math.floor(position.y) .. ")" .. (exclude_beacon_unit_number and " (excluding beacon " .. exclude_beacon_unit_number .. ")" or ""))
	
	local nearest_beacon = beacon_assignment.find_nearest_beacon(surface, position, force, exclude_beacon_unit_number, context)
	if nearest_beacon then
		-- logging.info("Beacon", "Found nearest beacon " .. nearest_beacon.unit_number .. " for " .. chest_type .. " chest " .. chest_unit_number)
		
		-- Ensure beacon is registered in storage
		if not storage.beacons[nearest_beacon.unit_number] then
			-- logging.info("Beacon", "Registering unregistered beacon " .. nearest_beacon.unit_number)
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
			-- logging.info("Beacon", "Provider chest " .. chest_unit_number .. " beacon_owner set to " .. nearest_beacon.unit_number)
		elseif storage.requesters[chest_unit_number] then
			storage.requesters[chest_unit_number].beacon_owner = nearest_beacon.unit_number
			-- logging.info("Beacon", "Requester chest " .. chest_unit_number .. " beacon_owner set to " .. nearest_beacon.unit_number)
		else
			-- logging.warn("Beacon", "Chest " .. chest_unit_number .. " not found in storage after assignment - cannot set beacon_owner")
		end
	else
		-- logging.warn("Beacon", "No beacon found for " .. chest_type .. " chest " .. chest_unit_number .. " at (" .. math.floor(position.x) .. "," .. math.floor(position.y) .. ")")
	end
end

function beacon_assignment.spidertron_network(entity)
	-- Network is now surface-wide, not beacon-based
	-- All entities on the same surface/force share the same network
	-- Beacon assignment is still used for organizational purposes but doesn't affect network connectivity
	
	-- Ensure entity has a surface and force
	if not entity.surface or not entity.force then return nil end
	
	-- Use surface index as network identifier (surface-wide network)
	local network_key = entity.surface.index
	
	-- Get a representative beacon for this surface (for backward compatibility and other uses)
	-- Find any valid beacon on the surface to use as a reference
	local representative_beacon = nil
	for _, beacon_data in pairs(storage.beacons) do
		if beacon_data.entity and beacon_data.entity.valid then
			if beacon_data.entity.surface == entity.surface and beacon_data.entity.force == entity.force then
				representative_beacon = beacon_data.entity
				break
			end
		end
	end
	
	-- Return network representation based on surface
	return {
		network_key = network_key,  -- Surface-based network key
		surface = entity.surface,
		force = entity.force,
		beacon = representative_beacon  -- Optional: representative beacon for reference
	}
end

return beacon_assignment

