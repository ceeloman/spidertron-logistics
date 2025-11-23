-- Debug commands for spidertron logistics

local constants = require('lib.constants')
local beacon_assignment = require('lib.beacon_assignment')
local logistics = require('lib.logistics')

local debug_commands = {}

function debug_commands.register_all()
	-- Command to show active spiders
	local success, err = pcall(function()
		commands.add_command("show_active_spiders", {"command.show-active-spiders-help"}, function(event)
		local player = game.get_player(event.player_index)
		if not player or not player.valid then return end
		
		local spider_count = 0
		local active_count = 0
		local inactive_count = 0
		local no_beacon_count = 0
		local spider_list = {}
		
		for unit_number, spider_data in pairs(storage.spiders) do
			local spider = spider_data.entity
			if spider and spider.valid then
				spider_count = spider_count + 1
				local network = beacon_assignment.spidertron_network(spider)
				local has_network = network ~= nil
				local is_active = spider_data.active == true
				
				if not has_network then
					no_beacon_count = no_beacon_count + 1
				elseif is_active then
					active_count = active_count + 1
				else
					inactive_count = inactive_count + 1
				end
				
				table.insert(spider_list, {
					unit_number = unit_number,
					position = spider.position,
					active = is_active,
					has_network = has_network,
					status = spider_data.status,
					has_driver = spider.get_driver() ~= nil
				})
			end
		end
		
		-- Print summary
		player.print({"command.spider-summary", spider_count, active_count, inactive_count, no_beacon_count})
		
		-- Print details for each spider
		if #spider_list > 0 then
			player.print("--- Spider Details ---")
			for _, info in ipairs(spider_list) do
				local status_text = ""
				if info.status == constants.idle then
					status_text = "idle"
				elseif info.status == constants.picking_up then
					status_text = "picking up"
				elseif info.status == constants.dropping_off then
					status_text = "dropping off"
				end
				
				local active_text = info.active and "ACTIVE" or "INACTIVE"
				local network_text = info.has_network and "connected" or "NO BEACON"
				local driver_text = info.has_driver and " (has driver)" or ""
				
				player.print(string.format("Spider #%d at (%.1f, %.1f): %s, %s, %s%s", 
					info.unit_number, 
					info.position.x, 
					info.position.y,
					active_text,
					network_text,
					status_text,
					driver_text))
			end
		else
			player.print("No spiders registered.")
		end
		end)
	end)
	if not success then
		-- Command already exists, skip registration
	end

	-- Command to show requester chests status
	success, err = pcall(function()
		commands.add_command("show_requesters", "Shows status of all requester chests", function(event)
		local player = game.get_player(event.player_index)
		if not player or not player.valid then return end
		
		local count = 0
		player.print("=== Requester Chests ===")
		
		for unit_number, requester_data in pairs(storage.requesters) do
			local requester = requester_data.entity
			if requester and requester.valid then
				count = count + 1
				local item = requester_data.requested_item or "none"
				local request_size = requester_data.request_size or 0
				local already_had = item ~= "none" and requester.get_item_count(item) or 0
				local incoming = item ~= "none" and (requester_data.incoming_items[item] or 0) or 0
				local real_amount = request_size - incoming - already_had
				local beacon_owner = requester_data.beacon_owner or "none"
				local network = beacon_assignment.spidertron_network(requester)
				local has_network = network ~= nil
				
				player.print(string.format("Requester #%d at (%.1f, %.1f):", unit_number, requester.position.x, requester.position.y))
				player.print(string.format("  Item: %s | Request: %d | Have: %d | Incoming: %d | Need: %d", 
					item, request_size, already_had, incoming, real_amount))
				player.print(string.format("  Beacon: %s | Network: %s", 
					tostring(beacon_owner), has_network and "YES" or "NO"))
			end
		end
		
		if count == 0 then
			player.print("No requester chests found.")
		else
			player.print(string.format("Total requesters: %d", count))
		end
		end)
	end)
	if not success then
		-- Command already exists, skip registration
	end

	-- Command to show provider chests status
	success, err = pcall(function()
		commands.add_command("show_providers", "Shows status of all provider chests", function(event)
		local player = game.get_player(event.player_index)
		if not player or not player.valid then return end
		
		local count = 0
		player.print("=== Provider Chests ===")
		
		for unit_number, provider_data in pairs(storage.providers) do
			local provider = provider_data.entity
			if provider and provider.valid then
				count = count + 1
				local inventory = provider.get_inventory(defines.inventory.chest)
				local contents = inventory.get_contents()
				local item_count = 0
				local items_list = {}
				
				if contents then
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
							item_count = item_count + 1
							local allocated = provider_data.allocated_items[item_name] or 0
							table.insert(items_list, string.format("%s: %d (allocated: %d)", item_name, total, allocated))
						end
					end
				end
				
				local beacon_owner = provider_data.beacon_owner or "none"
				local network = beacon_assignment.spidertron_network(provider)
				local has_network = network ~= nil
				
				player.print(string.format("Provider #%d at (%.1f, %.1f):", unit_number, provider.position.x, provider.position.y))
				player.print(string.format("  Items: %d types | Beacon: %s | Network: %s", 
					item_count, tostring(beacon_owner), has_network and "YES" or "NO"))
				if #items_list > 0 then
					for _, item_str in ipairs(items_list) do
						player.print("  " .. item_str)
					end
				end
			end
		end
		
		if count == 0 then
			player.print("No provider chests found.")
		else
			player.print(string.format("Total providers: %d", count))
		end
		end)
	end)
	if not success then
		-- Command already exists, skip registration
	end

	-- Command to show beacons and assignments
	success, err = pcall(function()
		commands.add_command("show_beacons", "Shows all beacons and their assigned chests", function(event)
		local player = game.get_player(event.player_index)
		if not player or not player.valid then return end
		
		local count = 0
		player.print("=== Beacons ===")
		
		for unit_number, beacon_data in pairs(storage.beacons) do
			local beacon = beacon_data.entity
			if beacon and beacon.valid then
				count = count + 1
				local assigned_chests = beacon_data.assigned_chests or {}
				local requester_count = 0
				local provider_count = 0
				
				for _, chest_unit_number in ipairs(assigned_chests) do
					if storage.requesters[chest_unit_number] then
						requester_count = requester_count + 1
					elseif storage.providers[chest_unit_number] then
						provider_count = provider_count + 1
					end
				end
				
				player.print(string.format("Beacon #%d at (%.1f, %.1f):", unit_number, beacon.position.x, beacon.position.y))
				player.print(string.format("  Assigned: %d requesters, %d providers (total: %d)", 
					requester_count, provider_count, #assigned_chests))
			end
		end
		
		if count == 0 then
			player.print("No beacons found.")
		else
			player.print(string.format("Total beacons: %d", count))
		end
		end)
	end)
	if not success then
		-- Command already exists, skip registration
	end

	-- Command to show task assignment status
	success, err = pcall(function()
		commands.add_command("show_tasks", "Shows available tasks and spider assignments", function(event)
		local player = game.get_player(event.player_index)
		if not player or not player.valid then return end
		
		player.print("=== Task Assignment Status ===")
		
		-- Get current state
		local requests = logistics.requesters()
		local spiders_list = logistics.spiders()
		local providers_list = logistics.providers()
		
		-- Show available requests
		local total_requests = 0
		for network_key, requesters in pairs(requests) do
			total_requests = total_requests + #requesters
			player.print(string.format("Network %s: %d requesters", tostring(network_key), #requesters))
			for _, requester_data in ipairs(requesters) do
				local item = requester_data.requested_item or "none"
				local real_amount = requester_data.real_amount or 0
				player.print(string.format("  - %s: needs %d", item, real_amount))
			end
		end
		
		-- Show available providers
		local total_providers = 0
		for network_key, providers_for_network in pairs(providers_list) do
			total_providers = total_providers + #providers_for_network
			player.print(string.format("Network %s: %d providers", tostring(network_key), #providers_for_network))
			for _, provider_data in ipairs(providers_for_network) do
				local provider = provider_data.entity
				if provider and provider.valid then
					local chest_type = provider_data.is_robot_chest and "ROBOT" or "CUSTOM"
					local items_count = 0
					if provider_data.contains then
						for _ in pairs(provider_data.contains) do
							items_count = items_count + 1
						end
					end
					player.print(string.format("  - %s chest at (%.1f, %.1f): %d item types", 
						chest_type, provider.position.x, provider.position.y, items_count))
				end
			end
		end
		
		-- Show available spiders
		local total_spiders = 0
		for network_key, spiders_for_network in pairs(spiders_list) do
			total_spiders = total_spiders + #spiders_for_network
			player.print(string.format("Network %s: %d available spiders", tostring(network_key), #spiders_for_network))
		end
		
		-- Show assigned spiders
		local assigned_count = 0
		for unit_number, spider_data in pairs(storage.spiders) do
			if spider_data.status ~= constants.idle then
				assigned_count = assigned_count + 1
				local spider = spider_data.entity
				if spider and spider.valid then
					local status_text = ""
					if spider_data.status == constants.picking_up then
						status_text = "picking up"
					elseif spider_data.status == constants.dropping_off then
						status_text = "dropping off"
					end
					player.print(string.format("Spider #%d: %s %s x%d", 
						unit_number, status_text, spider_data.payload_item or "?", spider_data.payload_item_count or 0))
				end
			end
		end
		
		player.print(string.format("Summary: %d requests, %d providers, %d available spiders, %d assigned", 
			total_requests, total_providers, total_spiders, assigned_count))
		end)
	end)
	if not success then
		-- Command already exists, skip registration
	end

	-- Command to show general status
	success, err = pcall(function()
		commands.add_command("show_status", "Shows general logistics system status", function(event)
		local player = game.get_player(event.player_index)
		if not player or not player.valid then return end
		
		player.print("=== Spidertron Logistics Status ===")
		
		local spider_count = 0
		local active_spiders = 0
		local idle_spiders = 0
		local working_spiders = 0
		
		for unit_number, spider_data in pairs(storage.spiders) do
			local spider = spider_data.entity
			if spider and spider.valid then
				spider_count = spider_count + 1
				if spider_data.active then
					active_spiders = active_spiders + 1
				end
				if spider_data.status == constants.idle then
					idle_spiders = idle_spiders + 1
				else
					working_spiders = working_spiders + 1
				end
			end
		end
		
		local requester_count = 0
		local requester_with_requests = 0
		for unit_number, requester_data in pairs(storage.requesters) do
			if requester_data.entity and requester_data.entity.valid then
				requester_count = requester_count + 1
				if requester_data.requested_item and requester_data.request_size > 0 then
					requester_with_requests = requester_with_requests + 1
				end
			end
		end
		
		local provider_count = 0
		local provider_with_items = 0
		for unit_number, provider_data in pairs(storage.providers) do
			if provider_data.entity and provider_data.entity.valid then
				provider_count = provider_count + 1
				local inventory = provider_data.entity.get_inventory(defines.inventory.chest)
				if inventory and next(inventory.get_contents()) then
					provider_with_items = provider_with_items + 1
				end
			end
		end
		
		local beacon_count = 0
		for unit_number, beacon_data in pairs(storage.beacons) do
			if beacon_data.entity and beacon_data.entity.valid then
				beacon_count = beacon_count + 1
			end
		end
		
		player.print(string.format("Spiders: %d total (%d active, %d idle, %d working)", 
			spider_count, active_spiders, idle_spiders, working_spiders))
		player.print(string.format("Requesters: %d total (%d with requests)", 
			requester_count, requester_with_requests))
		player.print(string.format("Providers: %d total (%d with items)", 
			provider_count, provider_with_items))
		player.print(string.format("Beacons: %d", beacon_count))
		end)
	end)
	if not success then
		-- Command already exists, skip registration
	end
end

	return debug_commands

