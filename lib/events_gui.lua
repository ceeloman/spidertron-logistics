-- GUI event handlers for spidertron logistics

local constants = require('lib.constants')
local utils = require('lib.utils')
local beacon_assignment = require('lib.beacon_assignment')
local registration = require('lib.registration')
local gui = require('lib.gui')
local journey = require('lib.journey')
local pathing = require('lib.pathing')
local rendering = require('lib.rendering')
local shared_toolbar = require("__ceelos-vehicle-gui-util__/lib/shared_toolbar")

local events_gui = {}

function events_gui.register()
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
							local request_count = slot.count or 50
							requester_data.requested_items[slot.item] = {
								count = request_count,
								buffer_threshold = slot.buffer or 0.8,
								allow_excess_provider = slot.allow_excess_provider ~= nil and slot.allow_excess_provider or true
							}
							
							if requester_data.entity and requester_data.entity.valid then
								-- Update entity tags so requests are copied when entity is copied
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
				shared_toolbar.remove_from_shared_toolbar(player, "spidertron-logistics", "repath")
				
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

	-- Handle custom input for requests debug GUI
	script.on_event("spidertron-logistics-requests-gui", function(event)
		local player = game.get_player(event.player_index)
		if not player or not player.valid then return end
		
		-- Toggle GUI (close if open, open if closed)
		local existing_frame = player.gui.screen["spidertron_requests_debug_frame"]
		if existing_frame and existing_frame.valid then
			gui.close_requests_debug_gui(player)
		else
			gui.open_requests_debug_gui(player)
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
									-- No storage chests available, trigger immediate job check instead of pathing to beacon
									spider_data.needs_immediate_job_check = true
									game.print("[ACTIVATION] Tick " .. game.tick .. ": Spider " .. vehicle.unit_number .. " activated, no items to dump, setting needs_immediate_job_check flag")
								end
							else
								-- No items to dump, trigger immediate job check
								spider_data.needs_immediate_job_check = true
								game.print("[ACTIVATION] Tick " .. game.tick .. ": Spider " .. vehicle.unit_number .. " activated, no items to dump, setting needs_immediate_job_check flag")
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
					if requester_data.entity and requester_data.entity.valid then
						-- Update entity tags so requests are copied when entity is copied
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
		
		-- Handle requests debug GUI refresh button
		if element.name == 'spidertron_requests_debug_refresh' then
			if player and player.valid then
				gui.close_requests_debug_gui(player)
				gui.open_requests_debug_gui(player)
			end
			return
		end
		
		-- Handle requests debug GUI close button
		if element.name == 'spidertron_requests_debug_close' then
			if player and player.valid then
				gui.close_requests_debug_gui(player)
			end
			return
		end
		
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
					
					if requester_data.entity and requester_data.entity.valid then
						-- Update entity tags so requests are copied when entity is copied
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
				local request_count = slot.count or 50
				requester_data.requested_items[slot.item] = {
					count = request_count,
					buffer_threshold = slot.buffer or 0.8,
					allow_excess_provider = slot.allow_excess_provider ~= nil and slot.allow_excess_provider or true
				}
				
				if requester_data.entity and requester_data.entity.valid then
					-- Update entity tags so requests are copied when entity is copied
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
								-- Start dumping - immediate job check will happen after dump completes
								local dump_success = journey.attempt_dump_items(vehicle.unit_number)
								-- If dump failed (no storage chests), trigger immediate job check
								if not dump_success then
									-- No storage chests available, trigger immediate job check instead of pathing to beacon
									spider_data.needs_immediate_job_check = true
									game.print("[ACTIVATION] Tick " .. game.tick .. ": Spider " .. vehicle.unit_number .. " activated, dump failed (no storage), setting needs_immediate_job_check flag")
								end
							else
								-- No items to dump, trigger immediate job check instead of pathing to beacon
								spider_data.needs_immediate_job_check = true
								game.print("[ACTIVATION] Tick " .. game.tick .. ": Spider " .. vehicle.unit_number .. " activated, no items to dump, setting needs_immediate_job_check flag")
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
		
		-- Handle repath button click
		if element.name == 'spidertron-logistics_repath' then
			local vehicle = player.opened
			if vehicle and vehicle.valid and vehicle.type == 'spider-vehicle' then
				local spider_data = storage.spiders[vehicle.unit_number]
				if spider_data then
					local spider = spider_data.entity
					if spider and spider.valid then
						-- Check if vehicle has an autopilot queue
						if spider.autopilot_destinations and #spider.autopilot_destinations > 0 then
							-- Get the final destination (last element in queue)
							local final_destination = spider.autopilot_destinations[#spider.autopilot_destinations]
							
							if final_destination then
								-- Clear current autopilot destination to allow repathing
								spider.autopilot_destination = nil
								
								-- Request new path to the final destination
								local pathing_success = pathing.set_smart_destination(spider, final_destination, nil)
								if not pathing_success then
									-- Path request failed
									player.play_sound{path = "utility/cannot_build"}
								end
							else
								-- No destination in queue
								player.play_sound{path = "utility/cannot_build"}
							end
						else
							-- No autopilot queue, can't repath
							player.play_sound{path = "utility/cannot_build"}
						end
					end
				end
			end
			return
		end
		
		-- Handle player GUI toolbar button clicks (when holding spidertron remote)
		local selected_spiders = player.spidertron_remote_selection
		if selected_spiders and #selected_spiders > 0 then
			-- Filter to valid spiders
			local valid_spiders = {}
			for _, spider in ipairs(selected_spiders) do
				if spider and spider.valid and spider.type == "spider-vehicle" then
					table.insert(valid_spiders, spider)
				end
			end
			
			if #valid_spiders > 0 then
				-- Handle player GUI toggle button
				if element.name == 'spidertron-logistics_player_toggle' then
					-- Toggle logistics for all selected spidertrons
					local any_active = false
					for _, spider in ipairs(valid_spiders) do
						local spider_data = storage.spiders[spider.unit_number]
						if spider_data and spider_data.active ~= false then
							any_active = true
							break
						end
					end
					
					local new_active = not any_active
					
					-- Apply toggle to all selected spidertrons
					for _, spider in ipairs(valid_spiders) do
						local spider_data = storage.spiders[spider.unit_number]
						if not spider_data then
							registration.register_spider(spider)
							spider_data = storage.spiders[spider.unit_number]
						end
						
						if spider_data then
							local was_active = spider_data.active or false
							spider_data.active = new_active
							
							-- Handle activation/deactivation
							if new_active and not was_active then
								-- Spider is being activated
								if spider.valid then
									-- Check if spider has items to dump
									if journey.has_dumpable_items(spider.unit_number) then
										local dump_success = journey.attempt_dump_items(spider.unit_number)
										if not dump_success then
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
										-- No items to dump, trigger immediate job check instead of pathing to beacon
										spider_data.needs_immediate_job_check = true
										game.print("[ACTIVATION] Tick " .. game.tick .. ": Spider " .. spider.unit_number .. " activated, no items to dump, setting needs_immediate_job_check flag")
									end
								end
							elseif not new_active and was_active then
								-- Spider is being deactivated
								journey.end_journey(spider.unit_number, false)
							end
						end
					end
					
					-- Update button state
					gui.update_toggle_button_color(element, new_active)
					
					-- Update toolbar to reflect new state
					gui.add_player_gui_toolbar(player)
					return
				end
				
				-- Handle player GUI dump button
				if element.name == 'spidertron-logistics_player_dump' then
					-- Dump items for all selected spidertrons
					for _, spider in ipairs(valid_spiders) do
						if spider.valid then
							journey.attempt_dump_items(spider.unit_number)
						end
					end
					return
				end
				
				-- Handle player GUI remote button
				if element.name == 'spidertron-logistics_player_remote' then
					-- Get spidertron remote for first selected spider (or all if multiple)
					if #valid_spiders == 1 then
						gui.get_spidertron_remote(player, valid_spiders[1])
					else
						-- Multiple spiders selected - just get remote for first one
						gui.get_spidertron_remote(player, valid_spiders[1])
					end
					return
				end
				
				-- Handle player GUI repath button
				if element.name == 'spidertron-logistics_player_repath' then
					-- Repath all selected spidertrons that have autopilot queues
					for _, spider in ipairs(valid_spiders) do
						if spider.valid then
							if spider.autopilot_destinations and #spider.autopilot_destinations > 0 then
								local final_destination = spider.autopilot_destinations[#spider.autopilot_destinations]
								
								if final_destination then
									spider.autopilot_destination = nil
									local pathing_success = pathing.set_smart_destination(spider, final_destination, nil)
									if not pathing_success then
										player.play_sound{path = "utility/cannot_build"}
									end
								end
							end
						end
					end
					
					-- Update toolbar to reflect repath button visibility
					gui.add_player_gui_toolbar(player)
					return
				end
				
				-- Handle player GUI neural connect button
				if element.name == 'spidertron-logistics_player_neural_connect' then
					if script.active_mods["neural-spider-control"] then
						local tags = element.tags
						if tags and tags.unit_number and tags.surface_index then
							local surface = game.surfaces[tags.surface_index]
							if surface then
								-- Find the spidertron by unit number
								local spidertron = nil
								local entities = surface.find_entities_filtered{type = "spider-vehicle"}
								for _, entity in ipairs(entities) do
									if entity.unit_number == tags.unit_number then
										spidertron = entity
										break
									end
								end
								
								if spidertron and spidertron.valid then
									-- Call neural connect function
									local success, neural_connect = pcall(function()
										return require("__neural-spider-control__.scripts.neural_connect")
									end)
									if success and neural_connect and neural_connect.connect_to_spidertron then
										neural_connect.connect_to_spidertron({
											player_index = player.index,
											spidertron = spidertron
										})
									else
										player.print("Failed to connect: Neural Spider Control mod may not be properly loaded.", {r=1, g=0.5, b=0})
									end
								else
									player.print("Spidertron no longer exists.", {r=1, g=0.5, b=0})
								end
							else
								player.print("Surface not found.", {r=1, g=0.5, b=0})
							end
						end
					end
					return
				end
				
				-- Handle player GUI check character inventory button
				if element.name == 'spidertron-logistics_player_check_character_inventory' then
					if script.active_mods["neural-spider-control"] then
						local tags = element.tags
						if tags and tags.engineer_unit_number then
							-- Try to find the engineer by unit_number from storage
							local engineer = nil
							
							-- Check orphaned engineers first
							if storage.orphaned_dummy_engineers then
								local orphaned_data = storage.orphaned_dummy_engineers[tags.engineer_unit_number]
								if orphaned_data and orphaned_data.entity and orphaned_data.entity.valid then
									engineer = orphaned_data.entity
								end
							end
							
							-- Also check active connections in case it's no longer orphaned
							if not engineer and storage.neural_spider_control and storage.neural_spider_control.dummy_engineers then
								for _, dummy_data in pairs(storage.neural_spider_control.dummy_engineers) do
									local dummy_entity = type(dummy_data) == "table" and dummy_data.entity or dummy_data
									if dummy_entity and dummy_entity.valid and dummy_entity.unit_number == tags.engineer_unit_number then
										engineer = dummy_entity
										break
									end
								end
							end
							
							if engineer and engineer.valid then
								-- Open the engineer's inventory
								player.opened = engineer
							else
								player.print("Engineer no longer exists.", {r=1, g=0.5, b=0})
							end
						end
					end
					return
				end
			end
		end
	end)
end

return events_gui

