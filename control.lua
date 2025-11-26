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
local route_planning = require('lib.route_planning')

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
			beacon_assignment.assign_chest_to_nearest_beacon(entity, nil, "gui_opened_no_beacon")
			if requester_data.beacon_owner then
				-- logging.info("Beacon", "Assigned requester to beacon " .. requester_data.beacon_owner)
			else
				rendering.draw_error_text(entity, "No beacon found!")
			end
		else
			-- Verify beacon still exists and is valid
			local beacon_data = storage.beacons[requester_data.beacon_owner]
			if not beacon_data or not beacon_data.entity or not beacon_data.entity.valid then
				-- logging.warn("Beacon", "Requester's beacon " .. requester_data.beacon_owner .. " is invalid, reassigning...")
				requester_data.beacon_owner = nil
				beacon_assignment.assign_chest_to_nearest_beacon(entity, nil, "gui_opened_invalid_beacon")
				if requester_data.beacon_owner then
					-- logging.info("Beacon", "Reassigned requester to beacon " .. requester_data.beacon_owner)
				else
					rendering.draw_error_text(entity, "No beacon found!")
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
								beacon_assignment.assign_chest_to_nearest_beacon(requester, nil, "gui_confirm_no_beacon")
								if requester_data.beacon_owner then
									-- logging.info("Beacon", "Assigned requester to beacon " .. requester_data.beacon_owner)
								else
									rendering.draw_error_text(requester, "No beacon found!")
								end
							else
								-- Verify beacon still exists and is valid
								local beacon_data = storage.beacons[requester_data.beacon_owner]
								if not beacon_data or not beacon_data.entity or not beacon_data.entity.valid then
									-- logging.warn("Beacon", "Requester's beacon " .. requester_data.beacon_owner .. " is invalid, reassigning...")
									requester_data.beacon_owner = nil
									beacon_assignment.assign_chest_to_nearest_beacon(requester, nil, "gui_confirm_invalid_beacon")
									if requester_data.beacon_owner then
										-- logging.info("Beacon", "Reassigned requester to beacon " .. requester_data.beacon_owner)
									else
										rendering.draw_error_text(requester, "No beacon found!")
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
					-- Right-click to clear slot
					if event.button == defines.mouse_button_type.right then
						local requester_data = gui_data.last_opened_requester
						if requester_data and requester_data.requested_items then
							-- Build sorted item list to find item at this slot position
							local item_list = {}
							for item_name, count in pairs(requester_data.requested_items) do
								if count > 0 and item_name and item_name ~= '' then
									table.insert(item_list, {name = item_name, count = count})
								end
							end
							table.sort(item_list, function(a, b) return a.name < b.name end)
							
							-- Remove item at this slot position
							if i <= #item_list then
								requester_data.requested_items[item_list[i].name] = nil
								-- Update GUI
								gui.update_requester_gui(gui_data, requester_data)
							end
						end
					else
						-- Left-click to open item selector modal
						gui.open_item_selector_gui(player_index, i, gui_data, gui_data.last_opened_requester)
					end
					return
				end
			end
		end
	end
	
	-- Handle manual dump button click
	if element.name == 'spidertron_manual_dump_button' then
		local vehicle = player.opened
		if vehicle and vehicle.valid and vehicle.type == 'spider-vehicle' then
			local spider_data = storage.spiders[vehicle.unit_number]
			if spider_data then
				local spider = spider_data.entity
				if spider and spider.valid then
					-- Trigger manual dump
					journey.attempt_dump_items(vehicle.unit_number)
				end
			end
		end
		return
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

-- Helper function to get spidertron's logistic requests (uses utils function)
local function get_spider_logistic_requests(spider)
	return utils.get_spider_logistic_requests(spider)
end

-- Main logistics update loop
script.on_nth_tick(constants.update_cooldown, function(event)
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
					
					-- Get spidertron's logistic requests to avoid dumping requested items
					local logistic_requests = get_spider_logistic_requests(spider)

					-- Try to dump items
					-- Iterate through inventory slots directly instead of using get_contents()
					local trunk = spider.get_inventory(defines.inventory.spider_trunk)
					if not trunk then
						journey.end_journey(unit_number, true)
						return
					end

					-- logging.info("Dump", "Spider trunk found, iterating through " .. #trunk .. " slots")

					local dumped_any = false
					local processed_items = {}  -- Track which items we've already decided on
					local item_excess = {}  -- Cache the excess amount for each item

					-- First pass: calculate excess for each item type
					for i = 1, #trunk do
						local stack = trunk[i]
						if stack and stack.valid_for_read and stack.count > 0 then
							local item_name = stack.name
							
							-- Skip if we've already calculated excess for this item
							if processed_items[item_name] then goto next_calc_slot end
							
							-- Get total count of this item in spider
							local total_count = spider.get_item_count(item_name)
							local requested_count = logistic_requests[item_name] or 0
							
							if requested_count > 0 and total_count <= requested_count then
								-- Keep all of this item - it's requested and we don't have excess
								item_excess[item_name] = 0
								processed_items[item_name] = true
							elseif requested_count > 0 then
								-- Have excess beyond what's requested
								item_excess[item_name] = total_count - requested_count
							else
								-- Not requested at all - dump everything
								item_excess[item_name] = total_count
							end
							
							::next_calc_slot::
						end
					end

					-- Second pass: actually dump the excess items
					local dumped_counts = {}
					for i = 1, #trunk do
						local stack = trunk[i]
						if stack and stack.valid_for_read and stack.count > 0 then
							local item_name = stack.name
							local stack_count = stack.count
							
							-- Check if we have excess to dump
							local excess = item_excess[item_name] or 0
							if excess <= 0 then goto next_dump_slot end
							
							-- Check how much we've already dumped
							local already_dumped = dumped_counts[item_name] or 0
							local can_dump = excess - already_dumped
							
							if can_dump <= 0 then goto next_dump_slot end
							
							-- Limit to what we can actually dump from this stack
							local to_dump = math.min(stack_count, can_dump)
							
							-- Get chest inventory
							local chest_inv = dump_target.get_inventory(defines.inventory.chest)
							if not chest_inv then goto next_dump_slot end
							
							-- Try to insert
							local inserted = chest_inv.insert{name = item_name, count = to_dump}
							
							if inserted > 0 then
								local removed = spider.remove_item{name = item_name, count = inserted}
								dumped_any = true
								dumped_counts[item_name] = (dumped_counts[item_name] or 0) + inserted
							end
							
							::next_dump_slot::
						end
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
						spider_data.dump_target = nil
						journey.end_journey(unit_number, true)
					elseif not dumped_any then
						-- Couldn't dump anything - check if we have any dumpable items left
						local has_dumpable = false
						
						for i = 1, #trunk do
							local stack = trunk[i]
							if stack and stack.valid_for_read and stack.count > 0 then
								local item_name = stack.name
								local total_count = spider.get_item_count(item_name)
								local requested_count = logistic_requests[item_name] or 0
								
								if requested_count == 0 or total_count > requested_count then
									has_dumpable = true
									break
								end
							end
						end
						
						if has_dumpable then
							-- Try to find another chest
							spider_data.dump_target = nil
							journey.attempt_dump_items(unit_number)
						else
							-- No dumpable items, done
							spider_data.dump_target = nil
							journey.end_journey(unit_number, true)
						end
					end
				end
			end
			
			::next_dumping_spider::
		end
	end
	
	-- Re-validate beacon assignments periodically
	-- Check all chests every 10 ticks to ensure they have valid beacon assignments
	if event.tick % 10 == 0 then
		-- Check all requesters every 10 ticks (no modulo - same as providers)
		for unit_number, requester_data in pairs(storage.requesters) do
			if requester_data.entity and requester_data.entity.valid then
				if not requester_data.beacon_owner then
					beacon_assignment.assign_chest_to_nearest_beacon(requester_data.entity, nil, "periodic_validation_no_beacon")
				else
					local beacon_data = storage.beacons[requester_data.beacon_owner]
					if not beacon_data or not beacon_data.entity or not beacon_data.entity.valid then
						requester_data.beacon_owner = nil
						beacon_assignment.assign_chest_to_nearest_beacon(requester_data.entity, nil, "periodic_validation_invalid_beacon")
					end
				end
			end
		end
		
		-- Check all providers every 10 ticks
		for _, provider_data in pairs(storage.providers) do
			if provider_data.entity and provider_data.entity.valid then
				if not provider_data.beacon_owner then
					beacon_assignment.assign_chest_to_nearest_beacon(provider_data.entity, nil, "periodic_validation_no_beacon")
				else
					-- Verify beacon still exists and is valid
					local beacon_data = storage.beacons[provider_data.beacon_owner]
					if not beacon_data or not beacon_data.entity or not beacon_data.entity.valid then
						provider_data.beacon_owner = nil
						beacon_assignment.assign_chest_to_nearest_beacon(provider_data.entity, nil, "periodic_validation_invalid_beacon")
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
			logging.debug("Logistics", "Network " .. network_key .. " has no providers")
			goto next_network 
		end
		-- logging.debug("Logistics", "Network " .. network_key .. " has " .. #providers_for_network .. " providers")
		
		local spiders_on_network = spiders_list[network_key]
		if not spiders_on_network or #spiders_on_network == 0 then 
			logging.debug("Logistics", "Network " .. network_key .. " has no available spiders")
			goto next_network
		end
		-- logging.debug("Logistics", "Network " .. network_key .. " has " .. #spiders_on_network .. " available spiders")
		
		-- Check for mixed routes (multi-pickup + multi-delivery) BEFORE grouping by requester
		-- This allows us to see ALL requesters needing the same item across all requester groups
		local best_spider_pos = nil
		if #spiders_on_network > 0 then
			best_spider_pos = spiders_on_network[1].position
		end
		
		if best_spider_pos then
			-- Feature 5: Check for multi-item, multi-requester route (different items, multiple providers, multiple requesters)
			-- This should be checked first as it's the most general case
			local multi_item_multi_req_route = route_planning.find_multi_item_multi_requester_route(requesters, providers_for_network, best_spider_pos)
			if multi_item_multi_req_route then
				local assigned = logistics.assign_spider_with_route(spiders_on_network, multi_item_multi_req_route, "multi_item_multi_requester")
				if assigned then
					-- logging.info("Assignment", "✓ Multi-item, multi-requester route assignment SUCCESSFUL")
					-- Mark all affected requests as assigned
					for _, item_req in ipairs(requesters) do
						if item_req.real_amount > 0 then
							item_req.real_amount = 0
						end
					end
					if #spiders_on_network == 0 then
						goto next_network
					end
					goto next_network
				end
			end
			
			-- Group ALL requests by item type (across all requesters)
			local all_requests_by_item = {}
			for _, item_request in ipairs(requesters) do
				local item = item_request.requested_item
				if item and item_request.real_amount > 0 then
					if not all_requests_by_item[item] then
						all_requests_by_item[item] = {}
					end
					table.insert(all_requests_by_item[item], item_request)
				end
			end
			
			-- Check for mixed routes for each item
			for item, item_requests_list in pairs(all_requests_by_item) do
				-- Need at least 2 requesters for this item to consider mixed route
				if #item_requests_list >= 2 then
					-- Calculate total needed
					local total_needed = 0
					for _, item_req in ipairs(item_requests_list) do
						total_needed = total_needed + item_req.real_amount
					end
					
					local mixed_route = route_planning.find_mixed_route(item, total_needed, providers_for_network, requesters, best_spider_pos)
					if mixed_route then
						local assigned = logistics.assign_spider_with_route(spiders_on_network, mixed_route, "mixed")
						if assigned then
							-- logging.info("Assignment", "✓ Mixed route assignment SUCCESSFUL")
							-- Mark all affected requests as assigned
							for _, item_req in ipairs(item_requests_list) do
								item_req.real_amount = 0
							end
							if #spiders_on_network == 0 then
								goto next_network
							end
							-- Continue to next network (all requests for this item are assigned)
							goto next_network
						end
					end
				end
			end
		end
		
		-- Group requests by requester for multi-item route detection
		local requests_by_requester = {}
		for _, item_request in ipairs(requesters) do
			local requester_data = item_request.requester_data
			local requester_unit_number = requester_data.entity.unit_number
			if not requests_by_requester[requester_unit_number] then
				requests_by_requester[requester_unit_number] = {}
			end
			table.insert(requests_by_requester[requester_unit_number], item_request)
		end
		
		-- Process each requester's requests
		for requester_unit_number, requester_item_requests in pairs(requests_by_requester) do
			local first_request = requester_item_requests[1]
			local requester_data = first_request.requester_data
			local requester = requester_data.entity
			
			-- Feature 3: Check for multi-item route (one requester, multiple items)
			if #requester_item_requests >= 2 then
				local requested_items = {}
				for _, item_req in ipairs(requester_item_requests) do
					if item_req.requested_item and item_req.real_amount > 0 then
						requested_items[item_req.requested_item] = item_req.real_amount
					end
				end
				
				if next(requested_items) then
					-- Find best spider position for route comparison
					local best_spider_pos = nil
					local best_spider = nil
					if #spiders_on_network > 0 then
						best_spider = spiders_on_network[1]
						best_spider_pos = best_spider.position
					else
						goto skip_multi_item
					end
					
					-- Try to find multi-item route
					local multi_item_route = route_planning.find_multi_item_route(requester, requested_items, providers_for_network, best_spider_pos)
					if multi_item_route then
						local assigned = logistics.assign_spider_with_route(spiders_on_network, multi_item_route, "multi_item")
						if assigned then
							-- logging.info("Assignment", "✓ Multi-item route assignment SUCCESSFUL")
							-- Mark all items in this route as assigned
							for _, item_req in ipairs(requester_item_requests) do
								item_req.real_amount = 0  -- Mark as assigned
							end
							if #spiders_on_network == 0 then
								goto next_network
							end
							goto next_requester_group
						end
					end
				end
			end
			
			::skip_multi_item::
			
			-- Process each item request for this requester
			for _, item_request in ipairs(requester_item_requests) do
				local item = item_request.requested_item
				if not item or item_request.real_amount <= 0 then goto next_item_request end
				
				-- logging.debug("Logistics", "Processing request: " .. item .. " x" .. item_request.real_amount .. " for requester at (" .. math.floor(requester.position.x) .. "," .. math.floor(requester.position.y) .. ")")
				
				-- Feature 1: Check for multi-pickup route (multiple providers for same item)
				if best_spider_pos then
					local multi_pickup_route = route_planning.find_multi_pickup_route(requester, item, item_request.real_amount, providers_for_network, best_spider_pos)
					if multi_pickup_route then
						local assigned = logistics.assign_spider_with_route(spiders_on_network, multi_pickup_route, "multi_pickup")
						if assigned then
							-- logging.info("Assignment", "✓ Multi-pickup route assignment SUCCESSFUL")
							item_request.real_amount = 0  -- Mark as assigned
							if #spiders_on_network == 0 then
								goto next_network
							end
							goto next_item_request
						end
					end
				end
				
				-- Feature 2: Check for multi-delivery route (one provider, multiple requesters)
				-- Find best provider first
				local max = 0
				local best_provider
				for _, provider_data in ipairs(providers_for_network) do
					local provider = provider_data.entity
					if not provider or not provider.valid then goto next_provider end
					
					local item_count = 0
					local allocated = 0
					
					if provider_data.is_robot_chest then
						if provider_data.contains and provider_data.contains[item] then
							item_count = provider_data.contains[item]
						else
							item_count = provider.get_inventory(defines.inventory.chest).get_item_count(item)
						end
						allocated = 0
					else
						item_count = provider.get_inventory(defines.inventory.chest).get_item_count(item)
						if not provider_data.allocated_items then
							provider_data.allocated_items = {}
						end
						allocated = provider_data.allocated_items[item] or 0
					end
					
					if item_count <= 0 then goto next_provider end
					
					local can_provide = item_count - allocated
					if can_provide > 0 and can_provide > max then
						max = can_provide
						best_provider = provider_data
					end
					
					::next_provider::
				end
				
				if best_provider and max > 0 then
					-- Check for multi-delivery route
					if best_spider_pos then
						local multi_delivery_route = route_planning.find_multi_delivery_route(best_provider.entity, item, max, requesters, best_spider_pos)
						if multi_delivery_route then
							local assigned = logistics.assign_spider_with_route(spiders_on_network, multi_delivery_route, "multi_delivery")
							if assigned then
								-- logging.info("Assignment", "✓ Multi-delivery route assignment SUCCESSFUL")
								-- Mark all affected requests as assigned
								for _, req in ipairs(requesters) do
									if req.requested_item == item and req.requester_data.entity.unit_number ~= requester_unit_number then
										-- Check if this requester is in the route
										for _, stop in ipairs(multi_delivery_route) do
											if stop.type == "delivery" and stop.entity.unit_number == req.requester_data.entity.unit_number then
												req.real_amount = math.max(0, req.real_amount - stop.amount)
												break
											end
										end
									end
								end
								item_request.real_amount = 0  -- Mark as assigned
								if #spiders_on_network == 0 then
									goto next_network
								end
								goto next_item_request
							end
						end
					end
					
					-- Fallback to single assignment
					-- Check if we should delay this assignment to batch more items
					if logistics.should_delay_assignment(requester_data, best_provider, max, item_request.real_amount, item_request.percentage_filled) then
						logging.debug("Logistics", "Delaying assignment for " .. item .. " (can_provide=" .. max .. 
							", real_amount=" .. item_request.real_amount .. ") - waiting for more items")
						goto next_item_request  -- Skip this assignment, try again next cycle
					end
					
					-- Create a temporary requester_data-like object for assign_spider
					local temp_requester = {
						entity = requester_data.entity,
						requested_item = item,
						real_amount = item_request.real_amount,
						incoming_items = requester_data.incoming_items
					}
					-- logging.info("Assignment", "Found provider with " .. max .. " " .. item .. " available")
					-- logging.info("Assignment", "Attempting to assign spider for " .. item .. " x" .. max)
					local assigned = logistics.assign_spider(spiders_on_network, temp_requester, best_provider, max)
					if assigned then
						-- logging.info("Assignment", "✓ Spider assignment SUCCESSFUL")
					else
						logging.warn("Assignment", "✗ Spider assignment FAILED (no available spiders or inventory full)")
					end
					if not assigned then
						goto next_item_request
					end
					if #spiders_on_network == 0 then
						goto next_network
					end
				else
					if best_provider == nil then
						logging.debug("Logistics", "No provider found for " .. item)
					elseif max <= 0 then
						logging.debug("Logistics", "Provider found but has 0 items available for " .. item)
					end
				end
				
				::next_item_request::
			end
			
			::next_requester_group::
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
		-- For routes, requester_target may be nil (we're picking up first)
		-- Only require requester_target for non-route pickups
		if not spider_data.route then
			if not spider_data.requester_target or not spider_data.requester_target.valid then
				-- logging.warn("Journey", "Spider " .. unit_number .. " cancelling: requester_target invalid (status: picking_up, no route)")
				journey.end_journey(unit_number, true)
				return
			end
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
	local requester_data = nil
	if requester and requester.valid then
		requester_data = storage.requesters[requester.unit_number]
	end
	
	if spider_data.status == constants.picking_up then
		local provider = spider_data.provider_target
		
		if not provider or not provider.valid then
			logging.warn("Pickup", "Provider target is invalid!")
			journey.end_journey(unit_number, true)
			return
		end
		
		-- Verify spider is actually close enough to the provider
		local distance_to_provider = utils.distance(spider.position, provider.position)
		if distance_to_provider > 6 then
			-- Spider not close enough yet, wait for next command completion
			return
		end
		
		-- Clear any remaining autopilot destinations to ensure spider stops
		if spider.autopilot_destinations and #spider.autopilot_destinations > 0 then
			spider.autopilot_destination = nil
		end
		
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
		if not item then
			logging.warn("Pickup", "Spider " .. unit_number .. " cancelling: item is nil")
			journey.end_journey(unit_number, true)
			return
		end
		
		local provider_inventory = provider.get_inventory(defines.inventory.chest)
		local contains = 0
		if provider_inventory then
			contains = provider_inventory.get_item_count(item) or 0
		else
			logging.warn("Pickup", "Provider has no inventory")
			journey.end_journey(unit_number, true)
			return
		end
		
		-- For routes, get the stop's amount (what this provider should give)
		-- For non-routes, use item_count
		local stop_amount = item_count
		if spider_data.route and spider_data.current_route_index then
			local current_stop = spider_data.route[spider_data.current_route_index]
			if current_stop and current_stop.amount then
				stop_amount = current_stop.amount
			end
		end
		
		-- Get spider trunk inventory
		local trunk = spider.get_inventory(defines.inventory.spider_trunk)
		if not trunk then
			logging.warn("Pickup", "Spider has no trunk inventory")
			journey.end_journey(unit_number, true)
			return
		end
		
		-- Get how many items spider already has
		local already_had = spider.get_item_count(item)
		
		-- Check how much we can actually insert (respects stack sizes and inventory limits)
		-- trunk.can_insert() is boolean, so we need to calculate the actual limit
		local max_can_insert = 0
		if trunk.can_insert({name = item, count = 1}) then
			-- Spider can insert at least 1, calculate how many
			local stack_size = utils.stack_size(item)
			
			-- Calculate space in existing stacks of this item
			local space_in_existing = 0
			for i = 1, #trunk do
				local stack = trunk[i]
				if stack and stack.valid_for_read and stack.name == item then
					space_in_existing = space_in_existing + (stack_size - stack.count)
				end
			end
			
			-- Calculate space in empty slots
			local empty_slots = trunk.count_empty_stacks(false, false)
			local space_in_empty = empty_slots * stack_size
			
			-- Total space available
			max_can_insert = space_in_existing + space_in_empty
		end
		
		-- Limit to what provider has and what this stop should provide
		local can_insert = min(max_can_insert, contains, stop_amount)
		
		
		if can_insert <= 0 then
			-- If we already have some items and this is a route, continue with route
			if already_had > 0 and spider_data.route and spider_data.current_route_index then
				-- Update payload and continue
				if not spider_data.route_payload then
					spider_data.route_payload = {}
				end
				spider_data.route_payload[item] = already_had
				spider_data.payload_item_count = already_had
				-- Advance route
				local advanced = journey.advance_route(unit_number)
				if not advanced then
					return
				end
				return
			end
			journey.end_journey(unit_number, true)
			return
		end
		
		local actually_inserted = spider.insert{name = item, count = can_insert}
		
		if actually_inserted == 0 and already_had == 0 then
			logging.warn("Pickup", "Spider " .. unit_number .. " cancelling: failed to insert items (can_insert: " .. can_insert .. ", actually_inserted: " .. actually_inserted .. ", already_had: " .. already_had .. ")")
			journey.end_journey(unit_number, true)
			return
		end
		
		if actually_inserted ~= 0 then
			provider.remove_item{name = item, count = actually_inserted}
			-- Track pickup_count for custom provider chests
			if not is_robot_chest and provider_data then
				provider_data.pickup_count = (provider_data.pickup_count or 0) + actually_inserted
			elseif is_robot_chest then
				-- For robot chests, assign pickup count to nearest spidertron provider depot
				local nearest_provider = beacon_assignment.find_nearest_provider_chest(provider.surface, provider.position, provider.force)
				if nearest_provider then
					local nearest_provider_data = storage.providers[nearest_provider.unit_number]
					if nearest_provider_data then
						nearest_provider_data.pickup_count = (nearest_provider_data.pickup_count or 0) + actually_inserted
					end
				end
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
		
		-- Update payload count - for routes, accumulate items from multiple pickups
		if spider_data.route and spider_data.current_route_index then
			-- In a route, accumulate items
			local current_stop = spider_data.route[spider_data.current_route_index]
			if current_stop then
				-- Update the stop with actual amount picked up
				current_stop.actual_amount = actually_inserted
				-- Accumulate total payload
				if not spider_data.route_payload then
					spider_data.route_payload = {}
				end
				spider_data.route_payload[item] = (spider_data.route_payload[item] or 0) + actually_inserted
				spider_data.payload_item_count = spider_data.route_payload[item] or 0
			end
		else
			-- Single pickup, update normally
			spider_data.payload_item_count = actually_inserted + already_had
		end
		
		-- Update incoming_items: subtract original expected amount, add back what was actually picked up
		-- For routes, we'll update incoming_items when we deliver
		if not spider_data.route then
			if not requester_data.incoming_items then
				requester_data.incoming_items = {}
			end
			requester_data.incoming_items[item] = (requester_data.incoming_items[item] or 0) - item_count + actually_inserted + already_had
			if requester_data.incoming_items[item] <= 0 then
				requester_data.incoming_items[item] = nil
			end
		end
		
		-- Only proceed to next destination if we actually have items
		if spider_data.payload_item_count > 0 then
			-- Check if spider has a route - if so, advance to next stop
			if spider_data.route and spider_data.current_route_index then
				local advanced = journey.advance_route(unit_number)
				if not advanced then
					-- Route complete or failed, journey already ended
					return
				end
			else
				-- No route, proceed with single pickup/delivery
				-- logging.info("Pickup", "Pickup successful: " .. spider_data.payload_item_count .. " items, setting destination to requester")
				-- Set status to dropping_off and set destination to requester
				spider_data.status = constants.dropping_off
				
				-- Use pre-validated requester path if available (from dual-path validation)
				if spider_data.requester_path_waypoints and spider_data.requester_path_target then
					-- Apply pre-validated waypoints
					spider.autopilot_destination = nil
					
					local spider_pos = spider.position
					local min_distance = math.huge
					local start_index = 1
					
					for i, wp in ipairs(spider_data.requester_path_waypoints) do
						local pos = wp.position or wp
						local dist = math.sqrt((pos.x - spider_pos.x)^2 + (pos.y - spider_pos.y)^2)
						if dist < min_distance then
							min_distance = dist
							start_index = i
						end
					end
					
					local last_pos = spider_pos
					local min_spacing = (spider.prototype.height + 0.5) * 7.5
					
					for i = start_index + 1, #spider_data.requester_path_waypoints do
						local wp = spider_data.requester_path_waypoints[i].position or spider_data.requester_path_waypoints[i]
						local dist = math.sqrt((wp.x - last_pos.x)^2 + (wp.y - last_pos.y)^2)
						
						if dist > min_spacing then
							spider.add_autopilot_destination(wp)
							last_pos = wp
						end
					end
					
					local waypoint_count = #spider_data.requester_path_waypoints
					spider.add_autopilot_destination(spider_data.requester_path_target)
					
					-- Clean up stored path data
					spider_data.requester_path_waypoints = nil
					spider_data.requester_path_target = nil
					
					logging.info("Pickup", "Applied pre-validated requester path (" .. waypoint_count .. " waypoints)")
				else
					-- No pre-validated path (shouldn't happen with dual-path validation, but fallback)
					local pathing_success = pathing.set_smart_destination(spider, spider_data.requester_target.position, spider_data.requester_target)
					if not pathing_success then
						-- logging.warn("Pickup", "Pathfinding to requester failed after pickup, cancelling journey")
						journey.end_journey(unit_number, true)
					end
				end
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
		
		-- Handle delivery - check if this is a route with multi-item delivery
		local items_to_deliver = {}
		if spider_data.route and spider_data.current_route_index then
			local current_stop = spider_data.route[spider_data.current_route_index]
			if current_stop and current_stop.type == "delivery" then
				if current_stop.items then
					-- Multi-item delivery - deliver all requested items
					for req_item, req_amount in pairs(current_stop.items) do
						local spider_has = spider.get_item_count(req_item)
						if spider_has > 0 then
							items_to_deliver[req_item] = math.min(spider_has, req_amount)
						end
					end
				elseif current_stop.item then
					-- Single item delivery
					local spider_item_count = spider.get_item_count(current_stop.item)
					if spider_item_count > 0 then
						items_to_deliver[current_stop.item] = math.min(spider_item_count, current_stop.amount or spider_item_count)
					end
				end
			end
		else
			-- Single delivery, use existing logic
			local spider_item_count = spider.get_item_count(item)
			local can_insert = min(spider_item_count, item_count)
			if can_insert > 0 then
				items_to_deliver[item] = can_insert
			end
		end
		
		-- Deliver all items
		local total_delivered = 0
		for deliver_item, deliver_amount in pairs(items_to_deliver) do
			if deliver_amount > 0 and requester.can_insert(deliver_item) then
				local actually_inserted = requester.insert{name = deliver_item, count = deliver_amount}
				if actually_inserted > 0 then
					local removed = spider.remove_item{name = deliver_item, count = actually_inserted}
					if removed > 0 then
						total_delivered = total_delivered + actually_inserted
						requester_data.dropoff_count = (requester_data.dropoff_count or 0) + actually_inserted
						
						-- Update incoming_items
						if not requester_data.incoming_items then
							requester_data.incoming_items = {}
						end
						requester_data.incoming_items[deliver_item] = (requester_data.incoming_items[deliver_item] or 0) - actually_inserted
						if requester_data.incoming_items[deliver_item] <= 0 then
							requester_data.incoming_items[deliver_item] = nil
						end
						
						-- Update route payload if in route
						if spider_data.route and spider_data.route_payload then
							spider_data.route_payload[deliver_item] = (spider_data.route_payload[deliver_item] or 0) - actually_inserted
							if spider_data.route_payload[deliver_item] <= 0 then
								spider_data.route_payload[deliver_item] = nil
							end
						end
					end
				end
			end
		end
		
		if total_delivered > 0 then
			rendering.draw_deposit_icon(requester)
		end
		
		-- Check if delivery was successful (items were removed from spider)
		local delivery_successful = false
		if spider_data.route and spider_data.current_route_index then
			-- For routes, check if we delivered what we intended
			local current_stop = spider_data.route[spider_data.current_route_index]
			if current_stop then
				if current_stop.items then
					-- Multi-item: check if we delivered at least some items
					delivery_successful = total_delivered > 0
				elseif current_stop.item then
					-- Single item: check if we have less of this item now
					local remaining = spider.get_item_count(current_stop.item)
					local had_before = (spider_data.route_payload and spider_data.route_payload[current_stop.item]) or 0
					delivery_successful = remaining < had_before or total_delivered > 0
				end
			end
		else
			-- Single delivery: check if items were removed
			local spider_item_count = spider.get_item_count(item) + total_delivered  -- What we had before delivery
			local remaining_spider_count = spider.get_item_count(item)
			delivery_successful = remaining_spider_count < spider_item_count or total_delivered > 0
		end
		
		if not delivery_successful and total_delivered == 0 then
			-- Delivery failed - retry
			if not spider_data.dropoff_retry_count then
				spider_data.dropoff_retry_count = 0
			end
			spider_data.dropoff_retry_count = spider_data.dropoff_retry_count + 1
			
			if spider_data.dropoff_retry_count > 5 then
				journey.end_journey(unit_number, true)
				return
			end
			
			if requester and requester.valid then
				pathing.set_smart_destination(spider, requester.position, requester)
			else
				journey.end_journey(unit_number, true)
			end
			return
		end
		
		-- Successfully dropped off, reset retry counter
		spider_data.dropoff_retry_count = nil
		
		-- logging.info("Dropoff", "Dropoff successful: " .. total_delivered .. " items delivered")
		
		-- Check if spider has a route - if so, advance to next stop
		if spider_data.route and spider_data.current_route_index then
			local advanced = journey.advance_route(unit_number)
			if not advanced then
				-- Route complete or failed, journey already ended
				return
			end
		else
			-- No route, end journey normally
			journey.end_journey(unit_number, true)
			journey.deposit_already_had(spider_data)
		end
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
		
		-- Get spidertron's logistic requests to avoid dumping requested items
		local logistic_requests = get_spider_logistic_requests(spider)
		
		-- Try to dump items
		local trunk = spider.get_inventory(defines.inventory.spider_trunk)
		if not trunk then
			journey.end_journey(unit_number, true)
			return
		end
		
		local contents = trunk.get_contents()
		if not contents or next(contents) == nil then
			-- No items left, done dumping
			spider_data.dump_target = nil
			journey.end_journey(unit_number, true)
			return
		end
		
		-- Try to insert items into storage chest
		local dumped_any = false
		for item_name, item_data in pairs(contents) do
			-- Handle new format
			local actual_item_name = item_name
			local item_count = 0
			
			if type(item_data) == "table" and item_data.name then
				actual_item_name = item_data.name
				item_count = item_data.count or 0
			elseif type(item_data) == "number" then
				item_count = item_data
			elseif type(item_data) == "table" then
				for quality, qty in pairs(item_data) do
					if type(qty) == "number" then
						item_count = item_count + qty
					end
				end
			end
			
			if not actual_item_name or actual_item_name == "" or item_count <= 0 then
				goto next_dump_item
			end
			
			-- Get how many items the spider actually has
			local spider_has = spider.get_item_count(actual_item_name)
			if spider_has > item_count then spider_has = item_count end
			
			-- Check if this item is requested
			local requested_count = logistic_requests[actual_item_name] or 0
			if requested_count > 0 then
				-- Only dump excess
				if spider_has <= requested_count then
					goto next_dump_item
				else
					spider_has = spider_has - requested_count
					if spider_has <= 0 then
						goto next_dump_item
					end
				end
			end
			
			if spider_has > 0 then
				local inserted = dump_target.insert{name = actual_item_name, count = spider_has}
				
				if inserted > 0 then
					local removed = spider.remove_item{name = actual_item_name, count = inserted}
					if removed > 0 then
						dumped_any = true
					end
				end
			end
			::next_dump_item::
		end
		
		if dumped_any then
			-- Check if there are more dumpable items
			local remaining_contents = trunk.get_contents()
			if not remaining_contents or next(remaining_contents) == nil then
				-- All items dumped
				spider_data.dump_target = nil
				journey.end_journey(unit_number, true)
				return
			end
			
			-- Check if remaining items are dumpable
			local has_more_dumpable = false
			
			for item_name, item_data in pairs(remaining_contents) do
				local actual_item_name = item_name
				local item_count = 0
				
				if type(item_data) == "table" and item_data.name then
					actual_item_name = item_data.name
					item_count = item_data.count or 0
				elseif type(item_data) == "number" then
					item_count = item_data
				elseif type(item_data) == "table" then
					for quality, qty in pairs(item_data) do
						if type(qty) == "number" then
							item_count = item_count + qty
						end
					end
				end
				
				if item_count > 0 and actual_item_name and actual_item_name ~= "" then
					local requested = logistic_requests[actual_item_name] or 0
					local total = spider.get_item_count(actual_item_name)
					if requested == 0 or total > requested then
						has_more_dumpable = true
						break
					end
				end
			end
			
			if has_more_dumpable then
				-- Find another chest
				spider_data.dump_target = nil
				journey.attempt_dump_items(unit_number)
			else
				-- Done dumping
				spider_data.dump_target = nil
				journey.end_journey(unit_number, true)
			end
		else
			-- Couldn't dump anything
			spider_data.dump_target = nil
			journey.attempt_dump_items(unit_number)
		end
	end
end)

local function handle_entity_removal(event)
	local entity = event.entity or event.created_entity
	local unit_number = event.unit_number or (entity and entity.unit_number)
	
	if not unit_number then return end
	
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
			-- Make a copy of the list since we'll be modifying it
			local chests_to_reassign = {}
			for _, chest_unit_number in ipairs(beacon_data.assigned_chests) do
				table.insert(chests_to_reassign, chest_unit_number)
			end
			
			-- CRITICAL: Remove beacon from storage BEFORE reassignment
			-- This ensures find_nearest_beacon won't find it in storage validation
			storage.beacons[unit_number] = nil
			-- logging.info("Beacon", "Beacon " .. unit_number .. " removed from storage before reassignment")
			
			-- First, unassign all chests from this beacon
			-- logging.info("Beacon", "Unassigning " .. #chests_to_reassign .. " chests from destroyed beacon " .. unit_number)
			for _, chest_unit_number in ipairs(chests_to_reassign) do
				beacon_assignment.unassign_chest_from_beacon(chest_unit_number)
			end
			
			-- Then, reassign each chest to the nearest available beacon (excluding the destroyed one)
			-- Use assign_chest_to_nearest_beacon which properly handles both providers and requesters
			-- logging.info("Beacon", "Reassigning " .. #chests_to_reassign .. " chests to nearest beacons")
			for _, chest_unit_number in ipairs(chests_to_reassign) do
				local chest = nil
				local chest_type = "unknown"
				
				if storage.providers[chest_unit_number] then
					chest = storage.providers[chest_unit_number].entity
					chest_type = "provider"
					-- logging.info("Beacon", "Reassigning provider chest " .. chest_unit_number .. " (entity valid: " .. tostring(chest and chest.valid) .. ")")
				elseif storage.requesters[chest_unit_number] then
					chest = storage.requesters[chest_unit_number].entity
					chest_type = "requester"
					-- logging.info("Beacon", "Reassigning requester chest " .. chest_unit_number .. " (entity valid: " .. tostring(chest and chest.valid) .. ")")
				else
					-- logging.warn("Beacon", "Chest " .. chest_unit_number .. " not found in providers or requesters storage")
				end
				
				if chest and chest.valid then
					-- Use assign_chest_to_nearest_beacon which properly handles both providers and requesters
					-- Pass the destroyed beacon's unit_number to exclude it from the search
					-- logging.info("Beacon", "Calling assign_chest_to_nearest_beacon for " .. chest_type .. " chest " .. chest_unit_number .. " (excluding beacon " .. unit_number .. ")")
					beacon_assignment.assign_chest_to_nearest_beacon(chest, unit_number, "beacon_removal")
					
					-- Verify assignment succeeded
					if chest_type == "provider" and storage.providers[chest_unit_number] then
						local new_beacon = storage.providers[chest_unit_number].beacon_owner
						if new_beacon then
							-- logging.info("Beacon", "Provider chest " .. chest_unit_number .. " successfully reassigned to beacon " .. new_beacon)
						else
							-- logging.warn("Beacon", "Provider chest " .. chest_unit_number .. " reassignment FAILED - no beacon_owner set")
						end
					elseif chest_type == "requester" and storage.requesters[chest_unit_number] then
						local new_beacon = storage.requesters[chest_unit_number].beacon_owner
						if new_beacon then
							-- logging.info("Beacon", "Requester chest " .. chest_unit_number .. " successfully reassigned to beacon " .. new_beacon)
						else
							-- logging.warn("Beacon", "Requester chest " .. chest_unit_number .. " reassignment FAILED - no beacon_owner set")
						end
					end
				else
					-- logging.warn("Beacon", "Cannot reassign " .. chest_type .. " chest " .. chest_unit_number .. " - entity invalid or missing")
				end
			end
		else
			-- No chests to reassign, just clean up
			storage.beacons[unit_number] = nil
		end
		-- logging.info("Beacon", "Beacon " .. unit_number .. " cleanup complete")
	end
end

script.on_event(defines.events.on_entity_died, handle_entity_removal)
script.on_event(defines.events.on_pre_player_mined_item, handle_entity_removal)
script.on_event(defines.events.on_robot_pre_mined, handle_entity_removal)
script.on_event(defines.events.script_raised_destroy, handle_entity_removal)

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
				beacon_assignment.assign_chest_to_nearest_beacon(provider_data.entity, nil, "setup_on_load")
			end
		end
	end
	
	for _, requester_data in pairs(storage.requesters) do
		if requester_data.entity and requester_data.entity.valid then
			if not requester_data.beacon_owner then
				beacon_assignment.assign_chest_to_nearest_beacon(requester_data.entity, nil, "setup_on_load")
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
	
	-- Check all players for selected/hovered entities
	for _, player in pairs(game.players) do
		if player and player.valid then
			local entity = player.selected
			if entity and entity.valid then
				-- Check if it's a chest or beacon
				if entity.name == constants.spidertron_requester_chest or 
				   entity.name == constants.spidertron_provider_chest or 
				   entity.name == constants.spidertron_logistic_beacon then
					-- Draw connection lines
					rendering.draw_connection_lines(entity)
				end
				
				-- Handle beacon tooltip GUI
				-- TODO: Temporarily disabled until a better solution is found
				--[[
				if entity.name == constants.spidertron_logistic_beacon then
					local beacon_data = storage.beacons[entity.unit_number]
					if beacon_data then
						gui.add_beacon_info_frame(player, entity, beacon_data)
					end
				else
					-- Not a beacon, remove beacon GUI if it exists
					if player.gui.screen["spidertron_beacon_info_frame"] then
						player.gui.screen["spidertron_beacon_info_frame"].destroy()
					end
				end
				--]]
				-- Always remove beacon GUI if it exists (cleanup)
				if player.gui.screen["spidertron_beacon_info_frame"] then
					player.gui.screen["spidertron_beacon_info_frame"].destroy()
				end
			else
				-- No entity selected, remove beacon GUI if it exists
				if player.gui.screen["spidertron_beacon_info_frame"] then
					player.gui.screen["spidertron_beacon_info_frame"].destroy()
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

