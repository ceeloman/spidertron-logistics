-- Main control file for spidertron logistics mod
-- Modularized structure with separate modules for different concerns

-- Load modules
local constants = require('lib.constants')
local utils = require('lib.utils')
local beacon_assignment = require('lib.beacon_assignment')
local registration = require('lib.registration')
local gui = require('lib.gui')
local logistics = require('lib.logistics')
local journey = require('lib.journey')
local rendering = require('lib.rendering')
local debug_commands = require('lib.commands')
local pathing = require('lib.pathing')
local logging = require('lib.logging')

-- Local references for performance
local min = math.min
local tostring = tostring

-- GUI Event Handlers
script.on_event(defines.events.on_gui_opened, function(event)
	-- Close any open item selector modals when opening a new GUI
	if event.gui_type == defines.gui_type.entity then
		for _, gui_data in pairs(storage.requester_guis) do
			gui.close_item_selector_gui(gui_data)
		end
	end
	
	if event.gui_type ~= defines.gui_type.entity then return end
	local entity = event.entity
	if entity == nil or not entity.valid then return end
	
	-- Handle requester chest GUI
	if entity.name == constants.spidertron_requester_chest then
		local player = game.get_player(event.player_index)
		local requester_data = storage.requesters[entity.unit_number]
		if not requester_data then return end
		
		-- Clean up old GUIs first
		gui.cleanup_old_guis(event.player_index)
		
		-- Migrate old format if needed
		if not requester_data.requested_items then
			requester_data.requested_items = {}
			if requester_data.requested_item then
				requester_data.requested_items[requester_data.requested_item] = requester_data.request_size or 0
			end
		end
		
		-- Ensure requester has beacon assignment
		if not requester_data.beacon_owner then
			-- logging.warn("Beacon", "Requester opened but has no beacon_owner, assigning...")
			beacon_assignment.assign_chest_to_nearest_beacon(entity)
			if requester_data.beacon_owner then
				-- logging.info("Beacon", "Assigned requester to beacon " .. requester_data.beacon_owner)
			else
				logging.error("Beacon", "Failed to assign requester to any beacon!")
			end
		else
			-- Verify beacon still exists and is valid
			local beacon_data = storage.beacons[requester_data.beacon_owner]
			if not beacon_data or not beacon_data.entity or not beacon_data.entity.valid then
				-- logging.warn("Beacon", "Requester's beacon " .. requester_data.beacon_owner .. " is invalid, reassigning...")
				requester_data.beacon_owner = nil
				beacon_assignment.assign_chest_to_nearest_beacon(entity)
				if requester_data.beacon_owner then
					-- logging.info("Beacon", "Reassigned requester to beacon " .. requester_data.beacon_owner)
				else
					logging.error("Beacon", "Failed to reassign requester to any beacon!")
				end
			end
		end
		
		-- Ensure incoming_items is initialized
		if not requester_data.incoming_items then
			requester_data.incoming_items = {}
		end
		
		local gui_data = gui.requester_gui(event.player_index)
		gui_data.last_opened_requester = requester_data
		gui.update_requester_gui(gui_data, requester_data)
		return
	end
	
	-- Handle spidertron GUI
	if entity.type == 'spider-vehicle' and entity.prototype.order ~= 'z[programmable]' then
		local player = game.get_player(event.player_index)
		if not player then return end
		
		-- Check if spider has trunk inventory
		local trunk = entity.get_inventory(defines.inventory.spider_trunk)
		if not trunk then
			-- No trunk, don't show GUI
			return
		end
		
		-- Check if spider name contains "constructron" (case-insensitive)
		local spider_name = entity.name:lower()
		if spider_name:find("constructron") then
			-- Has "constructron" in name, don't show GUI
			return
		end
		
		local spider_data = storage.spiders[entity.unit_number]
		if not spider_data then
			-- Register spider if not already registered
			registration.register_spider(entity)
			spider_data = storage.spiders[entity.unit_number]
		end
		if spider_data then
			-- Ensure active field exists
			if spider_data.active == nil then
				spider_data.active = false
			end
			-- Add toggle button
			gui.add_spidertron_toggle_button(player, entity)
		end
		return
	end
end)

script.on_event(defines.events.on_gui_closed, function(event)
	if event.gui_type == defines.gui_type.entity then
		local player = game.get_player(event.player_index)
		if player and player.valid then
			-- Clean up spidertron toggle button when GUI is closed
			if player.gui.relative["spidertron_logistics_toggle_frame"] then
				player.gui.relative["spidertron_logistics_toggle_frame"].destroy()
			end
		end
	end
end)

script.on_event(defines.events.on_gui_switch_state_changed, function(event)
	local element = event.element
	if not element or not element.valid then return end
	
	-- Handle spidertron toggle switch
	if element.name == "spidertron_logistics_toggle_button" then
		local player = game.get_player(event.player_index)
		if not player then return end
		
		local vehicle = player.opened
		if vehicle and vehicle.valid and vehicle.type == 'spider-vehicle' then
			local spider_data = storage.spiders[vehicle.unit_number]
			if spider_data then
				-- Update active state based on switch position
				-- "left" = active, "right" = inactive
				spider_data.active = (element.switch_state == "left")
				return
			end
		end
	end
end)

script.on_event(defines.events.on_gui_elem_changed, function(event)
	local element = event.element
	if not element or not element.valid then return end
	
	-- Handle item chooser selection
	if element.name == 'spidertron_item_chooser' then
		local player = game.get_player(event.player_index)
		for _, gui_data in pairs(storage.requester_guis) do
			if gui_data and gui_data.item_selector_item_chooser and gui_data.item_selector_item_chooser == element then
				local item_name = element.elem_value
				gui_data.item_selector_selected_item = item_name
				
				-- Update slider and label to use stack size (1x stack) when item is selected
				if item_name then
					-- Get stack size from item prototype using Factorio 2.0 API
					local stack_size = 1
					
					-- Use prototypes.item[item_name] in Factorio 2.0
					local success, prototype = pcall(function() 
						return prototypes.item[item_name] 
					end)
					
					if success and prototype and prototype.stack_size then
						stack_size = prototype.stack_size
					else
						-- Fallback: try to get from player's inventory
						if player and player.valid then
							local main_inventory = player.get_main_inventory()
							if main_inventory then
								for i = 1, #main_inventory do
									local stack = main_inventory[i]
									if stack and stack.valid_for_read and stack.name == item_name then
										stack_size = stack.prototype.stack_size or 1
										break
									end
								end
							end
						end
					end
					
					-- Ensure we have at least 1 (stack_size should already return the full stack size)
					if stack_size < 1 then stack_size = 1 end
					
					if gui_data.item_selector_slider and gui_data.item_selector_slider.valid then
						-- Clamp stack size to slider's valid range
						local min_val = gui_data.item_selector_slider.minimum_value or 0
						local max_val = gui_data.item_selector_slider.maximum_value or 1000
						local clamped_value = math.max(min_val, math.min(max_val, stack_size))
						
						-- Set the slider value to stack size
						gui_data.item_selector_slider.slider_value = clamped_value
						
						-- Update the label to match the actual value set
						local actual_value = math.floor(gui_data.item_selector_slider.slider_value)
						if gui_data.item_selector_quantity_label and gui_data.item_selector_quantity_label.valid then
							gui_data.item_selector_quantity_label.caption = tostring(actual_value)
						end
					end
				end
				return
			end
		end
	end
end)

script.on_event(defines.events.on_gui_text_changed, function(event)
	-- Not used with choose-elem-button approach
end)

script.on_event(defines.events.on_gui_value_changed, function(event)
	local element = event.element
	if not element or not element.valid then return end
	
	-- Handle quantity slider changes in item selector
	if element.name == 'spidertron_quantity_slider' then
		for _, gui_data in pairs(storage.requester_guis) do
			if gui_data and gui_data.item_selector_slider and gui_data.item_selector_slider == element then
				local value = math.floor(element.slider_value)
				if gui_data.item_selector_quantity_label and gui_data.item_selector_quantity_label.valid then
					gui_data.item_selector_quantity_label.caption = tostring(value)
				end
				return
			end
		end
	end
end)

script.on_event(defines.events.on_gui_click, function(event)
	local element = event.element
	if not element or not element.valid then return end
	
	local player = game.get_player(event.player_index)
	local player_index = event.player_index
	
	-- Handle item selector modal buttons
	for _, gui_data in pairs(storage.requester_guis) do
		if gui_data and gui_data.item_selector_gui and gui_data.item_selector_gui.valid then
			-- Check if clicked element is in the modal
			local clicked_in_modal = false
			local parent = element
			while parent do
				if parent == gui_data.item_selector_gui then
					clicked_in_modal = true
					break
				end
				parent = parent.parent
			end
			
			if clicked_in_modal then
				-- Handle confirm button
				if element.name == 'spidertron_confirm_request' then
					local slot_index = gui_data.item_selector_slot_index
					local selected_item = gui_data.item_selector_selected_item
					local quantity = 0
					
					if gui_data.item_selector_slider and gui_data.item_selector_slider.valid then
						quantity = math.floor(gui_data.item_selector_slider.slider_value)
					end
					
					if selected_item and quantity > 0 and gui_data.last_opened_requester then
						local requester_data = gui_data.last_opened_requester
						local requester = requester_data.entity
						
						-- logging.info("GUI", "Setting request: " .. selected_item .. " x" .. quantity .. " for requester at (" .. math.floor(requester.position.x) .. "," .. math.floor(requester.position.y) .. ")")
						
						if not requester_data.requested_items then
							requester_data.requested_items = {}
						end
						
						-- Remove old item from this slot position
						local item_list = {}
						for item_name, count in pairs(requester_data.requested_items) do
							if count > 0 and item_name and item_name ~= '' then
								table.insert(item_list, {name = item_name, count = count})
							end
						end
						table.sort(item_list, function(a, b) return a.name < b.name end)
						
						if slot_index <= #item_list then
							requester_data.requested_items[item_list[slot_index].name] = nil
						end
						
						-- Add new item
						requester_data.requested_items[selected_item] = quantity
						
						-- Ensure requester has valid beacon assignment
						if requester and requester.valid then
							if not requester_data.beacon_owner then
								-- logging.warn("Beacon", "Requester has no beacon_owner, assigning to nearest...")
								beacon_assignment.assign_chest_to_nearest_beacon(requester)
								if requester_data.beacon_owner then
									-- logging.info("Beacon", "Assigned requester to beacon " .. requester_data.beacon_owner)
								else
									logging.error("Beacon", "Failed to assign requester to any beacon!")
								end
							else
								-- Verify beacon still exists and is valid
								local beacon_data = storage.beacons[requester_data.beacon_owner]
								if not beacon_data or not beacon_data.entity or not beacon_data.entity.valid then
									-- logging.warn("Beacon", "Requester's beacon " .. requester_data.beacon_owner .. " is invalid, reassigning...")
									requester_data.beacon_owner = nil
									beacon_assignment.assign_chest_to_nearest_beacon(requester)
									if requester_data.beacon_owner then
										-- logging.info("Beacon", "Reassigned requester to beacon " .. requester_data.beacon_owner)
									else
										logging.error("Beacon", "Failed to reassign requester to any beacon!")
									end
								else
									-- logging.debug("Beacon", "Requester beacon " .. requester_data.beacon_owner .. " is valid")
								end
							end
						end
						
						-- Ensure incoming_items is initialized
						if not requester_data.incoming_items then
							requester_data.incoming_items = {}
						end
						
						-- Update GUI
						gui.update_requester_gui(gui_data, requester_data)
					end
					
					gui.close_item_selector_gui(gui_data)
					return
				end
				
				-- Handle cancel button
				if element.name == 'spidertron_cancel_request' then
					gui.close_item_selector_gui(gui_data)
					return
				end
			end
		end
	end
	
	-- Handle slot button clicks (open item selector modal)
	for _, gui_data in pairs(storage.requester_guis) do
		if gui_data and gui_data.buttons then
			for i, button_data in ipairs(gui_data.buttons) do
				if button_data and button_data.slot_button and button_data.slot_button.valid and button_data.slot_button == element then
					gui.open_item_selector_gui(player_index, i, gui_data, gui_data.last_opened_requester)
					return
				end
			end
		end
	end
end)

script.on_event(defines.events.on_entity_settings_pasted, function(event)
	local source, destination = event.source, event.destination
	
	if destination.name == constants.spidertron_requester_chest then
		local destination_data = storage.requesters[destination.unit_number]
		if source.name == constants.spidertron_requester_chest then 
			local source_data = storage.requesters[source.unit_number]
			-- Copy requested_items
			if not destination_data.requested_items then
				destination_data.requested_items = {}
			end
			if source_data.requested_items then
				-- Deep copy
				destination_data.requested_items = {}
				for item, count in pairs(source_data.requested_items) do
					destination_data.requested_items[item] = count
				end
			elseif source_data.requested_item then
				-- Migrate old format
				destination_data.requested_items[source_data.requested_item] = source_data.request_size or 0
			end
		else
			destination_data.requested_items = {}
		end
		
		local gui_data = storage.requester_guis[event.player_index]
		if gui_data and gui_data.last_opened_requester == destination_data then
			gui.update_requester_gui(gui_data, destination_data)
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

script.on_event(defines.events.on_player_driving_changed_state, function(event)
	local spider = event.entity
	if spider and spider.get_driver() and storage.spiders[spider.unit_number] then
		journey.end_journey(spider.unit_number, false)
	end
end)

script.on_event(defines.events.on_player_used_spidertron_remote, function(event)
	local spider = event.vehicle
	if event.success and storage.spiders[spider.unit_number] then
		journey.end_journey(spider.unit_number, false)
	end
end)

-- Handle pathfinding results
script.on_event(defines.events.on_script_path_request_finished, function(event)
	pathing.handle_path_result(event)
end)

-- Main logistics update loop
script.on_nth_tick(constants.update_cooldown, function(event)
	-- TOP PRIORITY: Handle spiders that need to dump items (failed deliveries)
	-- Check all spiders in dumping_items status
	for unit_number, spider_data in pairs(storage.spiders) do
		if spider_data.status == constants.dumping_items then
			local spider = spider_data.entity
			if not spider or not spider.valid then
				spider_data.status = constants.idle
				goto next_dumping_spider
			end
			
			-- If no dump_target, try to find one
			if not spider_data.dump_target or not spider_data.dump_target.valid then
				journey.attempt_dump_items(unit_number)
				goto next_dumping_spider
			end
			
			-- Check if spider is close enough to dump target and try to dump
			local dump_target = spider_data.dump_target
			if dump_target and dump_target.valid then
				local distance = utils.distance(spider.position, dump_target.position)
				if distance <= 6 then
					-- Spider is close enough, try to dump items
					-- logging.info("Dump", "Spider " .. unit_number .. " is close to storage chest (distance: " .. string.format("%.2f", distance) .. "), attempting dump")
					
					-- Clear autopilot to ensure spider stops
					if spider.autopilot_destinations and #spider.autopilot_destinations > 0 then
						spider.autopilot_destination = nil
						-- logging.info("Dump", "Cleared autopilot destination")
					else
						-- logging.info("Dump", "No autopilot destinations to clear")
					end
					
					-- Try to dump items
					-- Iterate through inventory slots directly instead of using get_contents()
					local trunk = spider.get_inventory(defines.inventory.spider_trunk)
					if not trunk then
						journey.end_journey(unit_number, true)
						return
					end
					
					-- logging.info("Dump", "Spider trunk found, iterating through " .. #trunk .. " slots")
					
					local dumped_any = false
					local processed_items = {}  -- Track which items we've processed to avoid duplicates
					
					-- Iterate through all inventory slots
					for i = 1, #trunk do
						local stack = trunk[i]
						if stack and stack.valid_for_read and stack.count > 0 then
							local item_name = stack.name
							local stack_count = stack.count
							
							-- Skip if we've already processed this item type
							if processed_items[item_name] then goto next_slot end
							
							-- logging.info("Dump", "  Found stack " .. i .. ": " .. stack_count .. " " .. item_name)
							
							-- Get chest inventory
							local chest_inv = dump_target.get_inventory(defines.inventory.chest)
							if not chest_inv then
								-- logging.warn("Dump", "    Failed to get chest inventory")
								goto next_slot
							end
							
							-- Check if chest can accept items
							local chest_has_item = chest_inv.get_item_count(item_name)
							local empty_slots = chest_inv.count_empty_stacks(false, false)
							
							-- logging.info("Dump", "    Chest has " .. chest_has_item .. " " .. item_name .. ", " .. empty_slots .. " empty slots")
							
							-- Can insert if: chest has the item (can add to existing stacks) OR has empty slots
							local can_insert = (chest_has_item > 0) or (empty_slots > 0)
							
							if not can_insert then
								-- logging.warn("Dump", "    Cannot insert: chest has no " .. item_name .. " and no empty slots")
								processed_items[item_name] = true
								goto next_slot
							end
							
							-- Try to insert the stack
							local inserted = 0
							
							-- Method 1: Insert the stack object directly
							-- logging.info("Dump", "    Trying chest_inv.insert(stack)")
							local stack_count_before = stack.count
							local stack_insert_result = chest_inv.insert(stack)
							local stack_count_after = stack.count
							-- logging.info("Dump", "    Insert returned: " .. stack_insert_result .. " (stack: " .. stack_count_before .. " -> " .. stack_count_after .. ")")
							
							if stack_insert_result > 0 then
								inserted = stack_insert_result
								-- Check if stack was automatically consumed
								local stack_consumed = stack_count_before - stack_count_after
								if stack_consumed < inserted then
									-- Stack wasn't fully consumed, remove the remainder
									local to_remove = inserted - stack_consumed
									local removed = spider.remove_item{name = item_name, count = to_remove}
									-- logging.info("Dump", "    Stack consumed: " .. stack_consumed .. ", removed additional: " .. removed)
								else
									-- logging.info("Dump", "    Stack was fully consumed automatically")
								end
								-- logging.info("Dump", "  ✓ Successfully dumped " .. inserted .. " " .. item_name)
								dumped_any = true
							else
								-- Method 2: Insert by name and count
								-- logging.info("Dump", "    Stack insert failed, trying chest_inv.insert{name, count}")
								local name_insert_result = chest_inv.insert{name = item_name, count = stack_count}
								-- logging.info("Dump", "    Insert returned: " .. name_insert_result)
								
								if name_insert_result > 0 then
									inserted = name_insert_result
									-- Remove exactly what was inserted from the spider
									local removed = spider.remove_item{name = item_name, count = inserted}
									-- logging.info("Dump", "    Removed from spider: " .. removed)
									-- logging.info("Dump", "  ✓ Successfully dumped " .. inserted .. " " .. item_name .. " (removed " .. removed .. " from spider)")
									dumped_any = true
								else
									-- Method 3: Entity insert
									-- logging.info("Dump", "    Inventory insert failed, trying dump_target.insert")
									local entity_insert_result = dump_target.insert{name = item_name, count = stack_count}
									-- logging.info("Dump", "    Insert returned: " .. entity_insert_result)
									
									if entity_insert_result > 0 then
										inserted = entity_insert_result
										-- Remove exactly what was inserted from the spider
										local removed = spider.remove_item{name = item_name, count = inserted}
										-- logging.info("Dump", "    Removed from spider: " .. removed)
										-- logging.info("Dump", "  ✓ Successfully dumped " .. inserted .. " " .. item_name .. " (removed " .. removed .. " from spider)")
										dumped_any = true
									else
										-- logging.warn("Dump", "  ✗ All insert methods returned 0 for " .. item_name)
									end
								end
							end
							
							-- Mark this item as processed
							processed_items[item_name] = true
						end
						::next_slot::
					end
					
					-- Check if done dumping
					local has_items = false
					for i = 1, #trunk do
						local stack = trunk[i]
						if stack and stack.valid_for_read and stack.count > 0 then
							has_items = true
							break
						end
					end
					
					if not has_items then
						-- No items left, done dumping
						-- logging.info("Dump", "Spider " .. unit_number .. " finished dumping all items")
						spider_data.dump_target = nil
						journey.end_journey(unit_number, true)
					elseif not dumped_any then
						-- Couldn't dump anything, try to find another chest
						-- logging.warn("Dump", "Spider " .. unit_number .. " couldn't dump items, trying to find another storage chest")
						spider_data.dump_target = nil
						journey.attempt_dump_items(unit_number)
					end
				end
			end
			
			::next_dumping_spider::
		end
	end
	
	-- Re-validate beacon assignments periodically to ensure all chests have owners
	-- Only do this every 60 ticks (once per second) to avoid performance issues
	if event.tick % 60 == 0 then
		for _, requester_data in pairs(storage.requesters) do
			if requester_data.entity and requester_data.entity.valid then
				if not requester_data.beacon_owner then
					beacon_assignment.assign_chest_to_nearest_beacon(requester_data.entity)
				else
					-- Verify beacon still exists and is valid
					local beacon_data = storage.beacons[requester_data.beacon_owner]
					if not beacon_data or not beacon_data.entity or not beacon_data.entity.valid then
						requester_data.beacon_owner = nil
						beacon_assignment.assign_chest_to_nearest_beacon(requester_data.entity)
					end
				end
			end
		end
		
		for _, provider_data in pairs(storage.providers) do
			if provider_data.entity and provider_data.entity.valid then
				if not provider_data.beacon_owner then
					beacon_assignment.assign_chest_to_nearest_beacon(provider_data.entity)
				else
					-- Verify beacon still exists and is valid
					local beacon_data = storage.beacons[provider_data.beacon_owner]
					if not beacon_data or not beacon_data.entity or not beacon_data.entity.valid then
						provider_data.beacon_owner = nil
						beacon_assignment.assign_chest_to_nearest_beacon(provider_data.entity)
					end
				end
			end
		end
	end
	
	-- Stuck detection for active spiders
	for unit_number, spider_data in pairs(storage.spiders) do
		if spider_data.status ~= constants.idle and spider_data.status ~= constants.dumping_items then
			local spider = spider_data.entity
			if spider and spider.valid then
				local current_pos = spider.position
				local current_tick = event.tick
				
				-- Initialize position tracking if needed
				if not spider_data.last_position then
					spider_data.last_position = current_pos
					spider_data.last_position_tick = current_tick
					spider_data.stuck_count = 0
				else
					-- Check if spider has moved (more than 0.5 tiles)
					local distance_moved = utils.distance(spider_data.last_position, current_pos)
					local ticks_since_last_check = current_tick - spider_data.last_position_tick
					
					-- If spider hasn't moved much in the last 5 seconds (300 ticks), it might be stuck
					if distance_moved < 0.5 and ticks_since_last_check >= 300 then
						spider_data.stuck_count = (spider_data.stuck_count or 0) + 1
						
						-- If stuck for 2+ checks (10+ seconds), trigger repath
						if spider_data.stuck_count >= 2 then
							-- logging.warn("Stuck", "Spider " .. unit_number .. " appears stuck (hasn't moved " .. string.format("%.2f", distance_moved) .. " tiles in " .. ticks_since_last_check .. " ticks), attempting repath")
							
							-- Clear current path
							if spider.autopilot_destinations and #spider.autopilot_destinations > 0 then
								spider.autopilot_destination = nil
							end
							
							-- Try to repath to current destination
							local destination = nil
							if spider_data.status == constants.picking_up and spider_data.provider_target and spider_data.provider_target.valid then
								destination = spider_data.provider_target
							elseif spider_data.status == constants.dropping_off and spider_data.requester_target and spider_data.requester_target.valid then
								destination = spider_data.requester_target
							end
							
							if destination then
								local pathing_success = pathing.set_smart_destination(spider, destination.position, destination)
								if pathing_success then
									-- logging.info("Stuck", "Repath successful for spider " .. unit_number)
									-- Reset stuck detection
									spider_data.last_position = current_pos
									spider_data.last_position_tick = current_tick
									spider_data.stuck_count = 0
								else
									-- logging.warn("Stuck", "Repath failed for spider " .. unit_number .. ", will try again next cycle")
								end
							else
								-- logging.warn("Stuck", "No valid destination for stuck spider " .. unit_number .. ", ending journey")
								journey.end_journey(unit_number, true)
							end
						else
							-- Update position but keep tracking
							spider_data.last_position = current_pos
							spider_data.last_position_tick = current_tick
						end
					else
						-- Spider moved, reset stuck counter
						if distance_moved >= 0.5 then
							spider_data.last_position = current_pos
							spider_data.last_position_tick = current_tick
							spider_data.stuck_count = 0
						end
					end
				end
			end
		else
			-- Reset stuck detection for idle/dumping spiders
			if spider_data.last_position then
				spider_data.last_position = nil
				spider_data.last_position_tick = nil
				spider_data.stuck_count = 0
			end
		end
	end
	
	local requests = logistics.requesters()
	local spiders_list = logistics.spiders()
	local providers_list = logistics.providers()
	
	-- Log summary of available resources
	local total_requests = 0
	local total_spiders = 0
	local total_providers = 0
	for _, reqs in pairs(requests) do total_requests = total_requests + #reqs end
	for _, spids in pairs(spiders_list) do total_spiders = total_spiders + #spids end
	for _, provs in pairs(providers_list) do total_providers = total_providers + #provs end
	
	-- logging.debug("Logistics", "Update cycle: " .. total_requests .. " requests, " .. total_spiders .. " spiders, " .. total_providers .. " providers")
	
	for network_key, requesters in pairs(requests) do
		-- logging.debug("Logistics", "Processing network " .. network_key .. " with " .. #requesters .. " requests")
		
		local providers_for_network = providers_list[network_key]
		if not providers_for_network then 
			-- logging.debug("Logistics", "Network " .. network_key .. " has no providers")
			goto next_network 
		end
		-- logging.debug("Logistics", "Network " .. network_key .. " has " .. #providers_for_network .. " providers")
		
		local spiders_on_network = spiders_list[network_key]
		if not spiders_on_network or #spiders_on_network == 0 then 
			-- logging.debug("Logistics", "Network " .. network_key .. " has no available spiders")
			goto next_network 
		end
		-- logging.debug("Logistics", "Network " .. network_key .. " has " .. #spiders_on_network .. " available spiders")
		
		for _, item_request in ipairs(requesters) do
			local item = item_request.requested_item
			local requester_data = item_request.requester_data
			if not item then goto next_requester end
			
			-- logging.debug("Logistics", "Processing request: " .. item .. " x" .. item_request.real_amount .. " for requester at (" .. math.floor(requester_data.entity.position.x) .. "," .. math.floor(requester_data.entity.position.y) .. ")")
			
			local max = 0
			local best_provider
			for _, provider_data in ipairs(providers_for_network) do
				local provider = provider_data.entity
				if not provider or not provider.valid then goto next_provider end
				
				local item_count = 0
				local allocated = 0
				
				if provider_data.is_robot_chest then
					-- For robot chests, use the contains data that was already calculated
					-- or recalculate if not available (shouldn't happen, but safety check)
					if provider_data.contains and provider_data.contains[item] then
						item_count = provider_data.contains[item]
					else
						-- Fallback: recalculate from inventory
						item_count = provider.get_inventory(defines.inventory.chest).get_item_count(item)
					end
					allocated = 0  -- Robot chests don't use allocation tracking
				else
					-- Custom provider chest logic (existing)
					item_count = provider.get_inventory(defines.inventory.chest).get_item_count(item)
					if not provider_data.allocated_items then
						provider_data.allocated_items = {}
					end
					allocated = provider_data.allocated_items[item] or 0
				end
				
				-- Only consider providers that actually have the item
				if item_count <= 0 then goto next_provider end
				
				local can_provide = item_count - allocated
				if can_provide > 0 and can_provide > max then
					max = can_provide
					best_provider = provider_data
				end
				
				::next_provider::
			end
			
			if best_provider ~= nil and max > 0 then
				-- Create a temporary requester_data-like object for assign_spider
				local temp_requester = {
					entity = requester_data.entity,
					requested_item = item,
					real_amount = item_request.real_amount,
					incoming_items = requester_data.incoming_items
				}
				local provider = best_provider.entity
				-- logging.info("Assignment", "Found provider with " .. max .. " " .. item .. " available")
				-- logging.info("Assignment", "Attempting to assign spider for " .. item .. " x" .. max)
				local assigned = logistics.assign_spider(spiders_on_network, temp_requester, best_provider, max)
				if assigned then
					-- logging.info("Assignment", "✓ Spider assignment SUCCESSFUL")
				else
					-- logging.warn("Assignment", "✗ Spider assignment FAILED (no available spiders or inventory full)")
				end
				if not assigned then
					goto next_requester
				end
				if #spiders_on_network == 0 then
					-- logging.debug("Logistics", "No more spiders available on network " .. network_key)
					goto next_network
				end
			else
				if best_provider == nil then
					-- logging.debug("Logistics", "No provider found for " .. item)
				elseif max <= 0 then
					-- logging.debug("Logistics", "Provider found but has 0 items available for " .. item)
				end
			end
			
			::next_requester::
		end
		::next_network::
	end
end)

script.on_event(defines.events.on_spider_command_completed, function(event)
	local spider = event.vehicle
	local unit_number = spider.unit_number
	local spider_data = storage.spiders[unit_number]
	
	local goal
	if spider_data == nil or not spider_data.status or spider_data.status == constants.idle then
		return
	elseif spider_data.status == constants.picking_up then
		if not spider_data.requester_target or not spider_data.requester_target.valid then
			-- logging.warn("Journey", "Spider " .. unit_number .. " cancelling: requester_target invalid (status: picking_up)")
			journey.end_journey(unit_number, true)
			return
		end
		goal = spider_data.provider_target
	elseif spider_data.status == constants.dropping_off then
		if not spider_data.requester_target or not spider_data.requester_target.valid then
			-- logging.warn("Journey", "Spider " .. unit_number .. " cancelling: requester_target invalid (status: dropping_off)")
			journey.end_journey(unit_number, true)
			return
		end
		goal = spider_data.requester_target
	elseif spider_data.status == constants.dumping_items then
		-- Dumping items is handled separately, don't process here
		return
	end
	
	-- Check if goal is valid (but don't check distance - spider might still be traveling)
	if not goal or not goal.valid or goal.to_be_deconstructed() or spider.surface ~= goal.surface then
		local reason = "unknown"
		if not goal then reason = "goal is nil"
		elseif not goal.valid then reason = "goal invalid"
		elseif goal.to_be_deconstructed() then reason = "goal marked for deconstruction"
		elseif spider.surface ~= goal.surface then reason = "different surface"
		end
		-- logging.warn("Journey", "Spider " .. unit_number .. " cancelling journey: " .. reason .. " (status: " .. (spider_data and spider_data.status or "nil") .. ")")
		journey.end_journey(unit_number, true)
		return
	end
	
	-- Check distance separately - only cancel if spider is way too far (likely lost/stuck)
	-- Normal travel distance can be hundreds of tiles, so we use a much larger threshold
	local distance_to_goal = utils.distance(spider.position, goal.position)
	if distance_to_goal > 1000 then
		-- logging.warn("Journey", "Spider " .. unit_number .. " cancelling journey: distance > 1000 (" .. string.format("%.2f", distance_to_goal) .. ") - spider likely lost (status: " .. (spider_data and spider_data.status or "nil") .. ")")
		journey.end_journey(unit_number, true)
		return
	end
	
	local item = spider_data.payload_item
	local item_count = spider_data.payload_item_count
	local requester = spider_data.requester_target
	local requester_data = storage.requesters[requester.unit_number]
	
	if spider_data.status == constants.picking_up then
		local provider = spider_data.provider_target
		
		-- Verify spider is actually close enough to the provider
		local distance_to_provider = utils.distance(spider.position, provider.position)
		if distance_to_provider > 6 then
			-- Spider not close enough yet, wait for next command completion
			-- logging.debug("Pickup", "Spider " .. unit_number .. " not close enough to provider (distance: " .. string.format("%.2f", distance_to_provider) .. "), waiting...")
			return
		end
		
		-- Clear any remaining autopilot destinations to ensure spider stops
		if spider.autopilot_destinations and #spider.autopilot_destinations > 0 then
			spider.autopilot_destination = nil
		end
		
		-- logging.info("Pickup", "Spider arrived at provider for " .. item .. " x" .. item_count .. " at (" .. math.floor(provider.position.x) .. "," .. math.floor(provider.position.y) .. ")")
		local provider_data = storage.providers[provider.unit_number]
		local is_robot_chest = false
		
		-- Check if this is a robot chest
		if provider_data then
			is_robot_chest = provider_data.is_robot_chest or false
		else
			-- Not in storage.providers, check if it's a robot chest type
			local robot_chest_names = {
				'storage-chest',
				'active-provider-chest',
				'passive-provider-chest'
			}
			for _, chest_name in ipairs(robot_chest_names) do
				if provider.name == chest_name then
					is_robot_chest = true
					break
				end
			end
		end
		
		-- Get item count from provider chest inventory
		local provider_inventory = provider.get_inventory(defines.inventory.chest)
		local contains = provider_inventory and provider_inventory.get_item_count(item) or 0
		if contains > item_count then contains = item_count end
		local already_had = spider.get_item_count(item)
		if already_had > item_count then already_had = item_count end
		
		if contains + already_had == 0 then
			-- logging.warn("Pickup", "Spider " .. unit_number .. " cancelling: no items available at provider (contains: " .. contains .. ", already_had: " .. already_had .. ")")
			journey.end_journey(unit_number, true)
			return
		end
		
		local can_insert = min(contains - already_had, item_count)
		local actually_inserted = can_insert <= 0 and 0 or spider.insert{name = item, count = can_insert}
		if actually_inserted + already_had == 0 then
			-- logging.warn("Pickup", "Spider " .. unit_number .. " cancelling: failed to insert items (can_insert: " .. can_insert .. ", actually_inserted: " .. actually_inserted .. ", already_had: " .. already_had .. ")")
			journey.end_journey(unit_number, true)
			return
		end
		
		if actually_inserted ~= 0 then
			provider.remove_item{name = item, count = actually_inserted}
			-- Only track pickup_count for custom provider chests
			if not is_robot_chest and provider_data then
				provider_data.pickup_count = (provider_data.pickup_count or 0) + actually_inserted
			end
			rendering.draw_withdraw_icon(provider)
		end
		
		-- Verify pickup actually succeeded before proceeding
		local final_spider_count = spider.get_item_count(item)
		local expected_count = actually_inserted + already_had
		
		if final_spider_count < expected_count then
			-- Pickup didn't complete as expected - retry
			-- Initialize retry counter if not exists
			if not spider_data.pickup_retry_count then
				spider_data.pickup_retry_count = 0
			end
			spider_data.pickup_retry_count = spider_data.pickup_retry_count + 1
			
			-- If we've retried too many times, abort
			if spider_data.pickup_retry_count > 5 then
				-- Too many retries, something is wrong - end journey
				journey.end_journey(unit_number, true)
				return
			end
			
			-- Retry by setting destination to provider again
			if provider and provider.valid then
				pathing.set_smart_destination(spider, provider.position, provider)
			else
				-- Provider is invalid, abort
				journey.end_journey(unit_number, true)
			end
			return
		end
		
		-- Successfully picked up, reset retry counter
		spider_data.pickup_retry_count = nil
		
		spider_data.payload_item_count = actually_inserted + already_had
		-- Update incoming_items: subtract original expected amount, add back what was actually picked up
		if not requester_data.incoming_items then
			requester_data.incoming_items = {}
		end
		requester_data.incoming_items[item] = (requester_data.incoming_items[item] or 0) - item_count + actually_inserted + already_had
		if requester_data.incoming_items[item] <= 0 then
			requester_data.incoming_items[item] = nil
		end
		
		-- Only proceed to next destination if we actually have items
		if spider_data.payload_item_count > 0 then
			-- logging.info("Pickup", "Pickup successful: " .. spider_data.payload_item_count .. " items, setting destination to requester")
			-- Set status to dropping_off and set destination to requester
			spider_data.status = constants.dropping_off
			local pathing_success = pathing.set_smart_destination(spider, spider_data.requester_target.position, spider_data.requester_target)
			if not pathing_success then
				-- logging.warn("Pickup", "Pathfinding to requester failed after pickup, cancelling journey")
				journey.end_journey(unit_number, true)
			end
		else
			-- No items picked up, end journey
			-- logging.warn("Pickup", "No items picked up, ending journey")
			journey.end_journey(unit_number, true)
		end
		
		-- Only update allocated_items for custom provider chests
		if not is_robot_chest and provider_data then
			local allocated_items = provider_data.allocated_items
			if allocated_items then
				allocated_items[item] = (allocated_items[item] or 0) - item_count
				if allocated_items[item] <= 0 then allocated_items[item] = nil end
			end
		end
		
		spider_data.status = constants.dropping_off
		-- Set destination to requester now that we have items
		if spider_data.requester_target and spider_data.requester_target.valid then
			local pathing_success = pathing.set_smart_destination(spider, spider_data.requester_target.position, spider_data.requester_target)
			if not pathing_success then
				-- logging.warn("Pickup", "Pathfinding to requester failed after pickup, cancelling journey")
				journey.end_journey(unit_number, true)
			end
		end
	elseif spider_data.status == constants.dropping_off then
		-- Verify spider is actually close enough to the requester
		local distance_to_requester = utils.distance(spider.position, requester.position)
		if distance_to_requester > 6 then
			-- Spider not close enough yet, wait for next command completion
			-- logging.debug("Dropoff", "Spider " .. unit_number .. " not close enough to requester (distance: " .. string.format("%.2f", distance_to_requester) .. "), waiting...")
			return
		end
		
		-- Clear any remaining autopilot destinations to ensure spider stops
		if spider.autopilot_destinations and #spider.autopilot_destinations > 0 then
			spider.autopilot_destination = nil
		end
		
		-- logging.info("Dropoff", "Spider arrived at requester for " .. item .. " x" .. item_count .. " at (" .. math.floor(requester.position.x) .. "," .. math.floor(requester.position.y) .. ")")
		
		-- Clear any remaining autopilot destinations to ensure spider stops
		if spider.autopilot_destinations and #spider.autopilot_destinations > 0 then
			spider.autopilot_destination = nil
		end
		
		local spider_item_count = spider.get_item_count(item)
		local can_insert = min(spider_item_count, item_count)
		
		-- Use insert and remove with exact counts
		local actually_inserted = 0
		if can_insert > 0 then
			actually_inserted = requester.insert{name = item, count = can_insert}
			-- logging.info("Dropoff", "  Inserted " .. actually_inserted .. " " .. item .. " into requester")
			
			if actually_inserted > 0 then
				-- Remove exactly what was inserted
				local removed = spider.remove_item{name = item, count = actually_inserted}
				-- logging.info("Dropoff", "  Removed " .. removed .. " " .. item .. " from spider")
				
				if removed > 0 then
					requester_data.dropoff_count = (requester_data.dropoff_count or 0) + actually_inserted
					rendering.draw_deposit_icon(requester)
				else
					-- logging.warn("Dropoff", "  Failed to remove items from spider after insertion")
				end
			end
		end
		
		-- Verify spider no longer has the items (or has fewer) before ending journey
		local remaining_spider_count = spider.get_item_count(item)
		if remaining_spider_count >= spider_item_count and spider_item_count > 0 then
			-- Dropoff failed - items are still in spider, retry
			-- Initialize retry counter if not exists
			if not spider_data.dropoff_retry_count then
				spider_data.dropoff_retry_count = 0
			end
			spider_data.dropoff_retry_count = spider_data.dropoff_retry_count + 1
			
			-- If we've retried too many times, abort
			if spider_data.dropoff_retry_count > 5 then
				-- Too many retries, something is wrong - end journey
				journey.end_journey(unit_number, true)
				return
			end
			
			-- Retry by setting destination to requester again
			if requester and requester.valid then
				pathing.set_smart_destination(spider, requester.position, requester)
			else
				-- Requester is invalid, abort
				journey.end_journey(unit_number, true)
			end
			return
		end
		
		-- Successfully dropped off, reset retry counter
		spider_data.dropoff_retry_count = nil
		
		-- logging.info("Dropoff", "Dropoff successful: " .. actually_inserted .. " items delivered")
		journey.end_journey(unit_number, true)
		journey.deposit_already_had(spider_data)
	elseif spider_data.status == constants.dumping_items then
		-- Handle dumping items to storage chest
		local dump_target = spider_data.dump_target
		if not dump_target or not dump_target.valid then
			-- No valid dump target, try to find one
			journey.attempt_dump_items(unit_number)
			return
		end
		
		-- Check if spider is close enough to dump target
		if utils.distance(spider.position, dump_target.position) > 6 then
			-- Not close enough yet, wait for next command completion
			return
		end
		
		-- Clear any remaining autopilot destinations to ensure spider stops
		if spider.autopilot_destinations and #spider.autopilot_destinations > 0 then
			spider.autopilot_destination = nil
		end
		
		-- Try to dump items
		local trunk = spider.get_inventory(defines.inventory.spider_trunk)
		if not trunk then
			journey.end_journey(unit_number, true)
			return
		end
		
		local contents = trunk.get_contents()
		if not contents or next(contents) == nil then
			-- No items left, done dumping
			-- logging.info("Dump", "Spider " .. unit_number .. " finished dumping items")
			spider_data.dump_target = nil
			journey.end_journey(unit_number, true)
			return
		end
		
		-- Try to insert items into storage chest
		-- Use the entity's insert method, not the inventory's (like we do for requester)
		local dumped_any = false
		for item_name, count in pairs(contents) do
			-- Validate item_name
			if not item_name or type(item_name) ~= "string" or item_name == "" then goto next_dump_item end
			
			local item_count = 0
			if type(count) == "number" then
				item_count = count
			elseif type(count) == "table" then
				-- Handle ItemWithQualityCounts format - sum all qualities
				for quality, qty in pairs(count) do
					if type(qty) == "number" then
						item_count = item_count + qty
					end
				end
			end
			
			if item_count > 0 then
				-- Get how many items the spider actually has
				local spider_has = spider.get_item_count(item_name)
				if spider_has > item_count then spider_has = item_count end
				
				if spider_has > 0 then
					-- Try to insert items using the entity's insert method (like requester.insert)
					-- This is the same pattern used for dropping off at requesters
					local inserted = dump_target.insert{name = item_name, count = spider_has}
					
					-- logging.info("Dump", "  Attempted to insert " .. spider_has .. " " .. item_name .. ", got " .. inserted)
					
					if inserted > 0 then
						-- Remove items from spider
						local removed = spider.remove_item{name = item_name, count = inserted}
						if removed > 0 then
							dumped_any = true
							-- logging.info("Dump", "Spider " .. unit_number .. " dumped " .. inserted .. " " .. item_name .. " to storage chest (removed " .. removed .. " from spider)")
						else
							-- logging.warn("Dump", "Spider " .. unit_number .. " inserted " .. inserted .. " " .. item_name .. " but failed to remove from spider (spider still has: " .. spider.get_item_count(item_name) .. ")")
						end
					else
						-- logging.warn("Dump", "Spider " .. unit_number .. " failed to insert " .. item_name .. " into storage chest (spider has: " .. spider_has .. ", insert returned: " .. inserted .. ")")
					end
				end
			end
			::next_dump_item::
		end
		
		if dumped_any then
			-- Check if there are more items to dump
			local remaining_contents = trunk.get_contents()
			if not remaining_contents or next(remaining_contents) == nil then
				-- All items dumped, done
				-- logging.info("Dump", "Spider " .. unit_number .. " finished dumping all items")
				spider_data.dump_target = nil
				journey.end_journey(unit_number, true)
			else
				-- Still have items, but chest might be full - try to find another storage chest
				-- Or continue to current one if it can still accept items
				local can_accept_more = false
				for item_name, count in pairs(remaining_contents) do
					-- Validate item_name is a valid string
					if not item_name or type(item_name) ~= "string" or item_name == "" then goto next_remaining_item end
					
					local item_count = 0
					if type(count) == "number" then
						item_count = count
					elseif type(count) == "table" then
						for quality, qty in pairs(count) do
							if type(qty) == "number" then
								item_count = item_count + qty
							end
						end
					end
					
					if item_count > 0 then
						local success, can_insert_result = pcall(function()
							return chest_inventory.can_insert({name = item_name, count = 1})
						end)
						if success and type(can_insert_result) == "number" and can_insert_result > 0 then
							can_accept_more = true
							break
						end
					end
					::next_remaining_item::
				end
				
				if not can_accept_more then
					-- Current chest is full, find another
					spider_data.dump_target = nil
					journey.attempt_dump_items(unit_number)
				end
			end
		else
			-- Couldn't dump any items - chest might be full or items incompatible
			-- Try to find another storage chest
			spider_data.dump_target = nil
			journey.attempt_dump_items(unit_number)
		end
	end
end)

script.on_event(defines.events.on_entity_died, function(event)
	local unit_number = event.unit_number
	
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
			-- logging.info("Beacon", "Beacon " .. unit_number .. " destroyed, reassigning " .. #beacon_data.assigned_chests .. " chests")
			for _, chest_unit_number in ipairs(beacon_data.assigned_chests) do
				local chest = nil
				if storage.providers[chest_unit_number] then
					chest = storage.providers[chest_unit_number].entity
					-- Clear beacon_owner
					if storage.providers[chest_unit_number] then
						storage.providers[chest_unit_number].beacon_owner = nil
					end
				elseif storage.requesters[chest_unit_number] then
					chest = storage.requesters[chest_unit_number].entity
					-- Clear beacon_owner
					if storage.requesters[chest_unit_number] then
						storage.requesters[chest_unit_number].beacon_owner = nil
					end
				end
				if chest and chest.valid then
					beacon_assignment.assign_chest_to_nearest_beacon(chest)
				end
			end
		end
		-- Clean up beacon assignments
		storage.beacon_assignments[unit_number] = nil
		storage.beacons[unit_number] = nil
		-- logging.info("Beacon", "Beacon " .. unit_number .. " cleaned up")
	end
end)

local function built(event)
	local entity = event.created_entity or event.entity

	if entity.type == 'spider-vehicle' and entity.prototype.order ~= 'z[programmable]' then
		registration.register_spider(entity)
	elseif entity.name == constants.spidertron_requester_chest then
		-- logging.info("Registration", "Registering requester chest at (" .. math.floor(entity.position.x) .. "," .. math.floor(entity.position.y) .. ")")
		registration.register_requester(entity, event.tags)
		local requester_data = storage.requesters[entity.unit_number]
		if requester_data and requester_data.beacon_owner then
			-- logging.info("Beacon", "Requester chest assigned to beacon " .. requester_data.beacon_owner)
		else
			-- logging.warn("Beacon", "Requester chest NOT assigned to any beacon")
		end
	elseif entity.name == constants.spidertron_provider_chest then
		-- logging.info("Registration", "Registering provider chest at (" .. math.floor(entity.position.x) .. "," .. math.floor(entity.position.y) .. ")")
		registration.register_provider(entity)
		local provider_data = storage.providers[entity.unit_number]
		if provider_data and provider_data.beacon_owner then
			-- logging.info("Beacon", "Provider chest assigned to beacon " .. provider_data.beacon_owner)
		else
			-- logging.warn("Beacon", "Provider chest NOT assigned to any beacon")
		end
	elseif entity.name == constants.spidertron_logistic_beacon then
		-- logging.info("Registration", "Registering beacon at (" .. math.floor(entity.position.x) .. "," .. math.floor(entity.position.y) .. ")")
		registration.register_beacon(entity)
	end
end

script.on_event(defines.events.on_built_entity, built)
script.on_event(defines.events.on_robot_built_entity, built)
script.on_event(defines.events.script_raised_built, built)
script.on_event(defines.events.script_raised_revive, built)

local function save_blueprint_data(blueprint, mapping)
	for i, entity in ipairs(mapping) do
		if entity.valid then
			local requester_data = storage.requesters[entity.unit_number]
			if requester_data then
				-- Save requested_items (multi-item format)
				if requester_data.requested_items then
					-- Convert table to serializable format
					local items_list = {}
					for item_name, count in pairs(requester_data.requested_items) do
						if count > 0 and item_name and item_name ~= '' then
							table.insert(items_list, {name = item_name, count = count})
						end
					end
					blueprint.set_blueprint_entity_tag(i, 'requested_items', items_list)
				elseif requester_data.requested_item then
					-- Legacy format support
					blueprint.set_blueprint_entity_tag(i, 'requested_item', requester_data.requested_item)
					blueprint.set_blueprint_entity_tag(i, 'request_size', requester_data.request_size)
				end
			end
		end
	end
end

script.on_event(defines.events.on_player_setup_blueprint, function(event)
	local player = game.players[event.player_index]
	
	local cursor = player.cursor_stack
	if cursor and cursor.valid_for_read and cursor.type == 'blueprint' then
		save_blueprint_data(cursor, event.mapping.get())
	else
		storage.blueprint_mappings[player.index] = event.mapping.get()
	end
end)

script.on_event(defines.events.on_player_configured_blueprint, function(event)
	local player = game.players[event.player_index]
	local mapping = storage.blueprint_mappings[player.index]
	local cursor = player.cursor_stack
	
	if cursor and cursor.valid_for_read and cursor.type == 'blueprint' and mapping and #mapping == cursor.get_blueprint_entity_count() then
		save_blueprint_data(cursor, mapping)
	end
	storage.blueprint_mappings[player.index] = nil
end)

-- Setup and initialization
local function setup()
	storage.spiders = storage.spiders or {}
	storage.requesters = storage.requesters or {}
	storage.requester_guis = storage.requester_guis or {}
	storage.providers = storage.providers or {}
	storage.beacons = storage.beacons or {}
	storage.beacon_assignments = storage.beacon_assignments or {}
	storage.blueprint_mappings = storage.blueprint_mappings or {}
	
	-- Migrate old beacon storage format if needed
	for unit_number, beacon in pairs(storage.beacons) do
		if type(beacon) == "table" and beacon.entity then
			-- Already in new format
		else
			-- Old format: just the entity, convert to new format
			if beacon and beacon.valid then
				storage.beacons[unit_number] = {
					entity = beacon,
					assigned_chests = {}
				}
			else
				storage.beacons[unit_number] = nil
			end
		end
	end
	
	-- Reassign all chests to beacons on load
	for _, provider_data in pairs(storage.providers) do
		if provider_data.entity and provider_data.entity.valid then
			if not provider_data.beacon_owner then
				beacon_assignment.assign_chest_to_nearest_beacon(provider_data.entity)
			end
		end
	end
	
	for _, requester_data in pairs(storage.requesters) do
		if requester_data.entity and requester_data.entity.valid then
			if not requester_data.beacon_owner then
				beacon_assignment.assign_chest_to_nearest_beacon(requester_data.entity)
			end
		end
	end
	
	-- Migrate spiders to have active field if missing
	for unit_number, spider_data in pairs(storage.spiders) do
		if spider_data.entity and spider_data.entity.valid then
			if spider_data.active == nil then
				spider_data.active = false  -- Default to inactive for existing spiders
			end
		end
	end
	
	-- Register all commands
	debug_commands.register_all()
end

-- Track selected entities for connection line rendering
local selected_entities = {}

-- Draw connection lines when hovering over entities and flashing icons for failed dumps
script.on_event(defines.events.on_tick, function(event)
	-- Only check every 10 ticks for performance
	if event.tick % 10 ~= 0 then return end
	
	-- Check all players for selected entities
	for _, player in pairs(game.players) do
		if player and player.valid and player.selected then
			local entity = player.selected
			if entity and entity.valid then
				-- Check if it's a chest or beacon
				if entity.name == constants.spidertron_requester_chest or 
				   entity.name == constants.spidertron_provider_chest or 
				   entity.name == constants.spidertron_logistic_beacon then
					-- Draw connection lines
					rendering.draw_connection_lines(entity)
				end
			end
		end
	end
	
	-- Draw flashing icons for spiders that can't dump items
	for unit_number, spider_data in pairs(storage.spiders) do
		if spider_data.status == constants.dumping_items then
			local spider = spider_data.entity
			if spider and spider.valid then
				rendering.draw_dump_failed_icon(spider, spider_data)
			end
		end
	end
end)

script.on_init(setup)
script.on_configuration_changed(setup)
