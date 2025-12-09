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
local shared_toolbar = require("__ceelos-vehicle-gui-util__/lib/shared_toolbar")

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
		if not requester_data then 
			return 
		end
		
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
			beacon_assignment.assign_chest_to_nearest_beacon(entity, nil, "gui_opened_no_beacon")
			if not requester_data.beacon_owner then
				rendering.draw_error_text(entity, "No beacon found!")
			end
		else
			-- Verify beacon still exists and is valid
			local beacon_data = storage.beacons[requester_data.beacon_owner]
			if not beacon_data or not beacon_data.entity or not beacon_data.entity.valid then
				requester_data.beacon_owner = nil
				beacon_assignment.assign_chest_to_nearest_beacon(entity, nil, "gui_opened_invalid_beacon")
				if not requester_data.beacon_owner then
					rendering.draw_error_text(entity, "No beacon found!")
				end
			end
		end
		
		-- Ensure incoming_items is initialized
		if not requester_data.incoming_items then
			requester_data.incoming_items = {}
		end
		
		local gui_data = gui.requester_gui(event.player_index)
		if gui_data then
			gui_data.last_opened_requester = requester_data
			gui.update_requester_gui(gui_data, requester_data)
		end
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
			local player_index = event.player_index
			local gui_data = storage.requester_guis[player_index]
			
			-- If settings menu is open, confirm settings instead of closing
			if gui_data and gui_data.settings_frame and gui_data.settings_frame.valid and gui_data.settings_frame.visible then
				if gui_data.last_opened_requester and gui_data.selected_slot_index then
					local requester_data = gui_data.last_opened_requester
					local slot = gui_data.item_slots[gui_data.selected_slot_index]
					
					if slot and slot.item then
						-- Initialize requested_items if needed
						if not requester_data.requested_items then
							requester_data.requested_items = {}
						end
						
						-- Save all current settings to requester_data
						requester_data.requested_items[slot.item] = {
							count = slot.count or 50,
							buffer_threshold = slot.buffer or 0.8,
							allow_excess_provider = slot.allow_excess_provider ~= nil and slot.allow_excess_provider or true
						}
						
						-- Update entity tags so requests are copied when entity is copied
						if requester_data.entity and requester_data.entity.valid then
							registration.update_requester_entity_tags(requester_data.entity, requester_data.requested_items)
						end
						
						-- Update the GUI to show the count on the icon
						gui.update_requester_gui(gui_data, requester_data)
						
						-- Close the settings menu
						gui_data.settings_frame.visible = false
						gui_data.selected_slot_index = nil
						
						-- Reopen the entity GUI (since E would have closed it)
						if requester_data.entity and requester_data.entity.valid then
							player.opened = requester_data.entity
						end
						
						return  -- Don't clean up GUI, we're keeping it open
					end
				end
			end
			
			-- Clean up requester chest GUI when any entity GUI is closed
			-- (The GUI is anchored to container_gui, so it should be destroyed when container closes)
			-- This ensures no orphaned GUIs remain
			local relative_gui = player.gui.relative
			if relative_gui then
				-- Clean up new GUI frame by name
				local new_gui_frame = relative_gui["spidertron_requester_gui_frame"]
				if new_gui_frame and new_gui_frame.valid then
					new_gui_frame.destroy()
				end
				
				-- Clean up old GUI by name (if it had a name)
				local requester_gui = relative_gui[constants.spidertron_requester_chest]
				if requester_gui and requester_gui.valid then
					requester_gui.destroy()
				end
				
				-- CRITICAL: Clean up old flow-based GUI with no name and no anchor (the stuck one)
				for _, child in ipairs(relative_gui.children) do
					if child and child.valid and child.type == 'flow' then
						-- Check if name exists and is not empty
						local has_name = child.name ~= nil and child.name ~= ''
						local has_anchor = child.anchor ~= nil
						
						-- Destroy flows with no name and no anchor (stuck old GUI)
						if not has_name and not has_anchor then
							child.destroy()
						-- Also destroy flows with requester chest anchor
						elseif has_anchor and child.anchor.gui == defines.relative_gui_type.container_gui 
						       and child.anchor.name == constants.spidertron_requester_chest then
							child.destroy()
						end
					end
				end
			end
			
			-- Also close any open item selector modals
			local gui_data = storage.requester_guis[event.player_index]
			if gui_data then
				gui.close_item_selector_gui(gui_data)
			end
			
			-- Remove our buttons from shared toolbar when GUI is closed
			shared_toolbar.remove_from_shared_toolbar(player, "spidertron-logistics", "toggle")
			shared_toolbar.remove_from_shared_toolbar(player, "spidertron-logistics", "dump")
			
			-- Clean up legacy toggle frame if it exists (for backwards compatibility)
			if player.gui.relative["spidertron_logistics_toggle_frame"] then
				player.gui.relative["spidertron_logistics_toggle_frame"].destroy()
			end
			
			-- Optionally destroy entire toolbar if empty (or let it persist for other mods)
			local toolbar = player.gui.relative[shared_toolbar.SHARED_TOOLBAR_NAME]
			if toolbar and toolbar.valid then
				local button_frame = toolbar["button_frame"]
				if button_frame and button_frame.valid then
					local button_flow = button_frame["button_flow"]
					if button_flow and button_flow.valid and #button_flow.children == 0 then
						toolbar.destroy()
					end
				end
			end
		end
	end
end)

script.on_event(defines.events.on_gui_switch_state_changed, function(event)
	local element = event.element
	if not element or not element.valid then return end
	
	-- Handle legacy toggle switch (for backwards compatibility)
	if element.name == "spidertron_logistics_toggle_button" then
		local player = game.get_player(event.player_index)
		if not player then return end
		
		local vehicle = player.opened
		if vehicle and vehicle.valid and vehicle.type == 'spider-vehicle' then
			local spider_data = storage.spiders[vehicle.unit_number]
			if spider_data then
				local was_active = spider_data.active or false
				local new_active = (element.switch_state == "left")
				
				-- Update active state based on switch position
				-- "left" = active, "right" = inactive
				spider_data.active = new_active
				
				-- Update button color if using new button system
				local relative_gui = player.gui.relative
				if relative_gui then
					local toolbar = relative_gui[shared_toolbar.SHARED_TOOLBAR_NAME]
					if toolbar and toolbar.valid then
						local button_frame = toolbar["button_frame"]
						if button_frame and button_frame.valid then
							local button_flow = button_frame["button_flow"]
							if button_flow and button_flow.valid then
								local toggle_button = button_flow["spidertron-logistics_toggle"]
								if toggle_button and toggle_button.valid then
									gui.update_toggle_button_color(toggle_button, new_active)
								end
							end
						end
					end
				end
				
				-- Handle activation
				if new_active and not was_active then
					-- Spider is being activated
					local spider = spider_data.entity
					if spider and spider.valid then
						-- Check if spider has items to dump
						if journey.has_dumpable_items(vehicle.unit_number) then
							-- Start dumping - beacon finding will happen after dump completes
							local dump_success = journey.attempt_dump_items(vehicle.unit_number)
							-- If dump failed (no storage chests), continue to find beacon anyway
							if not dump_success then
								-- No storage chests available, find beacon immediately
								local network = beacon_assignment.spidertron_network(spider)
								if network then
									local active_beacon = beacon_assignment.find_beacon_with_highest_pickup_count(
										spider.surface, 
										spider.position, 
										spider.force,
										1000
									)
									
									if active_beacon and active_beacon.valid then
										pathing.set_smart_destination(spider, active_beacon.position, active_beacon)
									else
										local nearest_beacon = beacon_assignment.find_nearest_beacon(
											spider.surface, 
											spider.position, 
											spider.force, 
											nil, 
											"activation_fallback"
										)
										if nearest_beacon then
											pathing.set_smart_destination(spider, nearest_beacon.position, nearest_beacon)
										end
									end
								end
							end
						else
							-- No items to dump, find a beacon immediately
							local network = beacon_assignment.spidertron_network(spider)
							if network then
								-- Try to find beacon with highest pickup count
								local active_beacon = beacon_assignment.find_beacon_with_highest_pickup_count(
									spider.surface, 
									spider.position, 
									spider.force,
									1000
								)
								
								if active_beacon and active_beacon.valid then
									pathing.set_smart_destination(spider, active_beacon.position, active_beacon)
								else
									-- Fallback to nearest beacon
									local nearest_beacon = beacon_assignment.find_nearest_beacon(
										spider.surface, 
										spider.position, 
										spider.force, 
										nil, 
										"activation_fallback"
									)
									if nearest_beacon then
										pathing.set_smart_destination(spider, nearest_beacon.position, nearest_beacon)
									end
								end
							end
						end
					end
				-- Handle deactivation
				elseif not new_active and was_active then
					-- Spider is being deactivated
					local spider = spider_data.entity
					if spider and spider.valid then
						-- Stop pathing - clear autopilot destinations
						if spider.autopilot_destinations and #spider.autopilot_destinations > 0 then
							spider.autopilot_destination = nil
						end
						
						-- End current journey if any
						if spider_data.status ~= constants.idle then
							journey.end_journey(vehicle.unit_number, false)
						end
						
						-- Set to idle
						spider_data.status = constants.idle
						spider_data.provider_target = nil
						spider_data.requester_target = nil
						spider_data.payload_item = nil
						spider_data.payload_item_count = 0
						spider_data.dump_target = nil
					end
				end
				return
			end
		end
	end
end)

script.on_event(defines.events.on_gui_elem_changed, function(event)
	local element = event.element
	if not element or not element.valid then return end
	
	-- Handle item slot selection (choose-elem-button)
	if element.name and element.name:match("^spidertron_slot_") then
		local slot_index = tonumber(element.name:match("%d+"))
		local player_index = event.player_index
		local gui_data = storage.requester_guis[player_index]
		
		if not gui_data or not gui_data.last_opened_requester then return end
		
		local requester_data = gui_data.last_opened_requester
		local item_name = element.elem_value
		local current_slot_item = gui_data.item_slots[slot_index].item
		
		-- If clicking on an already-requested item (same item), just open settings instead
		if current_slot_item and current_slot_item == item_name and requester_data.requested_items and requester_data.requested_items[item_name] then
			-- Item already requested, just open settings
			gui_data.selected_slot_index = slot_index
			-- Load current values from requester_data
			local item_data = requester_data.requested_items[item_name]
			if item_data then
				-- Handle migration from old format
				if type(item_data) == "number" then
					item_data = {count = item_data, buffer_threshold = 0.8, allow_excess_provider = true}
				end
				gui_data.item_slots[slot_index].count = item_data.count or 50
				gui_data.item_slots[slot_index].buffer = item_data.buffer_threshold or 0.8
				gui_data.item_slots[slot_index].allow_excess_provider = item_data.allow_excess_provider ~= nil and item_data.allow_excess_provider or true
			end
			gui.update_settings_section(gui_data, slot_index)
			return
		end
		
		-- If clicking on a different item that's already requested elsewhere, prevent selection
		if item_name and requester_data.requested_items and requester_data.requested_items[item_name] and current_slot_item ~= item_name then
			-- Item is already requested in another slot, don't allow duplicate
			element.elem_value = current_slot_item  -- Reset to current item
			return
		end
		
		-- Update slot data
		gui_data.item_slots[slot_index].item = item_name
		gui_data.selected_slot_index = slot_index
		
		if item_name then
			-- New item selected - set default values (one stack)
			local stack_size = prototypes.item[item_name].stack_size or 50
			gui_data.item_slots[slot_index].count = stack_size
			gui_data.item_slots[slot_index].buffer = 0.8
			gui_data.item_slots[slot_index].allow_excess_provider = true
			
			-- Update slider to position 2 (1 stack) - slider has 11 positions (1 item to 10 stacks)
			if gui_data.request_amount_slider then
				gui_data.request_amount_slider.set_slider_value_step(1)
				gui_data.request_amount_slider.slider_value = 2  -- Position 2 = 1 stack
			end
			
			-- Update settings section
			gui.update_settings_section(gui_data, slot_index)
			
			-- Don't save to requester_data yet - wait for confirm button
			-- This prevents immediate delivery triggering
		else
			-- Item removed
			if requester_data.requested_items and gui_data.item_slots[slot_index].item then
				local old_item = gui_data.item_slots[slot_index].item
				requester_data.requested_items[old_item] = nil
				-- Update entity tags so requests are copied when entity is copied
				if requester_data.entity and requester_data.entity.valid then
					registration.update_requester_entity_tags(requester_data.entity, requester_data.requested_items)
				end
			end
			gui_data.item_slots[slot_index].count = 0
			gui_data.item_slots[slot_index].buffer = 0.8
			-- Hide count label
			if gui_data.item_slots[slot_index].count_label then
				gui_data.item_slots[slot_index].count_label.caption = ''
				gui_data.item_slots[slot_index].count_label.visible = false
			end
			gui_data.settings_frame.visible = false
		end
		
		return
	end
end)

script.on_event(defines.events.on_gui_text_changed, function(event)
	local element = event.element
	if not element or not element.valid then return end
	
	local gui_data = storage.requester_guis[event.player_index]
	if not gui_data or not gui_data.last_opened_requester or not gui_data.selected_slot_index then return end
	
	local requester_data = gui_data.last_opened_requester
	local slot = gui_data.item_slots[gui_data.selected_slot_index]
	
	-- Don't process textfield while typing - wait for confirmation
end)

script.on_event(defines.events.on_gui_confirmed, function(event)
	local element = event.element
	if not element or not element.valid then return end
	
	local gui_data = storage.requester_guis[event.player_index]
	if not gui_data or not gui_data.last_opened_requester or not gui_data.selected_slot_index then return end
	
	local requester_data = gui_data.last_opened_requester
	local slot = gui_data.item_slots[gui_data.selected_slot_index]
	
	-- Handle request amount textfield confirmation
	if element.name == 'request_amount_textfield' then
		local value = tonumber(element.text) or 50
		value = math.max(1, math.min(10000, math.floor(value)))  -- Max 10000, min 1
		-- Round to nearest interval (10 intervals from 1 to 10000)
		local max_value = 10000
		local interval = (max_value - 1) / 10
		value = math.floor(value / interval) * interval
		if value < 1 then value = 1 end
		element.text = tostring(value)
		if gui_data.request_amount_slider then
			-- Clamp slider value to its max
			gui_data.request_amount_slider.slider_value = math.min(value, max_value)
		elseif gui_data.request_amount_slider then
			-- No item selected, just update slider
			gui_data.request_amount_slider.slider_value = math.min(value, 500)  -- Default max
		end
		slot.count = value
		-- Update count label
		if slot.count_label then
			slot.count_label.caption = tostring(value)
			slot.count_label.visible = value > 0
		end
		-- Don't update requester_data - wait for confirm button
		return
	end
end)

script.on_event(defines.events.on_gui_value_changed, function(event)
	local element = event.element
	if not element or not element.valid then return end
	
	local gui_data = storage.requester_guis[event.player_index]
	if not gui_data or not gui_data.last_opened_requester or not gui_data.selected_slot_index then return end
	
	local requester_data = gui_data.last_opened_requester
	local slot = gui_data.item_slots[gui_data.selected_slot_index]
	
	-- Handle request amount slider - update UI only, don't save to requester_data yet
	if element.name == 'request_amount_slider' then
		local slider_position = math.floor(element.slider_value)
		-- Slider has 11 positions: 1 = 1 item, 2 = 1 stack, 3 = 2 stacks, ..., 11 = 10 stacks
		local item_count
		if not slot.item then
			-- No item selected, use default mapping
			if slider_position == 1 then
				item_count = 1
			else
				item_count = (slider_position - 1) * 50  -- Position 2-11 = (position-1) stacks
			end
		else
			local stack_size = utils.stack_size(slot.item) or 50
			if slider_position == 1 then
				item_count = 1
			else
				-- Position 2-11 represents (position-1) stacks
				item_count = (slider_position - 1) * stack_size
			end
		end
		item_count = math.max(1, math.min(10000, item_count))
		gui_data.request_amount_textfield.text = tostring(item_count)
		slot.count = item_count
		-- Update overlay button number (count in bottom-right corner of icon)
		if slot.overlay_button and slot.overlay_button.valid then
			slot.overlay_button.number = item_count
		end
		-- Don't update requester_data - wait for confirm button
		return
	end
	
	-- Handle buffer slider - update UI only, don't save to requester_data yet
	if element.name == 'buffer_slider' then
		local value = math.floor(element.slider_value)
		gui_data.buffer_value.caption = string.format("%.0f%%", value)
		slot.buffer = value / 100
		-- Don't update requester_data - wait for confirm button
		return
	end
end)


script.on_event(defines.events.on_gui_click, function(event)
	local element = event.element
	if not element or not element.valid then return end
	
	local player = game.get_player(event.player_index)
	local player_index = event.player_index
	
		-- Handle left-click on item slot overlay buttons (slots with items) - open settings
		if event.button == defines.mouse_button_type.left then
		if element.name and element.name:match("^spidertron_slot_overlay_") then
			local slot_index = tonumber(element.name:match("%d+"))
			local gui_data = storage.requester_guis[player_index]
			
			if gui_data and gui_data.last_opened_requester then
				local requester_data = gui_data.last_opened_requester
				local slot = gui_data.item_slots[slot_index]
				
				if slot and slot.item then
					-- Use the slot's stored item directly (preserves insertion order)
					local item_name = slot.item
					
					-- Open settings for this item
					gui_data.selected_slot_index = slot_index
					
					-- Load current values from requester_data (don't overwrite slot.count if it's already set)
					local item_data = requester_data.requested_items[item_name]
					if item_data then
						-- Handle migration from old format
						if type(item_data) == "table" then
							-- Only update if slot.count is not already set (preserve current display)
							if not slot.count or slot.count == 0 then
								slot.count = item_data.count or 50
							end
							slot.buffer = item_data.buffer_threshold or 0.8
							slot.allow_excess_provider = item_data.allow_excess_provider ~= nil and item_data.allow_excess_provider or true
						elseif type(item_data) == "number" then
							-- Old format - only update if slot.count is not already set
							if not slot.count or slot.count == 0 then
								slot.count = item_data
							end
							slot.buffer = 0.8
							slot.allow_excess_provider = true
						end
					end
					
					-- Ensure slot.item is set
					slot.item = item_name
					
					-- Update settings section
					gui.update_settings_section(gui_data, slot_index)
					return
				end
			end
		end
		
		-- Handle left-click on item slots that already have items - open settings instead of item picker
		-- (Fallback for choose-elem-button clicks)
		if element.name and element.name:match("^spidertron_slot_") then
			local slot_index = tonumber(element.name:match("%d+"))
			local gui_data = storage.requester_guis[player_index]
			
			if gui_data and gui_data.last_opened_requester then
				local requester_data = gui_data.last_opened_requester
				local slot = gui_data.item_slots[slot_index]
				
				-- Check if slot has an item by using the slot's stored item (preserves insertion order)
				if slot and slot.item then
					local item_name = slot.item
					
					-- Verify item still exists in requester_data
					if requester_data.requested_items and requester_data.requested_items[item_name] then
						-- Open settings for this item
						gui_data.selected_slot_index = slot_index
						
						-- Load current values from requester_data (preserve slot.count if already set)
						local item_data = requester_data.requested_items[item_name]
						if item_data then
							-- Handle migration from old format
							if type(item_data) == "table" then
								-- Preserve slot.count if it's already set (from GUI display)
								if not slot.count or slot.count == 0 then
									slot.count = item_data.count or 50
								end
								slot.buffer = item_data.buffer_threshold or 0.8
								slot.allow_excess_provider = item_data.allow_excess_provider ~= nil and item_data.allow_excess_provider or true
							elseif type(item_data) == "number" then
								-- Old format - preserve slot.count if already set
								if not slot.count or slot.count == 0 then
									slot.count = item_data
								end
								slot.buffer = 0.8
								slot.allow_excess_provider = true
							end
						end
						
						-- Ensure slot.item is set
						slot.item = item_name
						
						-- Update settings section
						gui.update_settings_section(gui_data, slot_index)
						
						-- Settings already opened above, just return
						return
					end
				end
			end
		end
	end
	
	-- Handle right-click on item slots to clear request
	if event.button == defines.mouse_button_type.right then
		-- Check if clicked element is a slot overlay button, chooser, or within a slot flow
		local slot_index = nil
		if element.name and element.name:match("^spidertron_slot_overlay_") then
			slot_index = tonumber(element.name:match("%d+"))
		elseif element.name and element.name:match("^spidertron_slot_") then
			slot_index = tonumber(element.name:match("%d+"))
		else
			-- Check if clicked element is within a slot flow
			local parent = element.parent
			local depth = 0
			while parent and depth < 10 do
				if parent.name and (parent.name:match("^spidertron_slot_") or parent.name:match("^spidertron_slot_overlay_")) then
					slot_index = tonumber(parent.name:match("%d+"))
					break
				end
				parent = parent.parent
				depth = depth + 1
			end
			-- If still not found, check if we're in a slot flow by checking parent flows
			if not slot_index then
				parent = element.parent
				depth = 0
				while parent and depth < 10 do
					-- Check if any sibling or parent has a slot chooser
					for i = 1, 10 do
						if parent["spidertron_slot_" .. i] then
							slot_index = i
							break
						end
					end
					if slot_index then break end
					parent = parent.parent
					depth = depth + 1
				end
			end
		end
		
		if slot_index then
			local gui_data = storage.requester_guis[player_index]
			
			if not gui_data then
				return
			end
			
			if not gui_data.last_opened_requester then
				return
			end
			
			-- Get the actual requester_data from storage (not just the cached reference)
			local cached_requester = gui_data.last_opened_requester
			if not cached_requester or not cached_requester.entity or not cached_requester.entity.valid then
				return
			end
			
			local unit_number = cached_requester.entity.unit_number
			local requester_data = storage.requesters[unit_number]
			if not requester_data then
				return
			end
			
			local slot = gui_data.item_slots[slot_index]
			if not slot then
				return
			end
			
			-- Use the slot's stored item directly (preserves insertion order, no need to rebuild list)
			local item_to_remove = slot.item
			
			-- Only clear if there's an active request for this item
			if item_to_remove and requester_data.requested_items and requester_data.requested_items[item_to_remove] then
				-- Ensure requested_items table exists
				if not requester_data.requested_items then
					requester_data.requested_items = {}
				end
				
				-- Remove the item from requester_data (this modifies the actual storage)
				requester_data.requested_items[item_to_remove] = nil
				
				-- Update entity tags so requests are copied when entity is copied
				if requester_data.entity and requester_data.entity.valid then
					registration.update_requester_entity_tags(requester_data.entity, requester_data.requested_items)
				end
				
				-- Also update the cached reference to keep it in sync
				if gui_data.last_opened_requester then
					gui_data.last_opened_requester.requested_items = requester_data.requested_items
				end
				
				-- Clear slot data
				slot.item = nil
				slot.count = 0
				slot.buffer = 0.8
				slot.allow_excess_provider = true
				
				-- Clear chooser
				if slot.chooser then
					slot.chooser.elem_value = nil
				end
				
				-- Hide count label
				if slot.count_label then
					slot.count_label.caption = ''
					slot.count_label.visible = false
				end
				
				-- Hide settings if this slot was selected
				if gui_data.selected_slot_index == slot_index then
					gui_data.settings_frame.visible = false
					gui_data.selected_slot_index = nil
				end
				
				-- Update GUI to reflect changes (this will rebuild the item list and update slots)
				-- Use the actual storage reference to ensure consistency
				gui.update_requester_gui(gui_data, requester_data)
				return
			end
		end
	end
	
	-- Handle excess provider checkbox - update UI only, don't save to requester_data yet
	if element.name == 'excess_provider_checkbox' then
		local gui_data = storage.requester_guis[player_index]
		if not gui_data or not gui_data.last_opened_requester or not gui_data.selected_slot_index then return end
		
		local slot = gui_data.item_slots[gui_data.selected_slot_index]
		slot.allow_excess_provider = element.state
		-- Don't update requester_data - wait for confirm button
		return
	end
	
	-- Handle confirm request button - save all settings to requester_data
	if element.name == 'confirm_request_button' then
		local gui_data = storage.requester_guis[player_index]
		if not gui_data or not gui_data.last_opened_requester or not gui_data.selected_slot_index then return end
		
		local requester_data = gui_data.last_opened_requester
		local slot = gui_data.item_slots[gui_data.selected_slot_index]
		
		if slot.item then
			-- Initialize requested_items if needed
			if not requester_data.requested_items then
				requester_data.requested_items = {}
			end
			
			-- Save all current settings to requester_data
			requester_data.requested_items[slot.item] = {
				count = slot.count or 50,
				buffer_threshold = slot.buffer or 0.8,
				allow_excess_provider = slot.allow_excess_provider ~= nil and slot.allow_excess_provider or true
			}
			
			-- Update entity tags so requests are copied when entity is copied
			if requester_data.entity and requester_data.entity.valid then
				registration.update_requester_entity_tags(requester_data.entity, requester_data.requested_items)
			end
			
			-- Update the GUI to show the count on the icon
			gui.update_requester_gui(gui_data, requester_data)
		end
		
		-- Close the settings menu
		if gui_data.settings_frame and gui_data.settings_frame.valid then
			gui_data.settings_frame.visible = false
		end
		gui_data.selected_slot_index = nil
		
		return
	end
	
	-- Slot clicks are now handled by choose-elem-button in on_gui_elem_changed
	-- The native item picker opens automatically when clicking choose-elem-button
	
	-- Handle toggle button click (new shared toolbar name)
	if element.name == 'spidertron-logistics_toggle' then
		local vehicle = player.opened
		if vehicle and vehicle.valid and vehicle.type == 'spider-vehicle' then
			local spider_data = storage.spiders[vehicle.unit_number]
			if spider_data then
				local was_active = spider_data.active or false
				local new_active = not was_active  -- Toggle state
				
				-- Update active state
				spider_data.active = new_active
				
				-- Update button color
				gui.update_toggle_button_color(element, new_active)
				
				-- Handle activation/deactivation (same logic as switch handler)
				if new_active and not was_active then
					-- Spider is being activated
					local spider = spider_data.entity
					if spider and spider.valid then
						-- Check if spider has items to dump
						if journey.has_dumpable_items(vehicle.unit_number) then
							-- Start dumping - beacon finding will happen after dump completes
							local dump_success = journey.attempt_dump_items(vehicle.unit_number)
							-- If dump failed (no storage chests), continue to find beacon anyway
							if not dump_success then
								-- No storage chests available, find beacon immediately
								local network = beacon_assignment.spidertron_network(spider)
								if network then
									local active_beacon = beacon_assignment.find_beacon_with_highest_pickup_count(
										spider.surface, 
										spider.position, 
										spider.force,
										1000
									)
									
									if active_beacon and active_beacon.valid then
										pathing.set_smart_destination(spider, active_beacon.position, active_beacon)
									else
										local nearest_beacon = beacon_assignment.find_nearest_beacon(
											spider.surface, 
											spider.position, 
											spider.force, 
											nil, 
											"activation_fallback"
										)
										if nearest_beacon then
											pathing.set_smart_destination(spider, nearest_beacon.position, nearest_beacon)
										end
									end
								end
							end
						else
							-- No items to dump, find a beacon immediately
							local network = beacon_assignment.spidertron_network(spider)
							if network then
								-- Try to find beacon with highest pickup count
								local active_beacon = beacon_assignment.find_beacon_with_highest_pickup_count(
									spider.surface, 
									spider.position, 
									spider.force,
									1000
								)
								
								if active_beacon and active_beacon.valid then
									pathing.set_smart_destination(spider, active_beacon.position, active_beacon)
								else
									-- Fallback to nearest beacon
									local nearest_beacon = beacon_assignment.find_nearest_beacon(
										spider.surface, 
										spider.position, 
										spider.force, 
										nil, 
										"activation_fallback"
									)
									if nearest_beacon then
										pathing.set_smart_destination(spider, nearest_beacon.position, nearest_beacon)
									end
								end
							end
						end
					end
				elseif not new_active and was_active then
					-- Spider is being deactivated
					journey.end_journey(vehicle.unit_number, false)
				end
			end
		end
		return
	end
	
	-- Handle manual dump button click (new shared toolbar name or legacy name)
	if element.name == 'spidertron-logistics_dump' or element.name == 'spidertron_manual_dump_button' then
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
	
	-- Handle spidertron remote button click
	if element.name == 'spidertron-logistics_remote' then
		local vehicle = player.opened
		if vehicle and vehicle.valid and vehicle.type == 'spider-vehicle' then
			local spider_data = storage.spiders[vehicle.unit_number]
			if spider_data then
				local spider = spider_data.entity
				if spider and spider.valid then
					gui.get_spidertron_remote(player, spider)
					-- Close the GUI after giving the remote
					player.opened = nil
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

-- Save task state when spider is moved/interrupted
script.on_event(defines.events.on_player_driving_changed_state, function(event)
	local spider = event.entity
	if spider and storage.spiders[spider.unit_number] then
		-- Save task state for resumption
		journey.end_journey(spider.unit_number, false, true)
	end
end)

script.on_event(defines.events.on_player_used_spidertron_remote, function(event)
	local spider = event.vehicle
	if event.success and storage.spiders[spider.unit_number] then
		-- Save task state for resumption
		journey.end_journey(spider.unit_number, false, true)
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

-- Process batched pickups every tick (not every 240 ticks)
script.on_event(defines.events.on_tick, function(event)
	-- Process batched pickups every tick
	for unit_number, spider_data in pairs(storage.spiders) do
		if spider_data.status == constants.picking_up and 
		   spider_data.pickup_batch_remaining and 
		   spider_data.pickup_batch_remaining > 0 then
			
			local spider = spider_data.entity
			if spider and spider.valid then
				local provider = spider_data.provider_target
				if provider and provider.valid then
					local distance_to_provider = utils.distance(spider.position, provider.position)
					if distance_to_provider <= 10 then
						game.print("[PICKUP BATCH] Tick " .. event.tick .. ": on_tick processing batch (distance=" .. string.format("%.2f", distance_to_provider) .. ", remaining=" .. spider_data.pickup_batch_remaining .. ")")
						
						local item = spider_data.payload_item
						if item then
							local BATCH_SIZE = 200
							local batch_size = math.min(BATCH_SIZE, spider_data.pickup_batch_remaining)
							local total_inserted_so_far = spider_data.pickup_batch_total_inserted or 0
							local batch_number = math.floor(total_inserted_so_far / BATCH_SIZE) + 1
							
							game.print("[PICKUP BATCH] Tick " .. event.tick .. ": Processing batch #" .. batch_number .. " - " .. batch_size .. " items (remaining: " .. spider_data.pickup_batch_remaining .. ", total so far: " .. total_inserted_so_far .. ")")
							
							local batch_inserted = spider.insert{name = item, count = batch_size}
							
							if batch_inserted > 0 then
								provider.remove_item{name = item, count = batch_inserted}
								
								spider_data.pickup_batch_remaining = spider_data.pickup_batch_remaining - batch_inserted
								spider_data.pickup_batch_total_inserted = (spider_data.pickup_batch_total_inserted or 0) + batch_inserted
								
								game.print("[PICKUP BATCH] Tick " .. event.tick .. ": Batch processed - inserted " .. batch_inserted .. ", remaining: " .. spider_data.pickup_batch_remaining)
								
								if spider_data.pickup_batch_remaining <= 0 then
									game.print("[PICKUP BATCH] Tick " .. event.tick .. ": All batches complete! Total: " .. spider_data.pickup_batch_total_inserted)
									spider_data.pickup_batch_complete = true
									spider_data.pickup_batch_final_count = spider_data.pickup_batch_total_inserted
									
									-- Trigger command completion
									local current_pos = spider.position
									local tiny_offset = {x = current_pos.x + 0.1, y = current_pos.y}
									spider.autopilot_destination = nil
									spider.add_autopilot_destination(tiny_offset)
								end
							else
								-- Failed to insert
								logging.warn("Pickup", "Spider " .. unit_number .. " batch pickup failed to insert items")
								spider_data.pickup_batch_remaining = nil
								spider_data.pickup_batch_total_inserted = nil
								journey.end_journey(unit_number, true)
							end
						end
					else
						game.print("[PICKUP BATCH] Tick " .. event.tick .. ": on_tick skipping batch - spider too far (distance=" .. string.format("%.2f", distance_to_provider) .. " > 10)")
					end
				else
					game.print("[PICKUP BATCH] Tick " .. event.tick .. ": on_tick skipping batch - provider invalid")
				end
			else
				game.print("[PICKUP BATCH] Tick " .. event.tick .. ": on_tick skipping batch - spider invalid")
			end
		end
	end
end)

-- Main logistics update loop
script.on_nth_tick(constants.update_cooldown, function(event)
	-- Memory cleanup: remove old pathfinding requests and expired cache entries
	local current_tick = event.tick
	local cleanup_interval = 60  -- Clean up every 60 ticks (1 second)
	
	if current_tick % cleanup_interval == 0 then
		-- Clean up old pathfinding requests (older than 5 seconds)
		if storage.path_requests then
			for request_id, request_data in pairs(storage.path_requests) do
				if request_data.start_tick and (current_tick - request_data.start_tick) > 300 then
					storage.path_requests[request_id] = nil
				end
			end
		end
		
		-- Clean up expired pathfinding cache entries
		if storage.pathfinding_cache then
			for cache_key, cached_path in pairs(storage.pathfinding_cache) do
				if cached_path.cache_tick and (current_tick - cached_path.cache_tick) > constants.pathfinding_cache_ttl then
					storage.pathfinding_cache[cache_key] = nil
				end
			end
		end
		
		-- Clean up expired distance cache entries
		if storage.distance_cache then
			for cache_key, cached_dist in pairs(storage.distance_cache) do
				if cached_dist.cache_tick and (current_tick - cached_dist.cache_tick) > constants.distance_cache_ttl then
					storage.distance_cache[cache_key] = nil
				end
			end
		end
		
		-- Clean up invalid entity references in robot chest cache
		if storage.robot_chest_cache then
			for chest_unit_number, cached_data in pairs(storage.robot_chest_cache) do
				if not cached_data.entity or not cached_data.entity.valid then
					storage.robot_chest_cache[chest_unit_number] = nil
				end
			end
		end
		
		-- Clean up old pathfinder statuses (older than 10 seconds)
		if storage.pathfinder_statuses then
			for spider_unit_number, statuses in pairs(storage.pathfinder_statuses) do
				for tick, status in pairs(statuses) do
					if (current_tick - tick) > 600 then
						statuses[tick] = nil
					end
				end
				-- Remove empty status tables
				local has_entries = false
				for _ in pairs(statuses) do
					has_entries = true
					break
				end
				if not has_entries then
					storage.pathfinder_statuses[spider_unit_number] = nil
				end
			end
		end
	end
	
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
				local dump_success = journey.attempt_dump_items(unit_number)
				-- If attempt_dump_items failed and still no dump_target, end journey and set idle
				if not dump_success and (not spider_data.dump_target or not spider_data.dump_target.valid) then
					-- No storage chests available - end journey and set to idle
					spider_data.dump_target = nil
					journey.end_journey(unit_number, true)
				end
				goto next_dumping_spider
			end
			
			-- Check if spider is close enough to dump target and try to dump
			local dump_target = spider_data.dump_target
			if dump_target and dump_target.valid then
				local distance = utils.distance(spider.position, dump_target.position)
				if distance <= 6 then
					-- Spider is close enough, try to dump items
					
					-- Clear autopilot to ensure spider stops
					if spider.autopilot_destinations and #spider.autopilot_destinations > 0 then
						spider.autopilot_destination = nil
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
							local dump_success = journey.attempt_dump_items(unit_number)
							-- If attempt_dump_items failed and still no dump_target, end journey and set idle
							if not dump_success and (not spider_data.dump_target or not spider_data.dump_target.valid) then
								-- No storage chests available - end journey and set to idle
								spider_data.dump_target = nil
								journey.end_journey(unit_number, true)
							end
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
	
	-- Check for saved tasks to resume (spiders that were interrupted)
	for unit_number, spider_data in pairs(storage.spiders) do
		if spider_data.status == constants.idle and spider_data.saved_task and spider_data.active then
			local spider = spider_data.entity
			if spider and spider.valid then
				-- Try to resume the saved task
				local resumed = journey.resume_task(unit_number)
				if not resumed then
					-- Resume failed (entities invalid), clear saved task
					spider_data.saved_task = nil
				end
			else
				-- Spider invalid, clear saved task
				spider_data.saved_task = nil
			end
		end
	end
	
	-- Beacon validation is now event-driven (handled in handle_entity_removal and built functions)
	-- No periodic validation needed - beacons are validated when:
	-- 1. Beacon is destroyed (handle_entity_removal reassigns all chests)
	-- 2. Chest is created (built function assigns to nearest beacon)
	-- 3. Chest loses beacon (validated on-demand in logistics functions)
	
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
							local pos_x = math.floor(current_pos.x)
							local pos_y = math.floor(current_pos.y)
							
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
									-- Reset stuck detection
									spider_data.last_position = current_pos
									spider_data.last_position_tick = current_tick
									spider_data.stuck_count = 0
								end
							else
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
	
	-- Staggered updates: only process networks on specific ticks to spread load
	-- Use network_key (surface index) to determine which networks update this tick
	local current_tick = event.tick
	local stagger_interval = 4  -- Update each network every 4th tick
	local networks_to_process = {}
	
	local requests = logistics.requesters()
	local spiders_list = logistics.spiders()
	local providers_list = logistics.providers()
	
	-- Filter networks based on staggered schedule
	for network_key, requesters in pairs(requests) do
		-- Skip idle networks (no requests, no spiders, or no providers)
		local providers_for_network = providers_list[network_key]
		local spiders_on_network = spiders_list[network_key]
		
		if not providers_for_network or #providers_for_network == 0 then
			goto skip_network
		end
		if not spiders_on_network or #spiders_on_network == 0 then
			goto skip_network
		end
		if not requesters or #requesters == 0 then
			goto skip_network
		end
		
		-- Stagger: only process networks where (network_key + tick) % stagger_interval == 0
		if (network_key + current_tick) % stagger_interval == 0 then
			networks_to_process[network_key] = requesters
		end
		
		::skip_network::
	end
	
	-- Log summary of available resources
	local total_requests = 0
	local total_spiders = 0
	local total_providers = 0
	for _, reqs in pairs(requests) do total_requests = total_requests + #reqs end
	for _, spids in pairs(spiders_list) do total_spiders = total_spiders + #spids end
	for _, provs in pairs(providers_list) do total_providers = total_providers + #provs end
	
	for network_key, requesters in pairs(networks_to_process) do
		local providers_for_network = providers_list[network_key]
		local spiders_on_network = spiders_list[network_key]
		
		if not providers_for_network then 
			goto next_network 
		end
		
		if not spiders_on_network or #spiders_on_network == 0 then 
			goto next_network
		end
		
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
				
				-- Feature 1: Check for multi-pickup route (multiple providers for same item)
				if best_spider_pos then
					local multi_pickup_route = route_planning.find_multi_pickup_route(requester, item, item_request.real_amount, providers_for_network, best_spider_pos)
					if multi_pickup_route then
						local assigned = logistics.assign_spider_with_route(spiders_on_network, multi_pickup_route, "multi_pickup")
						if assigned then
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
					-- Buffer threshold is now handled in should_request_item, so no need for delay check here
					
					-- Check if we should delay this assignment to batch more items
					if logistics.should_delay_assignment(requester_data, best_provider, max, item_request.real_amount, item_request.percentage_filled) then
						goto next_item_request  -- Skip this assignment, try again next cycle
					end
					
					-- Create a temporary requester_data-like object for assign_spider
					local temp_requester = {
						entity = requester_data.entity,
						requested_item = item,
						real_amount = item_request.real_amount,
						incoming_items = requester_data.incoming_items
					}
					local assigned = logistics.assign_spider(spiders_on_network, temp_requester, best_provider, max)
					if not assigned then
						goto next_item_request
					end
					if #spiders_on_network == 0 then
						goto next_network
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
				journey.end_journey(unit_number, true)
				return
			end
		end
		goal = spider_data.provider_target
	elseif spider_data.status == constants.dropping_off then
		if not spider_data.requester_target or not spider_data.requester_target.valid then
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
		journey.end_journey(unit_number, true)
		return
	end
	
	-- Check distance separately - only cancel if spider is way too far (likely lost/stuck)
	-- Normal travel distance can be hundreds of tiles, so we use a much larger threshold
	local distance_to_goal = utils.distance(spider.position, goal.position)
	if distance_to_goal > 1000 then
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
		-- Declare ALL variables in outer scope to avoid goto scope issues
		-- These variables are used after the batch_pickup_complete label
		local provider = spider_data.provider_target
		local provider_data = nil
		local is_robot_chest = false
		local actually_inserted = 0
		local already_had = 0
		local start_tick = event.tick
		local operation_count = 0
		local distance_to_provider = 0
		local provider_inventory = nil
		local contains = 0
		local stop_amount = 0
		local trunk = nil
		local max_can_insert = 0
		local can_insert = 0
		local provider_inv_size = 0
		local removed_via_api = 0
		-- Timing variables
		local tick_before_spider_count = 0
		local tick_after_spider_count = 0
		local tick_before_get_count = 0
		local tick_after_get_count = 0
		local tick_before_loop = 0
		local tick_after_loop = 0
		local tick_before_empty = 0
		local tick_after_empty = 0
		local tick_before_insert = 0
		local tick_after_insert = 0
		local tick_before_remove = 0
		local tick_after_remove = 0
		local tick_before_find = 0
		local tick_after_find = 0
		local tick_before_verify = 0
		local tick_after_verify = 0
		-- Other variables
		local total_count = 0
		local requester_data_for_excess = nil
		local item_data = nil
		local requested_count = 0
		local current_stop = nil
		local stack_size = 0
		local space_in_existing = 0
		local trunk_size = 0
		local stack = nil
		local empty_slots = 0
		local space_in_empty = 0
		local batch_size = 0
		local batch_inserted = 0
		local remaining_to_remove = 0
		local slots_checked = 0
		local to_remove = 0
		local nearest_provider = nil
		local final_spider_count = 0
		local BATCH_SIZE = 200
		
		-- Check if batch was completed in on_tick handler
		if spider_data.pickup_batch_complete then
			-- Batch was completed in on_tick, use the final count and process completion
			actually_inserted = spider_data.pickup_batch_final_count
			
			if provider and provider.valid then
				provider_data = storage.providers[provider.unit_number]
			end
			if provider_data then
				is_robot_chest = provider_data.is_robot_chest or false
			end
			
			spider_data.pickup_batch_remaining = nil
			spider_data.pickup_batch_total_inserted = nil
			spider_data.pickup_batch_complete = nil
			spider_data.pickup_batch_final_count = nil
			
			-- Jump to completion logic
			item = spider_data.payload_item
			item_count = spider_data.payload_item_count
			already_had = spider.get_item_count(item) or 0
			start_tick = event.tick
			operation_count = 0
			goto batch_pickup_complete
		end
		
		if not provider or not provider.valid then
			logging.warn("Pickup", "Provider target is invalid!")
			journey.end_journey(unit_number, true)
			return
		end
		
		-- Verify spider is actually close enough to the provider
		distance_to_provider = utils.distance(spider.position, provider.position)
		if distance_to_provider > 6 then
			-- Spider not close enough yet, wait for next command completion
			return
		end
		
		-- DEBUG: Log pickup start with timing
		start_tick = event.tick
		operation_count = 0
		game.print("[PICKUP START] Spider " .. unit_number .. " taking " .. (item or "nil") .. " from provider " .. (provider.unit_number or "nil") .. " at tick " .. start_tick)
		
		-- Clear any remaining autopilot destinations to ensure spider stops
		if spider.autopilot_destinations and #spider.autopilot_destinations > 0 then
			spider.autopilot_destination = nil
		end
		
		-- Get provider data if not already set
		if not provider_data then
			provider_data = storage.providers[provider.unit_number]
		end
		
		-- Check if this is a robot chest
		if provider_data then
			if not is_robot_chest then
				is_robot_chest = provider_data.is_robot_chest or false
			end
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
		
		provider_inventory = provider.get_inventory(defines.inventory.chest)
		contains = 0
		if provider_inventory then
			-- For requester excess providers, only take the excess amount, not the full requested amount
			if provider_data and provider_data.is_requester_excess then
				-- Get the total count in the chest
			tick_before_get_count = event.tick
			total_count = provider_inventory.get_item_count(item) or 0
			tick_after_get_count = event.tick
			operation_count = operation_count + 1
			game.print("[PICKUP TIMING] get_item_count took " .. (tick_after_get_count - tick_before_get_count) .. " ticks (op #" .. operation_count .. ")")
				game.print("[PICKUP DEBUG] Requester excess provider: total_count=" .. total_count .. " for " .. item)
				-- Get the requested amount for this item
				requester_data_for_excess = storage.requesters[provider.unit_number]
				if requester_data_for_excess and requester_data_for_excess.requested_items and requester_data_for_excess.requested_items[item] then
					item_data = requester_data_for_excess.requested_items[item]
					requested_count = type(item_data) == "number" and item_data or (item_data.count or 0)
					-- Only take the excess (amount above requested)
					contains = math.max(0, total_count - requested_count)
					game.print("[PICKUP DEBUG] requested_count=" .. requested_count .. ", excess=" .. contains)
				else
					-- Fallback: use total count if we can't determine requested amount
					contains = total_count
					game.print("[PICKUP DEBUG] Fallback: using total_count=" .. contains)
				end
			else
				-- Regular provider: use total count
				tick_before_get_count = event.tick
				contains = provider_inventory.get_item_count(item) or 0
				tick_after_get_count = event.tick
				operation_count = operation_count + 1
				game.print("[PICKUP TIMING] get_item_count took " .. (tick_after_get_count - tick_before_get_count) .. " ticks (op #" .. operation_count .. ")")
				game.print("[PICKUP DEBUG] Regular provider: contains=" .. contains)
			end
		else
			logging.warn("Pickup", "Provider has no inventory")
			journey.end_journey(unit_number, true)
			return
		end
		
		-- For routes, get the stop's amount (what this provider should give)
		-- For non-routes, use item_count
		stop_amount = item_count
		if spider_data.route and spider_data.current_route_index then
			current_stop = spider_data.route[spider_data.current_route_index]
			if current_stop and current_stop.amount then
				stop_amount = current_stop.amount
				game.print("[PICKUP DEBUG] stop_amount from route stop: " .. stop_amount)
			else
				game.print("[PICKUP DEBUG] stop_amount from item_count (route): " .. stop_amount)
			end
		else
			game.print("[PICKUP DEBUG] stop_amount from item_count (non-route): " .. stop_amount)
		end
		game.print("[PICKUP DEBUG] stop_amount=" .. stop_amount .. ", contains=" .. contains .. ", will be limited by min()")
		
		-- Get spider trunk inventory
		trunk = spider.get_inventory(defines.inventory.spider_trunk)
		if not trunk then
			logging.warn("Pickup", "Spider has no trunk inventory")
			journey.end_journey(unit_number, true)
			return
		end
		
		-- Get how many items spider already has
		tick_before_spider_count = event.tick
		already_had = spider.get_item_count(item)
		tick_after_spider_count = event.tick
		operation_count = operation_count + 1
		game.print("[PICKUP TIMING] spider.get_item_count took " .. (tick_after_spider_count - tick_before_spider_count) .. " ticks (op #" .. operation_count .. ")")
		game.print("[PICKUP DEBUG] Spider already has: " .. already_had)
		
		-- Check how much we can actually insert (respects stack sizes and inventory limits)
		-- trunk.can_insert() is boolean, so we need to calculate the actual limit
		max_can_insert = 0
		if trunk.can_insert({name = item, count = 1}) then
			-- Spider can insert at least 1, calculate how many
			stack_size = utils.stack_size(item)
			game.print("[PICKUP DEBUG] Calculating trunk capacity, stack_size=" .. stack_size .. ", trunk_size=" .. #trunk)
			
			-- Calculate space in existing stacks of this item
			tick_before_loop = event.tick
			space_in_existing = 0
			trunk_size = #trunk
			for i = 1, trunk_size do
				stack = trunk[i]
				if stack and stack.valid_for_read and stack.name == item then
					space_in_existing = space_in_existing + (stack_size - stack.count)
				end
			end
			tick_after_loop = event.tick
			operation_count = operation_count + 1
			game.print("[PICKUP TIMING] Trunk inventory loop (" .. trunk_size .. " slots) took " .. (tick_after_loop - tick_before_loop) .. " ticks (op #" .. operation_count .. ")")
			
			-- Calculate space in empty slots
			tick_before_empty = event.tick
			empty_slots = trunk.count_empty_stacks(false, false)
			tick_after_empty = event.tick
			operation_count = operation_count + 1
			game.print("[PICKUP TIMING] count_empty_stacks took " .. (tick_after_empty - tick_before_empty) .. " ticks (op #" .. operation_count .. ")")
			space_in_empty = empty_slots * stack_size
			
			-- Total space available
			max_can_insert = space_in_existing + space_in_empty
			game.print("[PICKUP DEBUG] Trunk capacity: space_in_existing=" .. space_in_existing .. ", empty_slots=" .. empty_slots .. ", max_can_insert=" .. max_can_insert)
		end
		
		-- Limit to what provider has and what this stop should provide
		can_insert = min(max_can_insert, contains, stop_amount)
		game.print("[PICKUP DEBUG] Final can_insert=" .. can_insert .. " (max_can_insert=" .. max_can_insert .. ", contains=" .. contains .. ", stop_amount=" .. stop_amount .. ")")
		
		-- Check if we're continuing a batched pickup
		if spider_data.pickup_batch_remaining and spider_data.pickup_batch_remaining > 0 then
			-- Continue batched pickup
			batch_size = math.min(200, spider_data.pickup_batch_remaining)
			local total_inserted_so_far = spider_data.pickup_batch_total_inserted or 0
			local batch_number = math.floor(total_inserted_so_far / BATCH_SIZE) + 1
			
			game.print("[PICKUP BATCH] Tick " .. event.tick .. ": Processing batch #" .. batch_number .. " - " .. batch_size .. " items (remaining: " .. spider_data.pickup_batch_remaining .. ", total so far: " .. total_inserted_so_far .. ")")
			
			tick_before_insert = event.tick
			local count_before_insert = spider.get_item_count(item)
			batch_inserted = spider.insert{name = item, count = batch_size}
			local count_after_insert = spider.get_item_count(item)
			tick_after_insert = event.tick
			operation_count = operation_count + 1
			game.print("[PICKUP TIMING] spider.insert batch(" .. batch_size .. " items) took " .. (tick_after_insert - tick_before_insert) .. " ticks (op #" .. operation_count .. ")")
			game.print("[PICKUP DEBUG] Insert verification: count_before=" .. count_before_insert .. ", insert() returned=" .. batch_inserted .. ", count_after=" .. count_after_insert .. ", actual_added=" .. (count_after_insert - count_before_insert))
			
			if batch_inserted > 0 then
				-- Remove from provider
				tick_before_remove = event.tick
				removed_via_api = provider.remove_item{name = item, count = batch_inserted}
				tick_after_remove = event.tick
				operation_count = operation_count + 1
				game.print("[PICKUP TIMING] Provider remove_item batch(" .. batch_inserted .. " items) took " .. (tick_after_remove - tick_before_remove) .. " ticks (op #" .. operation_count .. ")")
				
				-- Update batch state
				spider_data.pickup_batch_remaining = spider_data.pickup_batch_remaining - batch_inserted
				spider_data.pickup_batch_total_inserted = (spider_data.pickup_batch_total_inserted or 0) + batch_inserted
				
				game.print("[PICKUP BATCH] Inserted " .. batch_inserted .. " items, remaining: " .. spider_data.pickup_batch_remaining)
				
				-- If batch is complete, continue with normal pickup completion
				if spider_data.pickup_batch_remaining <= 0 then
					game.print("[PICKUP BATCH] Batch complete! Total inserted: " .. spider_data.pickup_batch_total_inserted)
					actually_inserted = spider_data.pickup_batch_total_inserted
					spider_data.pickup_batch_remaining = nil
					spider_data.pickup_batch_total_inserted = nil
					
					-- Continue with normal pickup completion logic
					-- (we'll jump to the completion section)
					goto batch_pickup_complete
				else
					-- More batches needed, ensure spider stays at provider and let on_tick process next batch
					-- Clear any autopilot destinations to keep spider at provider location
					-- This ensures on_tick handler can process the next batch on the next tick
					local spider = spider_data.entity
					if spider and spider.valid then
						if spider.autopilot_destinations and #spider.autopilot_destinations > 0 then
							spider.autopilot_destination = nil
						end
					end
					return
				end
			else
				-- Failed to insert, abort batch
				logging.warn("Pickup", "Spider " .. unit_number .. " batch pickup failed to insert items")
				spider_data.pickup_batch_remaining = nil
				spider_data.pickup_batch_total_inserted = nil
				journey.end_journey(unit_number, true)
				return
			end
		end
		
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
		
		-- Check if we should batch this pickup (if more than 200 items)
		if can_insert > BATCH_SIZE then
			-- Start batched pickup
			game.print("[PICKUP BATCH] Tick " .. event.tick .. ": Starting batched pickup: " .. can_insert .. " items in batches of " .. BATCH_SIZE)
			spider_data.pickup_batch_remaining = can_insert
			spider_data.pickup_batch_total_inserted = 0
			
			-- Insert first batch
			batch_size = math.min(BATCH_SIZE, can_insert)
			game.print("[PICKUP BATCH] Tick " .. event.tick .. ": Processing batch #1 - " .. batch_size .. " items (remaining: " .. spider_data.pickup_batch_remaining .. ", total so far: 0)")
			game.print("[PICKUP DEBUG] About to insert first batch: " .. batch_size .. " items into spider")
			tick_before_insert = event.tick
			local count_before_insert = spider.get_item_count(item)
			batch_inserted = spider.insert{name = item, count = batch_size}
			local count_after_insert = spider.get_item_count(item)
			tick_after_insert = event.tick
			operation_count = operation_count + 1
			game.print("[PICKUP TIMING] spider.insert batch(" .. batch_size .. " items) took " .. (tick_after_insert - tick_before_insert) .. " ticks (op #" .. operation_count .. ")")
			game.print("[PICKUP DEBUG] Insert verification: count_before=" .. count_before_insert .. ", insert() returned=" .. batch_inserted .. ", count_after=" .. count_after_insert .. ", actual_added=" .. (count_after_insert - count_before_insert))
			
			if batch_inserted == 0 and already_had == 0 then
				logging.warn("Pickup", "Spider " .. unit_number .. " cancelling: failed to insert items (can_insert: " .. can_insert .. ", batch_inserted: " .. batch_inserted .. ", already_had: " .. already_had .. ")")
				spider_data.pickup_batch_remaining = nil
				spider_data.pickup_batch_total_inserted = nil
				journey.end_journey(unit_number, true)
				return
			end
			
			if batch_inserted > 0 then
				-- Remove from provider
				game.print("[PICKUP DEBUG] About to remove " .. batch_inserted .. " items from provider chest")
				provider_inventory = provider.get_inventory(defines.inventory.chest)
				tick_before_remove = event.tick
				provider_inv_size = #provider_inventory
				
				-- Use remove_item API
				removed_via_api = provider.remove_item{name = item, count = batch_inserted}
				
				tick_after_remove = event.tick
				operation_count = operation_count + 1
				game.print("[PICKUP TIMING] Provider remove_item batch(" .. batch_inserted .. " items) took " .. (tick_after_remove - tick_before_remove) .. " ticks, removed=" .. removed_via_api .. " (op #" .. operation_count .. ")")
				game.print("[PICKUP DEBUG] Finished removing items from provider chest")
				
				-- Update batch state
				spider_data.pickup_batch_remaining = spider_data.pickup_batch_remaining - batch_inserted
				spider_data.pickup_batch_total_inserted = batch_inserted
				
				game.print("[PICKUP BATCH] First batch complete: inserted " .. batch_inserted .. ", remaining: " .. spider_data.pickup_batch_remaining)
				
				-- If there's more to do, ensure spider stays at provider and let on_tick process next batch
				if spider_data.pickup_batch_remaining > 0 then
					-- Clear any autopilot destinations to keep spider at provider location
					-- This ensures on_tick handler can process the next batch on the next tick
					if spider.autopilot_destinations and #spider.autopilot_destinations > 0 then
						spider.autopilot_destination = nil
					end
					return
				else
					-- All done in first batch (shouldn't happen if can_insert > BATCH_SIZE, but handle it)
					-- Set actually_inserted for completion logic below
					actually_inserted = spider_data.pickup_batch_total_inserted
					spider_data.pickup_batch_remaining = nil
					spider_data.pickup_batch_total_inserted = nil
					-- Continue to completion logic (skip the else branch)
					goto batch_pickup_complete
				end
			else
				-- Failed to insert batch, abort
				spider_data.pickup_batch_remaining = nil
				spider_data.pickup_batch_total_inserted = nil
				journey.end_journey(unit_number, true)
				return
			end
		else
			-- Small pickup, do it all at once (original logic)
		game.print("[PICKUP DEBUG] About to insert " .. can_insert .. " items into spider")
		tick_before_insert = event.tick
		local count_before_insert = spider.get_item_count(item)
		actually_inserted = spider.insert{name = item, count = can_insert}
		local count_after_insert = spider.get_item_count(item)
		tick_after_insert = event.tick
		operation_count = operation_count + 1
		game.print("[PICKUP TIMING] spider.insert(" .. can_insert .. " items) took " .. (tick_after_insert - tick_before_insert) .. " ticks (op #" .. operation_count .. ")")
		game.print("[PICKUP DEBUG] Insert verification: count_before=" .. count_before_insert .. ", insert() returned=" .. actually_inserted .. ", count_after=" .. count_after_insert .. ", actual_added=" .. (count_after_insert - count_before_insert))
			
			if actually_inserted == 0 and already_had == 0 then
				logging.warn("Pickup", "Spider " .. unit_number .. " cancelling: failed to insert items (can_insert: " .. can_insert .. ", actually_inserted: " .. actually_inserted .. ", already_had: " .. already_had .. ")")
				journey.end_journey(unit_number, true)
				return
			end
			
			if actually_inserted ~= 0 then
				game.print("[PICKUP DEBUG] About to remove " .. actually_inserted .. " items from provider chest")
				-- Remove items from the end of the inventory (last slots first)
				provider_inventory = provider.get_inventory(defines.inventory.chest)
				remaining_to_remove = actually_inserted
				
				-- OPTIMIZATION: Use remove_item instead of iterating through all slots
				-- This is much faster for large inventories
				tick_before_remove = event.tick
				provider_inv_size = #provider_inventory
				
				-- Try using remove_item first (faster for Factorio to handle internally)
				removed_via_api = provider.remove_item{name = item, count = actually_inserted}
				
				-- If remove_item didn't remove everything (shouldn't happen, but fallback)
				if removed_via_api < actually_inserted then
					remaining_to_remove = actually_inserted - removed_via_api
					-- Fallback to manual removal only if needed
					slots_checked = 0
					for i = provider_inv_size, 1, -1 do
						if remaining_to_remove <= 0 then
							break
						end
						slots_checked = slots_checked + 1
						stack = provider_inventory[i]
						if stack and stack.valid_for_read and stack.name == item then
							to_remove = math.min(remaining_to_remove, stack.count)
							stack.count = stack.count - to_remove
							remaining_to_remove = remaining_to_remove - to_remove
						end
					end
					game.print("[PICKUP DEBUG] Fallback removal: checked " .. slots_checked .. " slots, removed " .. (actually_inserted - removed_via_api) .. " items")
				end
				
				tick_after_remove = event.tick
				operation_count = operation_count + 1
				game.print("[PICKUP TIMING] Provider inventory removal (size=" .. provider_inv_size .. " slots) took " .. (tick_after_remove - tick_before_remove) .. " ticks, removed=" .. removed_via_api .. " (op #" .. operation_count .. ")")
				game.print("[PICKUP DEBUG] Finished removing items from provider chest")
			end
		end
		
		-- Label must be outside any if blocks to avoid scope issues
		::batch_pickup_complete::
		
		-- Track pickup_count for custom provider chests
		if not is_robot_chest and provider_data then
			provider_data.pickup_count = (provider_data.pickup_count or 0) + actually_inserted
		elseif is_robot_chest then
			game.print("[PICKUP DEBUG] Finding nearest provider chest for robot chest...")
			tick_before_find = event.tick
			-- For robot chests, assign pickup count to nearest spidertron provider depot
			nearest_provider = beacon_assignment.find_nearest_provider_chest(provider.surface, provider.position, provider.force)
			tick_after_find = event.tick
			game.print("[PICKUP TIMING] find_nearest_provider_chest took " .. (tick_after_find - tick_before_find) .. " ticks")
			if nearest_provider then
				local nearest_provider_data = storage.providers[nearest_provider.unit_number]
				if nearest_provider_data then
					nearest_provider_data.pickup_count = (nearest_provider_data.pickup_count or 0) + actually_inserted
				end
			end
			game.print("[PICKUP DEBUG] Finished finding nearest provider chest")
		end
		rendering.draw_withdraw_icon(provider)
		
		-- Verify pickup actually succeeded before proceeding
		game.print("[PICKUP DEBUG] Verifying pickup...")
		tick_before_verify = event.tick
		final_spider_count = spider.get_item_count(item)
		tick_after_verify = event.tick
		operation_count = operation_count + 1
		game.print("[PICKUP TIMING] Verification get_item_count took " .. (tick_after_verify - tick_before_verify) .. " ticks (op #" .. operation_count .. ")")
		-- Calculate expected count: what we had before + what we inserted
		-- Note: already_had is set at the start of pickup, actually_inserted is what we just inserted
		local expected_count = already_had + actually_inserted
		game.print("[PICKUP DEBUG] Verification: final_spider_count=" .. final_spider_count .. ", expected_count=" .. expected_count .. " (already_had=" .. already_had .. ", actually_inserted=" .. actually_inserted .. ")")
		
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
		local end_tick = event.tick
		local total_ticks = end_tick - start_tick
		game.print("[PICKUP COMPLETE] Spider " .. unit_number .. " successfully picked up " .. actually_inserted .. " " .. item .. " at tick " .. end_tick .. " (total: " .. total_ticks .. " ticks, operations: " .. operation_count .. ")")
		
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
						journey.end_journey(unit_number, true)
					end
				end
			end
		else
			-- No items picked up, end journey
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
			return
		end
		
		-- Clear any remaining autopilot destinations to ensure spider stops
		if spider.autopilot_destinations and #spider.autopilot_destinations > 0 then
			spider.autopilot_destination = nil
		end
		
		
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
						
						-- Invalidate inventory cache since items were added to requester
						requester_data.cached_item_counts = nil
						requester_data.cache_tick = nil
						
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
			local dump_success = journey.attempt_dump_items(unit_number)
			-- If attempt_dump_items failed and still no dump_target, end journey and set idle
			if not dump_success and (not spider_data.dump_target or not spider_data.dump_target.valid) then
				-- No storage chests available - end journey and set to idle
				spider_data.dump_target = nil
				journey.end_journey(unit_number, true)
			end
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
				local dump_success = journey.attempt_dump_items(unit_number)
				-- If attempt_dump_items failed and still no dump_target, end journey and set idle
				if not dump_success and (not spider_data.dump_target or not spider_data.dump_target.valid) then
					-- No storage chests available - end journey and set to idle
					spider_data.dump_target = nil
					journey.end_journey(unit_number, true)
				end
			else
				-- Done dumping
				spider_data.dump_target = nil
				journey.end_journey(unit_number, true)
			end
		else
			-- Couldn't dump anything
			spider_data.dump_target = nil
			local dump_success = journey.attempt_dump_items(unit_number)
			-- If attempt_dump_items failed and still no dump_target, end journey and set idle
			if not dump_success and (not spider_data.dump_target or not spider_data.dump_target.valid) then
				-- No storage chests available - end journey and set to idle
				spider_data.dump_target = nil
				journey.end_journey(unit_number, true)
			end
		end
	end
end)

local function handle_entity_removal(event)
	local entity = event.entity or event.created_entity
	local unit_number = event.unit_number or (entity and entity.unit_number)
	
	if not unit_number then return end
	
	-- Remove from robot chest cache if present
	logistics.remove_robot_chest_from_cache(unit_number)
	
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
					
					-- Verify assignment succeeded
					if chest_type == "provider" and storage.providers[chest_unit_number] then
						local new_beacon = storage.providers[chest_unit_number].beacon_owner
						if new_beacon then
						else
						end
					elseif chest_type == "requester" and storage.requesters[chest_unit_number] then
						local new_beacon = storage.requesters[chest_unit_number].beacon_owner
						if new_beacon then
						else
						end
					end
				else
				end
			end
		else
			-- No chests to reassign, just clean up
			storage.beacons[unit_number] = nil
		end
	end
end

script.on_event(defines.events.on_entity_died, handle_entity_removal)
script.on_event(defines.events.on_pre_player_mined_item, handle_entity_removal)
script.on_event(defines.events.on_robot_pre_mined, handle_entity_removal)
if defines.events.script_raised_destroy then
	script.on_event(defines.events.script_raised_destroy, handle_entity_removal)
end

-- Store pending clone data (source -> destination mapping)

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
		local requester_data = storage.requesters[entity.unit_number]
		
		if requester_data and requester_data.beacon_owner then
		else
		end
	elseif entity.name == constants.spidertron_provider_chest then
		registration.register_provider(entity)
		local provider_data = storage.providers[entity.unit_number]
		if provider_data and provider_data.beacon_owner then
		else
		end
	elseif entity.name == constants.spidertron_logistic_beacon then
		registration.register_beacon(entity)
	else
		-- Check if this is a robot chest type
		local robot_chest_types = {
			'storage-chest',
			'active-provider-chest',
			'passive-provider-chest'
		}
		for _, chest_type in ipairs(robot_chest_types) do
			if entity.name == chest_type then
				logistics.update_robot_chest_cache(entity)
				break
			end
		end
	end
end

script.on_event(defines.events.on_built_entity, built)
script.on_event(defines.events.on_robot_built_entity, built)
if defines.events.script_raised_built then
	script.on_event(defines.events.script_raised_built, built)
end
if defines.events.script_raised_revive then
	script.on_event(defines.events.script_raised_revive, built)
end

local function save_blueprint_data(blueprint, mapping)
	local blueprint_entities = blueprint.get_blueprint_entities()
	if not blueprint_entities then return end
	
	-- Iterate over mapping (preview_unit_number -> preview_entity)
	for preview_unit_number, preview_entity in pairs(mapping) do
		if preview_entity and preview_entity.valid and preview_entity.name == constants.spidertron_requester_chest then
			
			-- Find the SOURCE entity by position matching
			local source_entity = nil
			local source_data = nil
			
			for unit_num, requester_data in pairs(storage.requesters) do
				if requester_data.entity and requester_data.entity.valid then
					local entity = requester_data.entity
					-- Match by position (within 0.5 tiles) and surface
					if entity.surface == preview_entity.surface and
					   math.abs(entity.position.x - preview_entity.position.x) < 0.5 and
					   math.abs(entity.position.y - preview_entity.position.y) < 0.5 then
						source_entity = entity
						source_data = requester_data
						break
					end
				end
			end
			
			if not source_data then
				goto next_entity
			end
			
			-- Find the blueprint entity index
			for i, entity_data in ipairs(blueprint_entities) do
				if entity_data.name == preview_entity.name then
					local pos_match = math.abs(entity_data.position.x - preview_entity.position.x) < 0.1 and
					                  math.abs(entity_data.position.y - preview_entity.position.y) < 0.1
					if pos_match then
						-- Save requested_items
						if source_data.requested_items then
							local items_list = {}
							for item_name, item_data in pairs(source_data.requested_items) do
								if item_name and item_name ~= '' then
									local count
									if type(item_data) == "table" then
										count = item_data.count or 0
									else
										count = item_data or 0
									end
									if count > 0 then
										table.insert(items_list, {name = item_name, count = count})
									end
								end
							end
							
							pcall(function()
								blueprint.set_blueprint_entity_tag(i, 'requested_items', items_list)
							end)
						elseif source_data.requested_item then
							-- Legacy format support
							blueprint.set_blueprint_entity_tag(i, 'requested_item', source_data.requested_item)
							blueprint.set_blueprint_entity_tag(i, 'request_size', source_data.request_size)
						end
						break
					end
				end
			end
		end
		::next_entity::
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
	
	if cursor and cursor.valid_for_read and cursor.type == 'blueprint' and mapping then
		-- Count entries in mapping (it's a dictionary, not an array)
		local mapping_count = 0
		for _ in pairs(mapping) do
			mapping_count = mapping_count + 1
		end
		
		if mapping_count == cursor.get_blueprint_entity_count() then
			save_blueprint_data(cursor, mapping)
		end
	end
	storage.blueprint_mappings[player.index] = nil
end)

-- Setup and initialization
local function setup()
	-- Clean up all GUI elements first (important for migrations and mod reloads)
	gui.cleanup_all_guis()
	
	storage.spiders = storage.spiders or {}
	storage.requesters = storage.requesters or {}
	storage.requester_guis = storage.requester_guis or {}
	storage.providers = storage.providers or {}
	storage.beacons = storage.beacons or {}
	storage.beacon_assignments = storage.beacon_assignments or {}
	storage.blueprint_mappings = storage.blueprint_mappings or {}
	storage.pathfinding_cache = storage.pathfinding_cache or {}
	storage.distance_cache = storage.distance_cache or {}
	storage.path_requests = storage.path_requests or {}
	storage.pathfinder_statuses = storage.pathfinder_statuses or {}
	storage.robot_chest_cache = storage.robot_chest_cache or {}
	
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
	-- Close item picker GUI (selection list) if it was opened by clicking a slot with an existing item
	-- Do this on every tick (not just every 10) to catch it immediately
	if storage.close_item_picker_next_tick then
		for player_index, should_close in pairs(storage.close_item_picker_next_tick) do
			if should_close then
				local player = game.get_player(player_index)
				if player and player.valid then
					local gui_data = storage.requester_guis[player_index]
					if gui_data and gui_data.last_opened_requester then
						local requester_entity = gui_data.last_opened_requester.entity
						if requester_entity and requester_entity.valid then
							-- Ensure player.opened is set to our requester
							if player.opened ~= requester_entity then
								player.opened = requester_entity
							end
							
							-- Close selection list GUI (the item picker opened by choose-elem-button)
							-- Selection list GUIs are screen GUIs, look for them and close
							local screen = player.gui.screen
							if screen then
								-- Iterate through screen children to find selection list GUI
								-- Selection list GUIs are usually frames with specific structure
								for _, child in pairs(screen.children) do
									if child and child.valid then
										local child_name = child.name or ""
										-- Check if this looks like a selection list GUI
										-- Selection list GUIs typically have a list-box or similar structure
										-- We can identify them by checking for list-box children or specific names
										local has_list_box = false
										for _, subchild in pairs(child.children) do
											if subchild and subchild.valid and subchild.type == "list-box" then
												has_list_box = true
												break
											end
										end
										
										-- If it has a list-box, it's likely the selection list GUI - close it
										if has_list_box then
											child.destroy()
											break
										end
										
										-- Also check if it's a frame with a name that suggests it's a selection list
										if child.type == "frame" and child_name ~= "" and (child_name:find("selection") or child_name:find("list") or child_name:find("picker")) then
											child.destroy()
											break
										end
									end
								end
							end
						end
					end
					-- Clear the flag after one tick
					storage.close_item_picker_next_tick[player_index] = nil
				end
			end
		end
	end

	-- Only check every 10 ticks for performance (rest of the function)
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

commands.add_command("cleanup", "Clear old flow-based GUI (the stuck one with no name)", function(event)
    local player = game.get_player(event.player_index)
    if not player or not player.valid then return end
    
    local relative_gui = player.gui.relative
    if not relative_gui then 
        player.print("No relative GUI found")
        return 
    end
    
    local count = 0
    
    -- ONLY clean up old flow-based GUI (no name, no anchor) - DO NOT destroy the new frame GUI!
    for _, child in pairs(relative_gui.children) do
        if child and child.valid then
            -- Only target flow elements (old GUI was a flow, new GUI is a frame)
            if child.type == 'flow' then
                -- Check if name exists and is not empty
                local has_name = child.name ~= nil and child.name ~= ''
                local has_anchor = child.anchor ~= nil
                
                -- Destroy flows with no name and no anchor (stuck old GUI)
                if not has_name and not has_anchor then
                    child.destroy()
                    count = count + 1
                -- Also destroy flows with requester chest anchor (old GUI with anchor)
                elseif has_anchor and child.anchor.gui == defines.relative_gui_type.container_gui 
                       and child.anchor.name == constants.spidertron_requester_chest then
                    child.destroy()
                    count = count + 1
                end
            end
            -- DO NOT destroy frames - the new GUI is a frame and should be kept!
        end
    end
    
    -- Also close any open item selector modals (these are safe to close)
    if player.gui.screen["spidertron_item_selector"] then
        player.gui.screen["spidertron_item_selector"].destroy()
        count = count + 1
    end
    
    if count > 0 then
        player.print("Destroyed " .. count .. " old GUI elements (kept new frame GUI)")
    else
        player.print("No old GUI elements found to clean up")
    end
end)

commands.add_command("debug-gui", "Show all GUIs", function(event)
    local player = game.get_player(event.player_index)
    if not player or not player.valid then return end
    
    player.print("=== ALL GUI ELEMENTS ===")
    
    local relative_gui = player.gui.relative
    if not relative_gui then
        player.print("No relative GUI found")
        return
    end
    
    local count = 0
    for _, child in pairs(relative_gui.children) do
        if child and child.valid then
            count = count + 1
            local anchor_info = "No anchor"
            -- Anchor is a PROPERTY, not a method!
            if child.anchor then
                local anchor_name = child.anchor.name or "no name"
                local anchor_gui = child.anchor.gui or "unknown"
                anchor_info = "Anchor: " .. anchor_name .. " (gui: " .. tostring(anchor_gui) .. ")"
            end
            
            local name = child.name or "(empty)"
            local direction = ""
            if child.type == 'flow' and child.direction then
                direction = ", Direction: " .. child.direction
            end
            player.print(count .. ". Type: " .. child.type .. ", Name: " .. name .. direction .. ", " .. anchor_info)
        end
    end
    
    player.print("Total: " .. count .. " elements")
end)

script.on_init(setup)
script.on_configuration_changed(setup)

