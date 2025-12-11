-- Core logistics functions: spiders, requesters, providers, and assignment

local constants = require('lib.constants')
local beacon_assignment = require('lib.beacon_assignment')
local rendering = require('lib.rendering')
local utils = require('lib.utils')
local pathing = require('lib.pathing')
local terrain = require('lib.terrain')
local logging = require('lib.logging')

local logistics = {}

-- Helper function to check if we should log (only for radar items)
local function should_log(item_name)
	return item_name == "radar"
end

-- TODO: Robot Chest Support (Future Implementation)
-- Previously supported robot chests (storage-chest, active-provider-chest, passive-provider-chest) as providers.
-- Removed due to performance concerns with scanning/caching.
-- Future implementation should:
-- 1. Periodically scan chunks for robot chests (only where requesters exist)
-- 2. Check robot chests in batches (process N chests per cycle)
-- 3. Only cache robot chests that contain requested items
-- 4. Use efficient chunk-based scanning instead of full surface scans
-- 5. Update cache when robot chests are built/destroyed
-- 
-- Removed functions:
-- - logistics.update_robot_chest_cache(chest) - Updated robot chest cache with inventory contents
-- - logistics.remove_robot_chest_from_cache(chest_unit_number) - Removed chest from cache on destruction

-- Batch refresh all provider and requester inventories
-- This runs once per logistics cycle to minimize inventory API calls
function logistics.refresh_inventory_caches(force_refresh)
	local current_tick = game.tick
	
	-- Only refresh if cache is stale or forced
	if not force_refresh and storage.last_inventory_refresh then
		if current_tick - storage.last_inventory_refresh < constants.inventory_cache_ttl then
			return -- Cache still fresh (within TTL)
		end
	end
	
	-- Batch refresh all provider inventories
	for unit_number, provider_data in pairs(storage.providers) do
		if provider_data.entity and provider_data.entity.valid then
			local inventory = provider_data.entity.get_inventory(defines.inventory.chest)
			if inventory then
				local contents = inventory.get_contents()
				provider_data.cached_contents = {}
				
				if contents then
					for item_name, count_or_qualities in pairs(contents) do
						local total = 0
						if type(count_or_qualities) == "number" then
							total = count_or_qualities
						elseif type(count_or_qualities) == "table" then
							for _, qty in pairs(count_or_qualities) do
								if type(qty) == "number" then
									total = total + qty
								end
							end
						end
						if total > 0 then
							provider_data.cached_contents[item_name] = total
						end
					end
				end
				provider_data.cache_tick = current_tick
			end
		end
	end
	
	-- TODO: Robot Chest Cache Refresh (Future Implementation)
	-- Previously refreshed robot chest cache periodically to keep inventory data current.
	-- Future implementation should refresh cache in batches, only for chests with requested items.
	
	-- Batch refresh all requester inventories
	for unit_number, requester_data in pairs(storage.requesters) do
		if requester_data.entity and requester_data.entity.valid then
			local inventory = requester_data.entity.get_inventory(defines.inventory.chest)
			if inventory then
				local contents = inventory.get_contents()
				requester_data.cached_item_counts = {}
				
				if contents then
					for item, count_or_qualities in pairs(contents) do
						local total = 0
						if type(count_or_qualities) == "number" then
							total = count_or_qualities
						elseif type(count_or_qualities) == "table" then
							for _, qty in pairs(count_or_qualities) do
								if type(qty) == "number" then
									total = total + qty
								end
							end
						end
						if total > 0 then
							requester_data.cached_item_counts[item] = total
						end
					end
				end
				requester_data.cache_tick = current_tick
			end
		end
	end
	
	storage.last_inventory_refresh = current_tick
end

function logistics.spiders()
	local valid = {}
	local total_spiders = 0
	local inactive_count = 0
	local busy_count = 0
	local no_network_count = 0
	
	for unit_number, spider_data in pairs(storage.spiders) do
		total_spiders = total_spiders + 1
		local spider = spider_data.entity
		if not spider or not spider.valid then
			-- Clean up invalid spider reference immediately
			storage.spiders[unit_number] = nil
			goto valid
		end
		if not spider_data.active then 
			inactive_count = inactive_count + 1
			goto valid 
		end  -- Check logistics activation state
		if spider_data.status ~= constants.idle then 
			busy_count = busy_count + 1
			goto valid 
		end
		
		local network = beacon_assignment.spidertron_network(spider)
		if network == nil then
			no_network_count = no_network_count + 1
			rendering.draw_missing_roboport_icon(spider, {0, -1.75})
			goto valid
		end
		
		-- Only active spiders participate in logistics
		if spider_data.active then
			local network_key = network.network_key
			if not valid[network_key] then
				valid[network_key] = {}
			end
			valid[network_key][#valid[network_key] + 1] = spider
		end
		::valid::
	end
	
	local available_count = 0
	for _, spids in pairs(valid) do
		available_count = available_count + #spids
	end
	
	
	return valid
end

local function requester_sort_function(a, b)
	local a_filled = a.percentage_filled
	local b_filled = b.percentage_filled
	return a_filled == b_filled and a.random_sort_order < b.random_sort_order or a_filled < b_filled
end

function logistics.should_request_item(requester_data, item_name)
	local should_log_item = item_name == "radar"
	
	if not requester_data.requested_items or not requester_data.requested_items[item_name] then
		-- if should_log_item then
		-- 	game.print("[SHOULD_REQUEST] Tick " .. game.tick .. ": Requester " .. requester_data.entity.unit_number .. " item '" .. item_name .. "' - FALSE: no requested_items or item not in list")
		-- end
		return false
	end
	
	local item_data = requester_data.requested_items[item_name]
	
	-- Handle migration from old format (number) to new format (table)
	local requested_count
	local buffer_threshold
	if type(item_data) == "number" then
		-- Old format: migrate to new format
		requested_count = item_data
		buffer_threshold = 0.8
		requester_data.requested_items[item_name] = {
			count = requested_count,
			buffer_threshold = buffer_threshold,
			min_buffer_threshold = 0
		}
	else
		-- New format: extract count and buffer_threshold
		requested_count = item_data.count or 0
		buffer_threshold = item_data.buffer_threshold or 0.8
	end
	
	if requested_count <= 0 then 
		-- if should_log_item then
		-- 	game.print("[SHOULD_REQUEST] Tick " .. game.tick .. ": Requester " .. requester_data.entity.unit_number .. " item '" .. item_name .. "' - FALSE: requested_count=" .. requested_count)
		-- end
		return false 
	end
	
	-- Get current amount in chest - ALWAYS use live data to ensure accuracy
	-- Use get_item_count() which handles all quality formats automatically
	local current_amount = 0
	local inventory = requester_data.entity.get_inventory(defines.inventory.chest)
	if inventory then
		current_amount = inventory.get_item_count(item_name) or 0
	end
	
	-- Get incoming items (items already assigned to spiders for delivery)
	local incoming = 0
	if requester_data.incoming_items and requester_data.incoming_items[item_name] then
		incoming = requester_data.incoming_items[item_name]
	end
	
	-- Calculate percentage filled (including incoming items)
	local total_amount = current_amount + incoming
	local percentage_filled = total_amount / requested_count
	
	-- Clear stale incoming_items ONLY if chest is ACTUALLY full (current_amount >= requested_count)
	-- Do NOT clear just because (current_amount + incoming) >= buffer_threshold - incoming items haven't arrived yet!
	-- This handles cases where requests were created in older mod versions and chests got filled
	if current_amount >= requested_count and incoming > 0 then
		-- Chest is actually full, clear incoming_items to prevent stale tracking
		if not requester_data.incoming_items then
			requester_data.incoming_items = {}
		end
		-- game.print("[CLEAR INCOMING] Tick " .. game.tick .. ": Clearing incoming_items (chest actually full) - requester=" .. requester_data.entity.unit_number .. 
		-- 	", item=" .. item_name .. 
		-- 	", incoming=" .. incoming .. 
		-- 	", current_amount=" .. current_amount .. 
		-- 	", requested=" .. requested_count)
		requester_data.incoming_items[item_name] = nil
		incoming = 0
		-- Recalculate with cleared incoming
		total_amount = current_amount
		percentage_filled = total_amount / requested_count
		-- if should_log_item then
		-- 	game.print("[CACHE CLEANUP] Tick " .. game.tick .. ": Cleared stale incoming_items for '" .. item_name .. "' - chest already full (fill%=" .. string.format("%.1f", percentage_filled * 100) .. " >= buffer=" .. string.format("%.1f", buffer_threshold * 100) .. ")")
		-- end
	end
	
	-- Request if below buffer threshold
	local should_request = percentage_filled < buffer_threshold
	-- if should_log_item then
	-- 	game.print("[SHOULD_REQUEST] Tick " .. game.tick .. ": Requester " .. requester_data.entity.unit_number .. " item '" .. item_name .. "' - " .. (should_request and "TRUE" or "FALSE") .. 
	-- 		" (requested=" .. requested_count .. ", current=" .. current_amount .. ", incoming=" .. incoming .. ", total=" .. total_amount .. 
	-- 		", fill%=" .. string.format("%.1f", percentage_filled * 100) .. ", buffer=" .. string.format("%.1f", buffer_threshold * 100) .. 
	-- 		", LIVE_DATA)")
	-- end
	
	return should_request
end

-- Global validation function to check all requesters and clear stale data
function logistics.validate_all_requesters()
	local validated_count = 0
	local cleared_count = 0
	
	for unit_number, requester_data in pairs(storage.requesters) do
		local requester = requester_data.entity
		if not requester or not requester.valid then
			storage.requesters[unit_number] = nil
			goto next_requester
		end
		
		if not requester_data.requested_items then
			goto next_requester
		end
		
		-- Get live inventory data for all requested items
		local inventory = requester.get_inventory(defines.inventory.chest)
		if not inventory then
			goto next_requester
		end
		
		local contents = inventory.get_contents()
		if not contents then
			goto next_requester
		end
		
		-- Check each requested item
		for item_name, item_data in pairs(requester_data.requested_items) do
			validated_count = validated_count + 1
			
			-- Get requested count and buffer threshold
			local requested_count = 0
			local buffer_threshold = 0.8
			if type(item_data) == "number" then
				requested_count = item_data
			else
				requested_count = item_data.count or 0
				buffer_threshold = item_data.buffer_threshold or 0.8
			end
			
			if requested_count <= 0 then
				goto next_item_validation
			end
			
			-- Get actual current amount from chest - use get_item_count() which handles all formats automatically
			local inventory = requester.get_inventory(defines.inventory.chest)
			local current_amount = 0
			if inventory then
				current_amount = inventory.get_item_count(item_name) or 0
			end
			
			-- if item_name == "radar" then
			-- 	game.print("[VALIDATION] Tick " .. game.tick .. ": Requester " .. unit_number .. " item '" .. item_name .. "' - get_item_count() returned: " .. current_amount)
			-- end
			
			-- Get incoming items
			local incoming = 0
			if requester_data.incoming_items and requester_data.incoming_items[item_name] then
				incoming = requester_data.incoming_items[item_name]
			end
			
			-- Calculate fill percentage
			local total_amount = current_amount + incoming
			local percentage_filled = total_amount / requested_count
			
			-- If chest is ACTUALLY full (current_amount >= requested_count) but has incoming_items, clear them
			-- Do NOT clear just because (current_amount + incoming) >= buffer_threshold
			if current_amount >= requested_count and incoming > 0 then
				if not requester_data.incoming_items then
					requester_data.incoming_items = {}
				end
				-- game.print("[CLEAR INCOMING] Tick " .. game.tick .. ": Clearing incoming_items (validation, chest actually full) - requester=" .. unit_number .. 
				-- 	", item=" .. item_name .. 
				-- 	", incoming=" .. incoming .. 
				-- 	", current_amount=" .. current_amount .. 
				-- 	", requested=" .. requested_count)
				requester_data.incoming_items[item_name] = nil
				cleared_count = cleared_count + 1
				
				if item_name == "radar" then
					game.print("[GLOBAL VALIDATION] Tick " .. game.tick .. ": Requester " .. unit_number .. " at (" .. 
						math.floor(requester.position.x) .. "," .. math.floor(requester.position.y) .. 
						") - Cleared stale incoming_items for '" .. item_name .. "' (current=" .. current_amount .. 
						", requested=" .. requested_count .. ", fill%=" .. string.format("%.1f", percentage_filled * 100) .. 
						" >= buffer=" .. string.format("%.1f", buffer_threshold * 100) .. ")")
				end
			end
			
			-- Invalidate cache to force refresh on next check
			requester_data.cached_item_counts = nil
			requester_data.cache_tick = nil
			
			::next_item_validation::
		end
		
		::next_requester::
	end
	
	-- if validated_count > 0 then
	-- 	game.print("[GLOBAL VALIDATION] Tick " .. game.tick .. ": Validated " .. validated_count .. " request(s), cleared " .. cleared_count .. " stale incoming_items")
	-- end
end

function logistics.requesters()
	-- Refresh inventory caches once per cycle (use cached data exclusively)
	logistics.refresh_inventory_caches(false)
	
	local result = {}
	local random = math.random
	local sort = table.sort
	
	for unit_number, requester_data in pairs(storage.requesters) do
		local requester = requester_data.entity
		if not requester or not requester.valid then
			-- Clean up invalid requester reference immediately
			storage.requesters[unit_number] = nil
			goto continue
		end
		if requester.to_be_deconstructed() then goto continue end
		
		local network = beacon_assignment.spidertron_network(requester)
		if network == nil then
			-- On-demand validation: if no beacon, try to assign one
			if not requester_data.beacon_owner then
				beacon_assignment.assign_chest_to_nearest_beacon(requester, nil, "on_demand_validation")
				network = beacon_assignment.spidertron_network(requester)
			end
			if network == nil then
				rendering.draw_missing_roboport_icon(requester)
				goto continue
			end
		end
		
		-- Migrate old format if needed
		if not requester_data.requested_items then
			requester_data.requested_items = {}
			if requester_data.requested_item then
				-- Migrate to new format
				local old_count = requester_data.request_size or 0
				requester_data.requested_items[requester_data.requested_item] = {
					count = old_count,
					buffer_threshold = 0.8,
					min_buffer_threshold = 0
				}
			end
		end
		
		-- Log all configured requests for this requester (only for radar)
		-- if requester_data.requested_items and next(requester_data.requested_items) then
		-- 	local request_list = {}
		-- 	for req_item, req_data in pairs(requester_data.requested_items) do
		-- 		if should_log(req_item) then
		-- 			local req_count = type(req_data) == "number" and req_data or (req_data.count or 0)
		-- 			if req_count > 0 then
		-- 				table.insert(request_list, req_item .. " x" .. req_count)
		-- 			end
		-- 		end
		-- 	end
		-- 	if #request_list > 0 then
		-- 		game.print("[REQUEST CHECK] Tick " .. game.tick .. ": Checking requester " .. unit_number .. " at (" .. math.floor(requester.position.x) .. "," .. math.floor(requester.position.y) .. ") - configured: " .. table.concat(request_list, ", "))
		-- 	end
		-- end
		
		-- Process each requested item
		for item_name, item_data in pairs(requester_data.requested_items) do
			-- Handle migration from old format (number) to new format (table)
			local requested_count
			local buffer_threshold
			local min_buffer_threshold
			if type(item_data) == "number" then
				-- Old format: migrate to new format
				requested_count = item_data
				buffer_threshold = 0.8
				min_buffer_threshold = 0
				requester_data.requested_items[item_name] = {
					count = requested_count,
					buffer_threshold = buffer_threshold,
					min_buffer_threshold = min_buffer_threshold
				}
			else
				-- New format: extract values
				requested_count = item_data.count or 0
				buffer_threshold = item_data.buffer_threshold or 0.8
				min_buffer_threshold = item_data.min_buffer_threshold or 0
			end
			
			if not item_name or item_name == '' or requested_count <= 0 then 
				-- if should_log(item_name) then
				-- 	game.print("[REQUEST CHECK] Tick " .. game.tick .. ": Requester " .. unit_number .. " item '" .. (item_name or "nil") .. "' - SKIP: invalid item or count=" .. requested_count)
				-- end
				goto next_item 
			end
			if not requester.can_insert(item_name) then 
				-- if should_log(item_name) then
				-- 	game.print("[REQUEST CHECK] Tick " .. game.tick .. ": Requester " .. unit_number .. " item '" .. item_name .. "' - SKIP: cannot insert")
				-- end
				goto next_item 
			end
			
			-- Use should_request_item to check if item should be requested
			local should_request = logistics.should_request_item(requester_data, item_name)
			if not should_request then 
				-- if should_log(item_name) then
				-- 	game.print("[REQUEST CHECK] Tick " .. game.tick .. ": Requester " .. unit_number .. " item '" .. item_name .. "' - SKIP: should_request_item returned false")
				-- end
				goto next_item 
			end
			
			if not requester_data.incoming_items then
				requester_data.incoming_items = {}
			end
			local incoming = requester_data.incoming_items[item_name] or 0
			
			-- Debug: Log incoming_items state
			-- game.print("[REQUESTERS DEBUG] Tick " .. game.tick .. ": Checking incoming_items - requester=" .. unit_number .. 
			-- 	", item=" .. item_name .. 
			-- 	", incoming_items_table=" .. (requester_data.incoming_items and "exists" or "nil") .. 
			-- 	", incoming_items[" .. item_name .. "]=" .. incoming)
			
			-- Get current amount - ALWAYS use live data to ensure accuracy (same as should_request_item)
			-- Use get_item_count() which handles all quality formats automatically
			local already_had = 0
			local inventory = requester.get_inventory(defines.inventory.chest)
			if inventory then
				already_had = inventory.get_item_count(item_name) or 0
			end
			-- if should_log(item_name) then
			-- 	game.print("[REQUEST CHECK] Tick " .. game.tick .. ": Requester " .. unit_number .. " item '" .. item_name .. "' - using LIVE count (get_item_count): " .. already_had)
			-- end
			
			-- Clear stale incoming_items ONLY if chest is ACTUALLY full (already_had >= requested_count)
			-- Do NOT clear just because (already_had + incoming) >= buffer_threshold
			if already_had >= requested_count and incoming > 0 then
				-- Chest is actually full, clear stale incoming_items
				-- game.print("[CLEAR INCOMING] Tick " .. game.tick .. ": Clearing incoming_items (requesters(), chest actually full) - requester=" .. unit_number .. 
				-- 	", item=" .. item_name .. 
				-- 	", incoming=" .. incoming .. 
				-- 	", already_had=" .. already_had .. 
				-- 	", requested=" .. requested_count)
				requester_data.incoming_items[item_name] = nil
				incoming = 0
				-- if should_log(item_name) then
				-- 	game.print("[CACHE CLEANUP] Tick " .. game.tick .. ": Cleared stale incoming_items for '" .. item_name .. "' in requesters() - chest already full (fill%=" .. string.format("%.1f", temp_percentage * 100) .. " >= buffer=" .. string.format("%.1f", buffer_threshold * 100) .. ")")
				-- end
			end
			
			-- Calculate real_amount needed (request up to full requested_count)
			local real_amount = requested_count - incoming - already_had
			if real_amount <= 0 then 
				-- if should_log(item_name) then
				-- 	game.print("[REQUEST CHECK] Tick " .. game.tick .. ": Requester " .. unit_number .. " item '" .. item_name .. "' - SKIP: real_amount=" .. real_amount .. " (requested=" .. requested_count .. ", incoming=" .. incoming .. ", already_had=" .. already_had .. ")")
				-- end
				goto next_item 
			end
			
			-- Create a request entry for this item
			local item_request = {
				entity = requester,
				requester_data = requester_data,
				requested_item = item_name,
				request_size = requested_count,
				real_amount = real_amount,
				incoming = incoming,
				already_had = already_had,
				percentage_filled = (incoming + already_had) / requested_count,
				random_sort_order = random()
			}
			
			-- game.print("[REQUESTERS] Tick " .. game.tick .. ": Created request - item=" .. item_name .. 
			-- 	", requester=" .. unit_number .. 
			-- 	", requested=" .. requested_count .. 
			-- 	", already_had=" .. already_had .. 
			-- 	", incoming=" .. incoming .. 
			-- 	", real_amount=" .. real_amount)
			
			-- Use surface-based network key
			local network_key = network.network_key
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
	-- Refresh inventory caches once per cycle (use cached data exclusively)
	logistics.refresh_inventory_caches(false)
	
	local result = {}

	-- First, add custom provider chests (existing logic)
	for unit_number, provider_data in pairs(storage.providers) do
		local provider = provider_data.entity
		if not provider or not provider.valid then
			-- Clean up invalid provider reference immediately
			storage.providers[unit_number] = nil
			goto continue
		end
			
		if provider.to_be_deconstructed() then 
			goto continue 
		end
		
		local network = beacon_assignment.spidertron_network(provider)
		if not network then
			-- On-demand validation: if no beacon, try to assign one
			if not provider_data.beacon_owner then
				beacon_assignment.assign_chest_to_nearest_beacon(provider, nil, "on_demand_validation")
				network = beacon_assignment.spidertron_network(provider)
			end
			if not network then
				logging.warn("Providers", "Provider chest at (" .. math.floor(provider.position.x) .. "," .. math.floor(provider.position.y) .. ") has no network/beacon assigned")
				rendering.draw_missing_roboport_icon(provider)
				goto continue
			end
		end
		
		-- Use cached inventory data exclusively (cache refreshed by refresh_inventory_caches())
		local contains = nil
		local current_tick = game.tick
		if provider_data.cached_contents and provider_data.cache_tick then
			local cache_age = current_tick - provider_data.cache_tick
			if cache_age < constants.inventory_cache_ttl then
				contains = provider_data.cached_contents
			else
				-- Cache expired - should have been refreshed by refresh_inventory_caches()
				-- Fallback to empty (shouldn't happen in normal operation)
				contains = {}
			end
		else
			-- No cache available - should have been refreshed by refresh_inventory_caches()
			-- Fallback to empty (shouldn't happen in normal operation)
			contains = {}
		end
		
		if next(contains) == nil then 
			goto continue 
		end
		
		-- Build item list string for logging
		local item_list = {}
		for item_name, count in pairs(contains) do
			table.insert(item_list, item_name .. " x" .. count)
		end
		provider_data.contains = contains
		
		-- Use surface-based network key
		local network_key = network.network_key
		if not result[network_key] then
			result[network_key] = {provider_data}
		else
			result[network_key][#result[network_key] + 1] = provider_data
		end
		
		::continue::
	end
	
	-- TODO: Robot Chest Provider Addition (Future Implementation)
	-- Previously added robot chests (storage-chest, active-provider-chest, passive-provider-chest) to provider list.
	-- Future implementation should:
	-- 1. Only add robot chests that contain requested items
	-- 2. Use chunk-based scanning to find relevant chests
	-- 3. Process in batches to avoid performance issues
	
	-- Now add requester chests with excess items (if allow_excess_provider is enabled)
	local requester_excess_count = 0
	for _, requester_data in pairs(storage.requesters) do
		local requester = requester_data.entity
		if not requester.valid then goto next_requester end
		if requester.to_be_deconstructed() then goto next_requester end
		
		local network = beacon_assignment.spidertron_network(requester)
		if not network then goto next_requester end
		
		-- Check if requester has requested items configured
		if not requester_data.requested_items then goto next_requester end
		
		local inventory = requester.get_inventory(defines.inventory.chest)
		if not inventory then goto next_requester end
		
		-- Build contains map with excess items only
		-- Iterate through requested_items instead of chest contents to ensure we use correct item names
		local excess_contains = {}
		for item_name, item_data in pairs(requester_data.requested_items) do
			-- Get the actual count in the chest for this item - use LIVE data, not cached
			local total_count = 0
			if inventory then
				total_count = inventory.get_item_count(item_name) or 0
			end
			
			-- Also check cached for comparison
			local cached_count = 0
			if requester_data.cached_item_counts then
				cached_count = requester_data.cached_item_counts[item_name] or 0
			end
			
			if total_count > 0 then
				-- Handle migration from old format
				local requested_count
				local allow_excess
				if type(item_data) == "number" then
					requested_count = item_data
					allow_excess = true  -- Default to true for old format
				else
					requested_count = item_data.count or 0
					allow_excess = item_data.allow_excess_provider ~= nil and item_data.allow_excess_provider or true
				end
				
				-- Only add excess items if allow_excess_provider is true
				if allow_excess and total_count > requested_count then
					local excess_amount = total_count - requested_count
					if excess_amount > 0 then
						excess_contains[item_name] = excess_amount
					end
				end
			end
		end
		
		-- Only add this requester as a provider if it has excess items
		if next(excess_contains) ~= nil then
			requester_excess_count = requester_excess_count + 1
			
			-- Create provider data for requester with excess items
			local requester_provider_data = {
				entity = requester,
				allocated_items = {},
				pickup_count = 0,
				dropoff_count = 0,
				beacon_owner = requester_data.beacon_owner,
				is_requester_excess = true,  -- Flag to identify requester excess providers
				contains = excess_contains
			}
			
			-- Add to result by surface network
			local network_key = network.network_key
			if not result[network_key] then
				result[network_key] = {requester_provider_data}
			else
				result[network_key][#result[network_key] + 1] = requester_provider_data
			end
		end
		
		::next_requester::
	end
	
	return result
end

function logistics.assign_spider(spiders, requester_data, provider_data, can_provide)
	local provider = provider_data.entity
	if not provider.valid then 
		return false 
	end
	local item = requester_data.requested_item
	local requester = requester_data.entity
	
	-- Log assignment attempt (only for radar)
	-- if item == "radar" then
	-- 	game.print("[ASSIGN ATTEMPT] Tick " .. game.tick .. ": Attempting to assign spider for 'radar' - requester " .. requester.unit_number .. 
	-- 		" at (" .. math.floor(requester.position.x) .. "," .. math.floor(requester.position.y) .. 
	-- 		"), provider " .. provider.unit_number .. " at (" .. math.floor(provider.position.x) .. "," .. math.floor(provider.position.y) .. 
	-- 		"), can_provide=" .. can_provide .. ", available_spiders=" .. #spiders)
	-- end
	
	
	local position = provider.position
	local x, y = position.x, position.y
	local spider
	local best_distance
	local spider_index
	local remove = table.remove
	
	local surface = provider.surface
	
	-- Check if provider or requester is in dangerous territory (within 80 tiles of enemy nests)
	-- This matches the NEST_AVOIDANCE_DISTANCE used in pathing
	local DANGEROUS_TERRITORY_DISTANCE = 80
	local provider_near_nests = surface.find_entities_filtered{
		position = provider.position,
		radius = DANGEROUS_TERRITORY_DISTANCE,
		type = {"unit-spawner", "turret"},  -- Nests and worms
		force = "enemy"
	}
	local requester_near_nests = surface.find_entities_filtered{
		position = requester.position,
		radius = DANGEROUS_TERRITORY_DISTANCE,
		type = {"unit-spawner", "turret"},  -- Nests and worms
		force = "enemy"
	}
	
	if #provider_near_nests > 0 then
		return false
	end
	
	if #requester_near_nests > 0 then
		return false
	end
	
	
	for i, canidate in ipairs(spiders) do
		-- Check if spider can insert item into trunk inventory
		local trunk = canidate.get_inventory(defines.inventory.spider_trunk)
		if trunk and trunk.can_insert({name = item, count = 1}) then
			-- Check if spider can traverse water (legs with "player" collision layer can't traverse water)
			local can_water = pathing.can_spider_traverse_water(canidate)
			
			-- If spider can't traverse water, check if a path can be found
			-- Uses the same logic as Spidertron Enhancements mod
			if not can_water then
				local provider_pos = provider.position
				local requester_pos = requester.position
				
				-- Check if path can be found from provider to requester
				if not pathing.can_find_path(surface, provider_pos, requester_pos, canidate) then
					goto next_spider
				end
			end
			
			local canidate_position = canidate.position
			local dist = utils.distance(x, y, canidate_position.x, canidate_position.y)
			
			if not spider or best_distance > dist then
				spider = canidate
				best_distance = dist
				spider_index = i
			end
		else
		end
		::next_spider::
	end
	if not spider then 
		return false 
	end
	
	
	local spider_data = storage.spiders[spider.unit_number]
	local amount = requester_data.real_amount
	
	-- game.print("[ASSIGN_SPIDER] Tick " .. game.tick .. ": assign_spider called - SPIDER_ID=" .. spider.unit_number .. 
	-- 	", item=" .. item .. 
	-- 	", requester=" .. requester.unit_number .. 
	-- 	", provider=" .. provider.unit_number .. 
	-- 	", real_amount=" .. amount .. 
	-- 	", can_provide_before=" .. can_provide)
	
	if can_provide > amount then can_provide = amount end
	
	-- Validate trunk capacity: ensure we don't assign more than the spider can carry
	local trunk = spider.get_inventory(defines.inventory.spider_trunk)
	if trunk then
		local already_has = spider.get_item_count(item) or 0
		local stack_size = utils.stack_size(item)
		
		-- Calculate available space in trunk for THIS specific item
		-- Check space in existing stacks of this item
		local space_in_existing = 0
		for i = 1, #trunk do
			local stack = trunk[i]
			if stack and stack.valid_for_read and stack.name == item then
				space_in_existing = space_in_existing + (stack_size - stack.count)
			end
		end
		
		-- Check empty slots (slots that can hold this item)
		local empty_slots = trunk.count_empty_stacks(false, false)
		local space_in_empty = empty_slots * stack_size
		local max_can_carry = space_in_existing + space_in_empty
		
		-- CRITICAL: Also check if spider can actually insert this item at all
		-- This handles cases where trunk is full of other items
		if not trunk.can_insert({name = item, count = 1}) then
			-- if item == "radar" then
			-- 	game.print("[ASSIGN FAILED] Tick " .. game.tick .. ": Spider " .. spider.unit_number .. " cannot insert '" .. item .. "' - trunk full of other items")
			-- end
			return false
		end
		
		-- if item == "radar" then
		-- 	game.print("[ASSIGN DEBUG] Tick " .. game.tick .. ": Validating trunk capacity for spider " .. spider.unit_number .. 
		-- 		" - item=" .. item .. ", already_has=" .. already_has .. ", stack_size=" .. stack_size .. 
		-- 		", space_in_existing=" .. space_in_existing .. ", empty_slots=" .. empty_slots .. 
		-- 		", max_can_carry=" .. max_can_carry .. ", can_provide=" .. can_provide)
		-- end
		
		-- Limit can_provide to what the spider can actually carry
		if can_provide > max_can_carry then
			-- if item == "radar" then
			-- 	game.print("[ASSIGN DEBUG] Tick " .. game.tick .. ": Limiting can_provide from " .. can_provide .. " to " .. max_can_carry)
			-- end
			can_provide = max_can_carry
		end
		
		-- If spider can't carry anything, don't assign
		if can_provide <= 0 then
			-- if item == "radar" then
			-- 	game.print("[ASSIGN FAILED] Tick " .. game.tick .. ": Spider " .. spider.unit_number .. " can't carry anything (max_can_carry=" .. max_can_carry .. ")")
			-- end
			return false
		end
		
		-- if item == "radar" then
		-- 	game.print("[ASSIGN DEBUG] Tick " .. game.tick .. ": Trunk capacity validation passed, final can_provide=" .. can_provide)
		-- end
	end
	
	-- Track allocated_items for custom provider chests and requester excess providers
	-- TODO: Robot chest support removed - previously skipped allocation for robot chests
	if not provider_data.allocated_items then
		provider_data.allocated_items = {}
	end
	provider_data.allocated_items[item] = (provider_data.allocated_items[item] or 0) + can_provide
	
	if not requester_data.incoming_items then
		requester_data.incoming_items = {}
	end
	local incoming_before = requester_data.incoming_items[item] or 0
	requester_data.incoming_items[item] = incoming_before + can_provide
	requester_data.real_amount = amount - can_provide
	
	-- Verify the update was applied to the actual requester_data (not just temp_requester)
	local actual_requester_data = storage.requesters[requester.unit_number]
	local actual_incoming_after = 0
	if actual_requester_data and actual_requester_data.incoming_items then
		actual_incoming_after = actual_requester_data.incoming_items[item] or 0
	end
	
	-- game.print("[ASSIGN_SPIDER] Tick " .. game.tick .. ": Updated tracking - SPIDER_ID=" .. spider.unit_number .. 
	-- 	", item=" .. item .. 
	-- 	", requester=" .. requester.unit_number .. 
	-- 	", incoming_before=" .. incoming_before .. 
	-- 	", can_provide=" .. can_provide .. 
	-- 	", incoming_after=" .. requester_data.incoming_items[item] .. 
	-- 	", actual_storage_incoming=" .. actual_incoming_after .. 
	-- 	", real_amount_before=" .. amount .. 
	-- 	", real_amount_after=" .. requester_data.real_amount .. 
	-- 	", same_reference=" .. tostring(requester_data.incoming_items == (actual_requester_data and actual_requester_data.incoming_items or nil)))
	
	-- Update spider data
	spider_data.status = constants.picking_up
	spider_data.requester_target = requester
	spider_data.provider_target = provider
	spider_data.payload_item = item
	spider_data.payload_item_count = can_provide
	
	
	-- Set destination using pathing
	local pathing_success = pathing.set_smart_destination(spider, provider.position, provider)
	
	if not pathing_success then
		-- Pathfinding request failed - cancel the assignment
		-- Revert spider status
		spider_data.status = constants.idle
		spider_data.requester_target = nil
		spider_data.provider_target = nil
		spider_data.payload_item = nil
		spider_data.payload_item_count = 0
		-- Revert allocation
		-- TODO: Robot chest support removed - previously skipped allocation revert for robot chests
		if provider_data.allocated_items then
			provider_data.allocated_items[item] = (provider_data.allocated_items[item] or 0) - can_provide
			if provider_data.allocated_items[item] <= 0 then
				provider_data.allocated_items[item] = nil
			end
		end
		-- Revert incoming items
		requester_data.incoming_items[item] = (requester_data.incoming_items[item] or 0) - can_provide
		if requester_data.incoming_items[item] <= 0 then
			requester_data.incoming_items[item] = nil
		end
		-- Don't remove spider from list, let it be available for next attempt
		return false
	else
		-- Draw status text after successful pathing
		rendering.draw_status_text(spider, spider_data)
	end
	
	-- Check for additional items from the same requester (or nearby requesters) that are at 85%+ filled
	-- This allows spiders to pick up remaining amounts on the same trip
	logistics.add_nearby_items_to_delivery(spider, spider_data, requester, requester_data, item, can_provide, provider_data)
	

	remove(spiders, spider_index)
	
	-- game.print("[ASSIGN_SPIDER] Tick " .. game.tick .. ": Assignment complete - SPIDER_ID=" .. spider.unit_number .. 
	-- 	", item=" .. item .. 
	-- 	", amount=" .. can_provide .. 
	-- 	", requester=" .. requester.unit_number .. 
	-- 	", provider=" .. provider.unit_number)
	
	return true
end

-- Helper function to check how much a provider can supply for an item
function logistics.can_provider_supply(provider_data, item_name)
	local provider = provider_data.entity
	if not provider or not provider.valid then return 0 end
	
	local item_count = 0
	local allocated = 0
	
	-- TODO: Robot chest support removed - previously checked provider_data.is_robot_chest
	if provider_data.is_requester_excess then
		-- For requester excess providers, use the contains field which has the excess amount
		if provider_data.contains and provider_data.contains[item_name] then
			item_count = provider_data.contains[item_name]
		else
			item_count = 0
		end
		if provider_data.allocated_items then
			allocated = provider_data.allocated_items[item_name] or 0
		end
	else
		-- Use cached data exclusively (cache refreshed by refresh_inventory_caches())
		if provider_data.cached_contents then
			item_count = provider_data.cached_contents[item_name] or 0
		else
			item_count = 0
		end
		if provider_data.allocated_items then
			allocated = provider_data.allocated_items[item_name] or 0
		end
	end
	
	return math.max(0, item_count - allocated)
end

-- Find additional items from the same requester (or nearby) that are at 85%+ filled
-- and add them to the spider's delivery if there's space
function logistics.add_nearby_items_to_delivery(spider, spider_data, primary_requester, primary_requester_data, primary_item, primary_amount, provider_data)
	local trunk = spider.get_inventory(defines.inventory.spider_trunk)
	if not trunk then return end
	
	-- Check same requester for other items at 85%+ filled
	if primary_requester_data.requested_items then
		for item_name, item_data in pairs(primary_requester_data.requested_items) do
			-- Skip the primary item we're already delivering
			if item_name ~= primary_item then
				local requested_count = type(item_data) == "number" and item_data or (item_data.count or 0)
				if requested_count > 0 then
					-- Use cached data exclusively (cache refreshed by refresh_inventory_caches())
					local current_amount = 0
					if primary_requester_data.cached_item_counts then
						current_amount = primary_requester_data.cached_item_counts[item_name] or 0
					end
					local incoming = (primary_requester_data.incoming_items and primary_requester_data.incoming_items[item_name]) or 0
					local percentage_filled = (current_amount + incoming) / requested_count
					
					-- If at 85%+ filled, add remaining amount to delivery
					if percentage_filled >= 0.85 then
						local remaining_needed = requested_count - current_amount - incoming
						if remaining_needed > 0 then
							-- Check if spider can carry this item
							if trunk.can_insert({name = item_name, count = 1}) then
								-- Try to find a provider for this item
								local network = beacon_assignment.spidertron_network(primary_requester)
								if network then
									local providers = logistics.providers()
									local providers_for_network = providers[network.network_key]
									if providers_for_network then
										-- Find best provider for this additional item (prefer same provider if it has the item)
										local best_provider_entity = nil
										local best_provider_data = nil
										local best_amount = 0
										
										-- First check if the primary provider has this item
										if provider_data.contains and provider_data.contains[item_name] then
											local can_provide = logistics.can_provider_supply(provider_data, item_name)
											if can_provide > 0 then
												best_provider_entity = provider_data.entity
												best_provider_data = provider_data
												best_amount = math.min(can_provide, remaining_needed)
											end
										end
										
										-- If primary provider doesn't have it, find another provider
										if not best_provider_entity then
											for _, provider_data_check in ipairs(providers_for_network) do
												local provider_entity = provider_data_check.entity
												if provider_entity and provider_entity.valid then
													local can_provide = logistics.can_provider_supply(provider_data_check, item_name)
													if can_provide > 0 then
														local distance = utils.distance(provider_entity.position, primary_requester.position)
														-- Prefer providers close to the primary requester
														if not best_provider_entity or distance < utils.distance(best_provider_entity.position, primary_requester.position) then
															best_provider_entity = provider_entity
															best_provider_data = provider_data_check
															best_amount = math.min(can_provide, remaining_needed)
														end
													end
												end
											end
										end
										
										if best_provider_entity and best_provider_data and best_amount > 0 then
											-- Mark as incoming
											if not primary_requester_data.incoming_items then
												primary_requester_data.incoming_items = {}
											end
											primary_requester_data.incoming_items[item_name] = (primary_requester_data.incoming_items[item_name] or 0) + best_amount
											
											-- Allocate from provider
											-- TODO: Robot chest support removed - previously skipped allocation for robot chests
											if not best_provider_data.allocated_items then
												best_provider_data.allocated_items = {}
											end
											best_provider_data.allocated_items[item_name] = (best_provider_data.allocated_items[item_name] or 0) + best_amount
											
											-- Store additional items in spider_data (we'll need to handle multiple items in journey.lua)
											if not spider_data.additional_items then
												spider_data.additional_items = {}
											end
											table.insert(spider_data.additional_items, {
												item = item_name,
												amount = best_amount,
												requester = primary_requester,
												provider = best_provider_entity
											})
										end
									end
								end
							end
						end
					end
				end
			end
		end
	end
end

-- Check if assignment should be delayed to batch more items
function logistics.should_delay_assignment(requester_data, provider_data, can_provide, real_amount, percentage_filled)
	-- Check priority/urgency - if requester is critical, never delay
	if percentage_filled < constants.critical_fill_threshold then
		return false  -- Urgent request, don't delay
	end
	
	-- Check availability ratio
	local availability_ratio = can_provide / real_amount
	if availability_ratio < constants.min_availability_ratio then
		-- Low availability, should delay
		-- But also check distance to see if we should wait longer
		local provider = provider_data.entity
		local requester = requester_data.entity
		local distance = utils.distance(provider.position, requester.position)
		
		-- Calculate minimum items needed based on distance
		-- Longer distances = need more items to justify the trip
		-- Scale applies to all distances, with base as a reference point
		local min_items_for_distance
		if distance > constants.distance_delay_base then
			-- For long distances: use full scaling from base
			local extra_distance = distance - constants.distance_delay_base
			min_items_for_distance = 1 + (extra_distance * constants.distance_delay_multiplier)
		else
			-- For short distances: use reduced scaling to ensure delays still happen
			-- At distance 0: need 1 item, at distance 200: need ~11 items
			min_items_for_distance = 1 + (distance * constants.distance_delay_multiplier * 0.5)
		end
		
		-- Delay if we have fewer items than the distance-based minimum
		if can_provide < min_items_for_distance then
			logging.debug("Assignment", "Delaying assignment: can_provide=" .. can_provide .. 
				", real_amount=" .. real_amount .. ", ratio=" .. string.format("%.2f", availability_ratio) ..
				", distance=" .. string.format("%.1f", distance) .. 
				", min_items=" .. string.format("%.1f", min_items_for_distance))
			return true
		end
	end
	
	return false  -- Don't delay
end

-- Assign spider with a multi-stop route
function logistics.assign_spider_with_route(spiders, route, route_type)
	if not route or #route == 0 then
		return false
	end
	
	-- Find best spider for the route (closest to first stop)
	local first_stop = route[1]
	if not first_stop or not first_stop.entity or not first_stop.entity.valid then
		return false
	end
	
	local first_position = first_stop.entity.position
	local spider
	local best_distance
	local spider_index
	local remove = table.remove
	
	for i, candidate in ipairs(spiders) do
		-- Check if spider can handle the route (basic inventory check)
		local trunk = candidate.get_inventory(defines.inventory.spider_trunk)
		if trunk then
			local candidate_position = candidate.position
			local dist = utils.distance(first_position.x, first_position.y, candidate_position.x, candidate_position.y)
			
			if not spider or best_distance > dist then
				spider = candidate
				best_distance = dist
				spider_index = i
			end
		end
	end
	
	if not spider then
		return false
	end
	
	local spider_data = storage.spiders[spider.unit_number]
	
	-- Allocate items from providers and track incoming items for requesters
	-- TODO: Robot chest support removed - previously skipped allocation for robot chests
	for _, stop in ipairs(route) do
		if stop.type == "pickup" and stop.entity and stop.entity.valid then
			local provider_data = storage.providers[stop.entity.unit_number]
			if provider_data then
				if not provider_data.allocated_items then
					provider_data.allocated_items = {}
				end
				provider_data.allocated_items[stop.item] = (provider_data.allocated_items[stop.item] or 0) + stop.amount
			end
		elseif stop.type == "delivery" and stop.entity and stop.entity.valid then
			local requester_data = storage.requesters[stop.entity.unit_number]
			if requester_data then
				if not requester_data.incoming_items then
					requester_data.incoming_items = {}
				end
				if stop.item then
					-- Single item delivery
					requester_data.incoming_items[stop.item] = (requester_data.incoming_items[stop.item] or 0) + stop.amount
				elseif stop.items then
					-- Multi-item delivery
					for item, amount in pairs(stop.items) do
						requester_data.incoming_items[item] = (requester_data.incoming_items[item] or 0) + amount
					end
				end
			end
		end
	end
	
	-- Update spider data with route
	spider_data.status = constants.picking_up
	spider_data.route = route
	spider_data.route_type = route_type
	spider_data.current_route_index = 1
	
	-- Set initial destination to first stop
	local first_stop_entity = route[1].entity
	spider_data.provider_target = first_stop_entity  -- Will be updated as route progresses
	spider_data.requester_target = nil  -- Will be set when we reach delivery stops
	
	-- Set payload info from first pickup
	if route[1].type == "pickup" then
		spider_data.payload_item = route[1].item
		spider_data.payload_item_count = route[1].amount
	else
	end
	
	-- Set destination using pathing
	local pathing_success = pathing.set_smart_destination(spider, first_stop_entity.position, first_stop_entity)
	
	if not pathing_success then
		-- Revert allocations
		-- TODO: Robot chest support removed - previously skipped allocation revert for robot chests
		for _, stop in ipairs(route) do
			if stop.type == "pickup" and stop.entity and stop.entity.valid then
				local provider_data = storage.providers[stop.entity.unit_number]
				if provider_data and provider_data.allocated_items then
					provider_data.allocated_items[stop.item] = (provider_data.allocated_items[stop.item] or 0) - stop.amount
					if provider_data.allocated_items[stop.item] <= 0 then
						provider_data.allocated_items[stop.item] = nil
					end
				end
			elseif stop.type == "delivery" and stop.entity and stop.entity.valid then
				local requester_data = storage.requesters[stop.entity.unit_number]
				if requester_data and requester_data.incoming_items then
					if stop.item then
						requester_data.incoming_items[stop.item] = (requester_data.incoming_items[stop.item] or 0) - stop.amount
						if requester_data.incoming_items[stop.item] <= 0 then
							requester_data.incoming_items[stop.item] = nil
						end
					elseif stop.items then
						for item, amount in pairs(stop.items) do
							requester_data.incoming_items[item] = (requester_data.incoming_items[item] or 0) - amount
							if requester_data.incoming_items[item] <= 0 then
								requester_data.incoming_items[item] = nil
							end
						end
					end
				end
			end
		end
		-- Revert spider status
		spider_data.status = constants.idle
		spider_data.route = nil
		spider_data.route_type = nil
		spider_data.current_route_index = nil
		spider_data.provider_target = nil
		spider_data.requester_target = nil
		spider_data.payload_item = nil
		spider_data.payload_item_count = 0
		return false
	else
		-- Draw status text after successful pathing
		rendering.draw_status_text(spider, spider_data)
	end
	
	remove(spiders, spider_index)
	return true
end

return logistics


