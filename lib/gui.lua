-- GUI handling for requester chests and spidertron toggle

local constants = require('lib.constants')
local registration = require('lib.registration')
local logistics = require('lib.logistics')
local glib = require("__glib__/glib")
local shared_toolbar = require("__ceelos-vehicle-gui-util__/lib/shared_toolbar")

local gui = {}

local MOD_NAME = "spidertron-logistics"

-- Clean up all GUI elements for all players (called on mod load/reload)
function gui.cleanup_all_guis()
	-- Clean up all GUI elements for all players
	for _, player in pairs(game.players) do
		if player and player.valid then
			-- Clean up screen GUIs (modal dialogs, beacon info, etc.)
			local screen_gui = player.gui.screen
			if screen_gui then
				-- Remove item selector modal
				local item_selector = screen_gui["spidertron_item_selector"]
				if item_selector and item_selector.valid then
					item_selector.destroy()
				end
				
				-- Remove beacon info frame
				local beacon_frame = screen_gui["spidertron_beacon_info_frame"]
				if beacon_frame and beacon_frame.valid then
					beacon_frame.destroy()
				end
			end
			
			-- Clean up relative GUIs
			local relative_gui = player.gui.relative
			if relative_gui then
				-- CRITICAL: Remove OLD flow-based requester chest GUI (from previous version)
				-- The OLD GUI was: type = 'flow' (vertical_flow) with anchor.name = constants.spidertron_requester_chest
				-- Structure: vertical_flow (flow, vertical) → item_logistic_gui (frame) → slots_flow (flow, horizontal)
				-- DEBUG SHOWS: The stuck GUI is a flow with NO NAME and NO ANCHOR
				-- AGGRESSIVE CLEANUP: Destroy ANY flow with no name and no anchor (new GUI is a frame with a name)
				for _, child in ipairs(relative_gui.children) do
					if child and child.valid and child.type == 'flow' then
						-- Check if name exists and is not empty (handle both nil and empty string)
						local has_name = child.name ~= nil and child.name ~= ''
						local has_anchor = child.anchor ~= nil
						
						-- Check if it has the requester chest anchor (anchor is a PROPERTY, not a method!)
						if has_anchor then
							if child.anchor.gui == defines.relative_gui_type.container_gui 
							   and child.anchor.name == constants.spidertron_requester_chest then
								-- This is the OLD flow-based GUI with anchor - destroy it
								child.destroy()
							end
						-- If no anchor AND no name, destroy it (matches stuck old GUI pattern)
						-- New GUI is a frame with name 'spidertron_requester_gui_frame', so any unnamed flow is old
						elseif not has_name then
							-- Destroy any flow with no name and no anchor - this is the stuck old GUI
							child.destroy()
						end
					end
				end
				
				-- Remove requester chest GUI by name (catches both old and new)
				local requester_gui = relative_gui[constants.spidertron_requester_chest]
				if requester_gui and requester_gui.valid then
					-- Only destroy if it's not the new GUI frame
					if requester_gui.name ~= 'spidertron_requester_gui_frame' then
						requester_gui.destroy()
					end
				end
				
				-- Remove new GUI frame by name
				local new_gui_frame = relative_gui["spidertron_requester_gui_frame"]
				if new_gui_frame and new_gui_frame.valid then
					new_gui_frame.destroy()
				end
				
				-- Remove old spidertron toggle frame (legacy)
				local toggle_frame = relative_gui["spidertron_logistics_toggle_frame"]
				if toggle_frame and toggle_frame.valid then
					toggle_frame.destroy()
				end
				
				-- Remove shared toolbar completely (it will be recreated with correct style on next open)
				-- This ensures style changes take effect after mod reload
				local toolbar = relative_gui[shared_toolbar.SHARED_TOOLBAR_NAME]
				if toolbar and toolbar.valid then
					toolbar.destroy()
				end
				
				-- Remove player GUI toolbar (in player GUI left)
				local left_gui = player.gui.left
				if left_gui then
					local player_toolbar = left_gui[MOD_NAME .. "_player_gui_toolbar"]
					if player_toolbar and player_toolbar.valid then
						player_toolbar.destroy()
					end
				end
			end
		end
	end
	
	-- Clear GUI data storage - this is important!
	storage.requester_guis = {}
end

-- Development cleanup function - removes all GUI elements (can be removed after development)
function gui.cleanup_all_guis_dev()
	for _, player in pairs(game.players) do
		if player and player.valid then
			-- Clean up screen GUIs
			if player.gui.screen["spidertron_item_selector"] then 
				player.gui.screen["spidertron_item_selector"].destroy() 
			end
			
			if player.gui.screen["spidertron_beacon_info_frame"] then 
				player.gui.screen["spidertron_beacon_info_frame"].destroy() 
			end
			
			-- Clean up relative GUIs
			if player.gui.relative then
				if player.gui.relative["spidertron_logistics_toggle_frame"] then 
					player.gui.relative["spidertron_logistics_toggle_frame"].destroy() 
				end
				
				if player.gui.relative["spidertron_shared_toolbar"] then 
					player.gui.relative["spidertron_shared_toolbar"].destroy() 
				end
				
				-- CRITICAL: Clean up OLD flow-based requester chest GUI (from previous version)
				-- The OLD GUI was: type = 'flow' (vertical_flow) with anchor.name = constants.spidertron_requester_chest
				-- Structure: vertical_flow (flow, vertical) → item_logistic_gui (frame) → slots_flow (flow, horizontal)
				-- DEBUG SHOWS: The stuck GUI is a flow with NO NAME and NO ANCHOR
				-- AGGRESSIVE CLEANUP: Destroy ANY flow with no name and no anchor (new GUI is a frame with a name)
				for _, child in pairs(player.gui.relative.children) do
					if child and child.valid then
						-- Check if it's a flow type with the requester chest anchor (anchor is a PROPERTY, not a method!)
						if child.type == 'flow' then
							-- Check if name exists and is not empty (handle both nil and empty string)
							local has_name = child.name ~= nil and child.name ~= ''
							local has_anchor = child.anchor ~= nil
							
							if has_anchor then
								if child.anchor.gui == defines.relative_gui_type.container_gui 
								   and child.anchor.name == constants.spidertron_requester_chest then
									child.destroy()
								end
							-- If no anchor AND no name, destroy it (matches stuck old GUI pattern)
							-- New GUI is a frame with name 'spidertron_requester_gui_frame', so any unnamed flow is old
							elseif not has_name then
								-- Destroy any flow with no name and no anchor - this is the stuck old GUI
								child.destroy()
							end
						-- Also clean up by name (catches both old and new)
						elseif child.name == "spidertron-requester-chest" then 
							child.destroy() 
						end
					end
				end
				
				-- Also clean up new GUI frame by name
				if player.gui.relative["spidertron_requester_gui_frame"] then
					player.gui.relative["spidertron_requester_gui_frame"].destroy()
				end
			end
		end
	end
	
	-- Clear GUI data storage
	storage.requester_guis = {}
end

function gui.cleanup_old_guis(player_index)
	local player = game.get_player(player_index)
	if not player or not player.valid then return end
	
	-- Clean up old GUI structures that might exist
	local relative_gui = player.gui.relative
	if not relative_gui then return end
	
	-- CRITICAL: Clean up OLD flow-based GUI (the stuck one from previous version)
	-- The OLD GUI was: type = 'flow' (vertical_flow) with anchor.name = constants.spidertron_requester_chest
	-- It had structure: vertical_flow → item_logistic_gui → slots_flow
	-- DEBUG SHOWS: The stuck GUI is a flow with NO NAME and NO ANCHOR
	-- AGGRESSIVE CLEANUP: Destroy ANY flow with no name and no anchor (new GUI is a frame with a name)
	for _, child in ipairs(relative_gui.children) do
		if child and child.valid then
			-- Check if it's a flow type (OLD GUI structure)
			if child.type == 'flow' then
				-- Check if name exists and is not empty (handle both nil and empty string)
				local has_name = child.name ~= nil and child.name ~= ''
				local has_anchor = child.anchor ~= nil
				
				-- Check if it has the requester chest anchor (if anchor exists)
				if has_anchor then
					if child.anchor.gui == defines.relative_gui_type.container_gui 
					   and child.anchor.name == constants.spidertron_requester_chest then
						-- This is the OLD flow-based GUI with anchor - destroy it
						child.destroy()
					end
				-- If no anchor AND no name, destroy it (matches stuck old GUI pattern)
				-- New GUI is a frame with name 'spidertron_requester_gui_frame', so any unnamed flow is old
				elseif not has_name then
					-- Destroy any flow with no name and no anchor - this is the stuck old GUI
					child.destroy()
				end
			end
		end
	end
	
	-- Also check by name (in case old GUI had a name)
	local old_by_name = relative_gui[constants.spidertron_requester_chest]
	if old_by_name and old_by_name.valid then
		-- If it's a flow type, it's definitely the old GUI
		if old_by_name.type == 'flow' then
			old_by_name.destroy()
		-- If it's a frame but not our new frame, check structure
		elseif old_by_name.type == 'frame' and old_by_name.name ~= 'spidertron_requester_gui_frame' then
			-- Check if it has the new structure (frame with "Logistic Requests" caption)
			local has_new_structure = false
			for _, subchild in ipairs(old_by_name.children) do
				if subchild.type == 'frame' and subchild.caption == 'Logistic Requests' then
					has_new_structure = true
					break
				end
			end
			if not has_new_structure then
				old_by_name.destroy()
			end
		end
	end
	
	-- Remove old frame-based GUI (if it exists and is not the new one)
	local old_frame = relative_gui[constants.spidertron_requester_chest]
	if old_frame and old_frame.valid and old_frame.type == 'frame' then
		-- Only destroy if it's not the new GUI frame
		if old_frame.name ~= 'spidertron_requester_gui_frame' then
			-- Check if it has old structure (no "Logistic Requests" frame)
			local has_new_structure = false
			for _, child in ipairs(old_frame.children) do
				if child.type == 'frame' and child.caption == 'Logistic Requests' then
					has_new_structure = true
					break
				end
			end
			-- If it's the old structure, destroy it
			if not has_new_structure then
				old_frame.destroy()
			end
		end
	end
end

function gui.requester_gui(player_index)
	local player = game.get_player(player_index)
	if not player or not player.valid then return nil end
	
	local relative_gui = player.gui.relative
	
	-- Clean up NEW GUI (frame with name)
	local existing = relative_gui["spidertron_requester_gui_frame"]
	if existing and existing.valid then
		existing.destroy()
	end
	
	-- Clean up OLD GUI from storage 
	local old_gui_data = storage.requester_guis[player_index]
	if old_gui_data then
		if old_gui_data.vertical_flow and old_gui_data.vertical_flow.valid then
			old_gui_data.vertical_flow.destroy()
		end
	end
	
	-- CRITICAL: Clean up OLD flow-based GUI (the stuck one from previous version)
	-- The OLD GUI was: type = 'flow' (vertical_flow) with anchor.name = constants.spidertron_requester_chest
	-- Structure: vertical_flow (flow, vertical) → item_logistic_gui (frame) → slots_flow (flow, horizontal)
	-- DEBUG SHOWS: The stuck GUI is a flow with NO NAME and NO ANCHOR
	-- AGGRESSIVE CLEANUP: Destroy ANY flow with no name and no anchor (new GUI is a frame with a name)
	if relative_gui then
		-- First pass: destroy any flow type elements with the requester chest anchor (if anchor exists)
		local to_destroy = {}
		for _, child in ipairs(relative_gui.children) do
			if child and child.valid and child.type == 'flow' then
				-- Check if name exists and is not empty (handle both nil and empty string)
				local has_name = child.name ~= nil and child.name ~= ''
				local has_anchor = child.anchor ~= nil
				
				-- Check if it has the requester chest anchor (anchor is a PROPERTY, not a method!)
				if has_anchor then
					if child.anchor.gui == defines.relative_gui_type.container_gui 
					   and child.anchor.name == constants.spidertron_requester_chest then
						-- This is the OLD flow-based GUI with anchor - mark for destruction
						table.insert(to_destroy, child)
					end
				-- If no anchor AND no name, destroy it (matches stuck old GUI pattern)
				-- New GUI is a frame with name 'spidertron_requester_gui_frame', so any unnamed flow is old
				elseif not has_name then
					-- Destroy any flow with no name and no anchor - this is the stuck old GUI
					table.insert(to_destroy, child)
				end
			end
		end
		-- Destroy all marked elements
		for _, element in ipairs(to_destroy) do
			if element.valid then
				element.destroy()
			end
		end
		
		-- Second pass: also check by name (in case old GUI had a name)
		local old_by_name = relative_gui[constants.spidertron_requester_chest]
		if old_by_name and old_by_name.valid and old_by_name.type == 'flow' then
			-- Definitely the old GUI - destroy it
			old_by_name.destroy()
		end
	end
	
	-- Create main container with a NAME
	local main_frame = player.gui.relative.add{
		type = 'frame',
		name = 'spidertron_requester_gui_frame',
		direction = 'vertical',
		anchor = {
			gui = defines.relative_gui_type.container_gui,
			position = defines.relative_gui_position.right,
			name = constants.spidertron_requester_chest
		}
	}
	
	-- Title bar
	local title_flow = main_frame.add{
		type = 'flow',
		direction = 'horizontal'
	}
	title_flow.style.horizontal_spacing = 8
	
	local title_label = title_flow.add{
		type = 'label',
		caption = 'Logistic Requests',
		style = 'frame_title'
	}
	title_label.style.font = 'heading-1'
	
	local pusher = title_flow.add{
		type = 'empty-widget',
		style = 'draggable_space_header'
	}
	pusher.style.horizontally_stretchable = true
	pusher.style.height = 24
	
	-- Content frame
	local content_frame = main_frame.add{
		type = 'frame',
		direction = 'vertical',
		style = 'inside_shallow_frame_with_padding'
	}
	
	-- Status section (beacon assignment, items delivered, reconnect button)
	local status_frame = content_frame.add{
		type = 'frame',
		name = 'status_section',
		direction = 'vertical',
		style = 'inside_shallow_frame'
	}
	status_frame.style.padding = 8
	status_frame.style.bottom_margin = 8
	
	-- Status flow for beacon indicator and items delivered
	local status_flow = status_frame.add{
		type = 'flow',
		direction = 'horizontal'
	}
	status_flow.style.vertical_align = 'center'
	status_flow.style.horizontal_spacing = 8
	
	-- Beacon status indicator (light green if assigned) - tooltip shows status
	local beacon_indicator = status_flow.add{
		type = 'sprite',
		name = 'beacon_status_indicator',
		sprite = 'utility/status_not_working',
		tooltip = 'No Beacon'
	}
	beacon_indicator.style.size = 20
	
	-- Items delivered count
	local items_delivered_label = status_flow.add{
		type = 'label',
		name = 'items_delivered_label',
		caption = 'Items Delivered: 0'
	}
	items_delivered_label.style.font = 'default'
	
	-- Pusher to push reconnect button to the right
	local status_pusher = status_flow.add{
		type = 'empty-widget'
	}
	status_pusher.style.horizontally_stretchable = true
	
	-- Reconnect beacon icon button (sprite-button for smaller width)
	local reconnect_button = status_flow.add{
		type = 'sprite-button',
		name = 'reconnect_beacon_button',
		sprite = 'entity/spidertron-logistic-beacon',
		style = 'slot_button_in_shallow_frame',
		tooltip = 'Force reconnection to nearest beacon'
	}
	reconnect_button.style.size = 32
	
	-- Divider before item slots
	local status_divider = content_frame.add{
		type = 'line',
		direction = 'horizontal'
	}
	status_divider.style.top_margin = 4
	status_divider.style.bottom_margin = 8
	
	-- Item slots section
	local slots_label = content_frame.add{
		type = 'label',
		caption = 'Items:'
	}
	slots_label.style.font = 'default-semibold'
	slots_label.style.bottom_margin = 4
	
	local slots_table = content_frame.add{
		type = 'table',
		column_count = 5
	}
	slots_table.style.horizontal_spacing = 4
	slots_table.style.vertical_spacing = 4
	
	-- Create 10 item slots using choose-elem-button (opens native item picker)
	-- Simple vertical layout: icon on top, count below
	local item_slots = {}
	for i = 1, 10 do
		-- Vertical flow for icon and count
		local slot_flow = slots_table.add{
			type = 'flow',
			direction = 'vertical'
		}
		slot_flow.style.vertical_align = 'center'
		slot_flow.style.horizontal_align = 'center'
		slot_flow.style.vertical_spacing = 2
		
		-- Item chooser button (for empty slots - opens item picker)
		local chooser = slot_flow.add{
			type = 'choose-elem-button',
			name = 'spidertron_slot_' .. i,
			elem_type = 'item',
			style = 'slot_button_in_shallow_frame'
		}
		chooser.style.size = 40
		
		-- Sprite-button overlay (for slots with items - opens settings instead of item picker)
		-- This replaces the chooser when a slot has an item
		local overlay_button = slot_flow.add{
			type = 'sprite-button',
			name = 'spidertron_slot_overlay_' .. i,
			style = 'slot_button_in_shallow_frame'
		}
		overlay_button.style.size = 40
		overlay_button.visible = false  -- Hidden by default, shown when item is set
		overlay_button.enabled = true
		
		table.insert(item_slots, {
			flow = slot_flow,
			chooser = chooser,
			overlay_button = overlay_button,
			item = nil,
			count = 0,
			buffer = 0.8,
			allow_excess_provider = true
		})
	end
	
	-- Settings section (initially hidden, shown when slot selected)
	local settings_frame = content_frame.add{
		type = 'frame',
		name = 'settings_section',
		direction = 'vertical',
		style = 'inside_shallow_frame'
	}
	settings_frame.style.padding = 8
	settings_frame.visible = false
	
	-- Selected item display
	local selected_item_flow = settings_frame.add{
		type = 'flow',
		direction = 'horizontal'
	}
	selected_item_flow.style.vertical_align = 'center'
	selected_item_flow.style.bottom_margin = 8
	
	local selected_label = selected_item_flow.add{
		type = 'label',
		caption = {'gui.requester-selected'}
	}
	selected_label.style.font = 'default-semibold'
	
	local selected_item_sprite = selected_item_flow.add{
		type = 'sprite',
		name = 'selected_item_sprite',
		sprite = ''
	}
	selected_item_sprite.style.size = 24
	selected_item_sprite.style.stretch_image_to_widget_size = true
	
	local selected_item_label = selected_item_flow.add{
		type = 'label',
		name = 'selected_item_name',
		caption = 'None'
	}
	
	-- Request amount setting
	local request_amount_label = settings_frame.add{
		type = 'label',
		caption = {'gui.requester-request-amount'}
	}
	request_amount_label.style.font = 'default-semibold'
	request_amount_label.style.bottom_margin = 4
	
	local request_amount_flow = settings_frame.add{
		type = 'flow',
		direction = 'horizontal'
	}
	request_amount_flow.style.vertical_align = 'center'
	request_amount_flow.style.bottom_margin = 8
	
	-- Slider will be created dynamically with stack-based increments
	-- Slider max is high enough, we'll clamp values to 10 stacks when setting
	local request_amount_slider = request_amount_flow.add{
		type = 'slider',
		name = 'request_amount_slider',
		minimum_value = 1,
		maximum_value = 11,  -- The slider maps: 1=1 item, 2=1 stack, 3=2 stacks, ..., 11=10 stacks
		value = 2  -- Default to position 2 (1 stack)
	}
	-- The slider is used as an abstract selector: 1 = 1 item, 2 = 1 stack, 3 = 2 stacks, ..., 11 = 10 stacks
	request_amount_slider.set_slider_value_step(1)
	request_amount_slider.style.horizontally_stretchable = true
	request_amount_slider.style.width = 200
	
	local request_amount_textfield = request_amount_flow.add{
		type = 'textfield',
		name = 'request_amount_textfield',
		text = '50',
		numeric = true,
		allow_negative = false,
		allow_decimal = false
	}
	request_amount_textfield.style.width = 60
	request_amount_textfield.style.left_margin = 8
	
	-- Buffer threshold setting
	local buffer_label_flow = settings_frame.add{
		type = 'flow',
		direction = 'horizontal'
	}
	buffer_label_flow.style.vertical_align = 'center'
	buffer_label_flow.style.bottom_margin = 4
	
	local buffer_label = buffer_label_flow.add{
		type = 'label',
		caption = {'gui.requester-buffer-threshold'}
	}
	buffer_label.style.font = 'default-semibold'
	
	-- Info sprite with tooltip
	local buffer_info = buffer_label_flow.add{
		type = 'sprite',
		name = 'buffer_info',
		sprite = 'info',
		tooltip = {'gui.requester-buffer-info-tooltip'}
	}
	buffer_info.style.size = 20
	buffer_info.style.left_margin = 4
	buffer_info.style.top_padding = -4
	
	local buffer_flow = settings_frame.add{
		type = 'flow',
		direction = 'horizontal'
	}
	buffer_flow.style.vertical_align = 'center'
	buffer_flow.style.bottom_margin = 8
	
	local buffer_slider = buffer_flow.add{
		type = 'slider',
		name = 'buffer_slider',
		minimum_value = 0,
		maximum_value = 100,
		value = 80
	}
	buffer_slider.set_slider_value_step(5)
	buffer_slider.style.horizontally_stretchable = true
	buffer_slider.style.width = 200
	
	local buffer_value = buffer_flow.add{
		type = 'label',
		name = 'buffer_value',
		caption = '80%'
	}
	buffer_value.style.left_margin = 8
	buffer_value.style.width = 40
	
	-- Checkbox for allowing excess items to be used as provider
	local excess_checkbox_flow = settings_frame.add{
		type = 'flow',
		direction = 'horizontal'
	}
	excess_checkbox_flow.style.vertical_align = 'center'
	excess_checkbox_flow.style.top_margin = 8
	
	local excess_checkbox = excess_checkbox_flow.add{
		type = 'checkbox',
		name = 'excess_provider_checkbox',
		caption = {'gui.requester-excess-provider'},
		state = true
	}
	excess_checkbox.tooltip = {'gui.requester-excess-provider-tooltip'}
	
	-- Info sprite with tooltip for excess checkbox
	local excess_info = excess_checkbox_flow.add{
		type = 'sprite',
		name = 'excess_info',
		sprite = 'info',
		tooltip = {'gui.requester-excess-provider-tooltip'}
	}
	excess_info.style.size = 20
	excess_info.style.top_padding = -4
	excess_info.style.left_margin = 4
	
	-- Confirm button to apply settings (at the bottom, right-aligned)
	local confirm_button_flow = settings_frame.add{
		type = 'flow',
		direction = 'horizontal'
	}
	confirm_button_flow.style.horizontal_align = 'right'
	confirm_button_flow.style.horizontally_stretchable = true  -- Allow flow to stretch to fill width
	confirm_button_flow.style.top_margin = 8
	
	local confirm_request_button = confirm_button_flow.add{
		type = 'button',
		name = 'confirm_request_button',
		caption = {'gui.confirm'},
		style = 'confirm_button'
	}
	
	-- Store GUI data
	local gui_data = {
		main_frame = main_frame,
		content_frame = content_frame,
		item_slots = item_slots,
		settings_frame = settings_frame,
		selected_item_sprite = selected_item_sprite,
		selected_item_label = selected_item_label,
		request_amount_slider = request_amount_slider,
		request_amount_textfield = request_amount_textfield,
		buffer_slider = buffer_slider,
		buffer_value = buffer_value,
		confirm_request_button = confirm_request_button,
		excess_checkbox = excess_checkbox,
		selected_slot_index = nil,
		last_opened_requester = nil,
		beacon_indicator = beacon_indicator,
		items_delivered_label = items_delivered_label,
		reconnect_button = reconnect_button
	}
	
	storage.requester_guis[player_index] = gui_data
	return gui_data
end

function gui.update_requester_gui(gui_data, requester_data)
	if not gui_data or not requester_data then return end
	
	-- Update status indicators
	if gui_data.beacon_indicator and gui_data.beacon_indicator.valid then
		local has_beacon = requester_data.beacon_owner ~= nil
		if has_beacon then
			-- Verify beacon still exists and is valid
			local beacon_data = storage.beacons[requester_data.beacon_owner]
			if beacon_data and beacon_data.entity and beacon_data.entity.valid then
				-- Beacon is assigned and valid - show green indicator
				gui_data.beacon_indicator.sprite = 'utility/status_working'
				gui_data.beacon_indicator.tooltip = 'Beacon Assigned'
			else
				-- Beacon was assigned but is now invalid
				has_beacon = false
				requester_data.beacon_owner = nil
			end
		end
		
		if not has_beacon then
			-- No beacon assigned - show red indicator
			gui_data.beacon_indicator.sprite = 'utility/status_not_working'
			gui_data.beacon_indicator.tooltip = 'No Beacon'
		end
	end
	
	-- Update items delivered count
	if gui_data.items_delivered_label and gui_data.items_delivered_label.valid then
		local dropoff_count = requester_data.dropoff_count or 0
		gui_data.items_delivered_label.caption = 'Items Delivered: ' .. tostring(dropoff_count)
	end
	
	-- Migrate old format to new format
	if not requester_data.requested_items then
		requester_data.requested_items = {}
	end
	
	-- Convert old simple format to new structured format
	local needs_migration = false
	for item_name, value in pairs(requester_data.requested_items) do
		if type(value) == "number" then
			needs_migration = true
			break
		end
	end
	
	if needs_migration then
		local new_items = {}
		for item_name, count in pairs(requester_data.requested_items) do
			if type(count) == "number" and count > 0 then
				new_items[item_name] = {
					count = count,
					buffer_threshold = 0.8  -- Default 80%
				}
			end
		end
		requester_data.requested_items = new_items
	end
	
	-- Update item slots (preserve insertion order, no sorting)
	local item_list = {}
	for item_name, data in pairs(requester_data.requested_items) do
		if data.count and data.count > 0 then
			table.insert(item_list, {
				name = item_name, 
				count = data.count,
				buffer = data.buffer_threshold or 0.8,
				allow_excess_provider = data.allow_excess_provider ~= nil and data.allow_excess_provider or true
			})
		end
	end
	-- No sorting - preserve insertion order
	
	-- Show only n+1 slots (where n is number of active requests)
	local num_active_requests = #item_list
	local num_slots_to_show = num_active_requests + 1
	
	-- Update choose-elem-buttons
	-- Check if GUI is still open and valid
	if not gui_data.item_slots then
		return -- GUI has been closed, can't update
	end
	
	for i = 1, 10 do
		-- Check if slot exists and is valid
		if not gui_data.item_slots[i] or not gui_data.item_slots[i].flow or not gui_data.item_slots[i].flow.valid then
			-- GUI element is invalid, skip this slot
			break
		end
		
		-- Show/hide slot based on n+1 rule
		if i <= num_slots_to_show then
			gui_data.item_slots[i].flow.visible = true
			
			if i <= #item_list then
				-- Active request slot - hide chooser, show overlay button
				local item_name = item_list[i].name
				local item_count = item_list[i].count
				if gui_data.item_slots[i].chooser and gui_data.item_slots[i].chooser.valid then
					-- Hide chooser when slot has item (prevents item picker from opening)
					gui_data.item_slots[i].chooser.visible = false
				end
				-- Show overlay button that will handle clicks
				if gui_data.item_slots[i].overlay_button and gui_data.item_slots[i].overlay_button.valid then
					gui_data.item_slots[i].overlay_button.sprite = "item/" .. item_name
					gui_data.item_slots[i].overlay_button.number = item_count  -- Count in bottom-right corner of icon
					-- Use localized name in tooltip
					local item_prototype = prototypes.item[item_name]
					if item_prototype and item_prototype.localised_name then
						-- LocalisedString can't be nested in arrays, so we'll use a locale string
						-- Create a tooltip using the localised_name directly (it's already a LocalisedString)
						-- For now, just show the localised name - the count is already visible on the icon
						gui_data.item_slots[i].overlay_button.tooltip = item_prototype.localised_name
					else
						-- Fallback to string format with count
						gui_data.item_slots[i].overlay_button.tooltip = item_name .. ": " .. tostring(item_count)
					end
					gui_data.item_slots[i].overlay_button.visible = true
				end
				-- Remove top padding from active slots (no negative padding)
				if gui_data.item_slots[i].flow and gui_data.item_slots[i].flow.valid then
					gui_data.item_slots[i].flow.style.top_padding = 0
				end
				gui_data.item_slots[i].item = item_name
				gui_data.item_slots[i].count = item_count
				gui_data.item_slots[i].buffer = item_list[i].buffer or 0.8
				gui_data.item_slots[i].allow_excess_provider = item_list[i].allow_excess_provider ~= nil and item_list[i].allow_excess_provider or true
			else
				-- Empty slot (the +1 slot) - show chooser, hide overlay button
				if gui_data.item_slots[i].chooser and gui_data.item_slots[i].chooser.valid then
					gui_data.item_slots[i].chooser.elem_value = nil  -- Empty slot - no sprite
					gui_data.item_slots[i].chooser.enabled = true  -- Enable chooser for empty slots
					gui_data.item_slots[i].chooser.visible = true  -- Show chooser for empty slots
				end
				-- Hide overlay button
				if gui_data.item_slots[i].overlay_button and gui_data.item_slots[i].overlay_button.valid then
					gui_data.item_slots[i].overlay_button.visible = false
				end
				gui_data.item_slots[i].item = nil
				gui_data.item_slots[i].count = 0
				gui_data.item_slots[i].buffer = 0.8
				gui_data.item_slots[i].allow_excess_provider = true
			end
		else
			-- Hide extra slots
			if gui_data.item_slots[i].flow and gui_data.item_slots[i].flow.valid then
				gui_data.item_slots[i].flow.visible = false
			end
		end
	end
	
	-- Update settings section if a slot is selected
	if gui_data.selected_slot_index then
		gui.update_settings_section(gui_data, gui_data.selected_slot_index)
	end
end

function gui.update_settings_section(gui_data, slot_index)
	if not gui_data or not slot_index then return end
	
	local slot = gui_data.item_slots[slot_index]
	if not slot then return end
	
	if slot.item then
		-- Show settings for this item
		gui_data.settings_frame.visible = true
		gui_data.selected_item_sprite.sprite = "item/" .. slot.item
		gui_data.selected_item_label.caption = prototypes.item[slot.item].localised_name or slot.item
		
		-- Get current request amount
		local request_amount = slot.count or 50
		local stack_size = prototypes.item[slot.item].stack_size or 50
		
		-- Slider has 11 positions: 1 = 1 item, 2 = 1 stack, 3 = 2 stacks, ..., 11 = 10 stacks
		gui_data.request_amount_slider.set_slider_value_step(1)
		-- Map request_amount to slider position (1-11 range)
		local slider_position
		if request_amount == 1 then
			slider_position = 1  -- 1 item
		else
			-- Calculate which stack position: 1 stack = position 2, 2 stacks = position 3, etc.
			local stacks = math.ceil(request_amount / stack_size)
			slider_position = math.max(2, math.min(11, stacks + 1))  -- +1 because position 1 is 1 item
		end
		gui_data.request_amount_slider.slider_value = slider_position
		gui_data.request_amount_textfield.text = tostring(request_amount)
		
		-- Update buffer slider
		local buffer_percent = (slot.buffer or 0.8) * 100
		gui_data.buffer_slider.slider_value = buffer_percent
		gui_data.buffer_value.caption = string.format("%.0f%%", buffer_percent)
		
		-- Update excess provider checkbox
		if gui_data.excess_checkbox then
			gui_data.excess_checkbox.state = slot.allow_excess_provider ~= nil and slot.allow_excess_provider or true
		end
		
		-- Ensure overlay button number is preserved (count in bottom-right corner of icon)
		if slot.overlay_button and slot.overlay_button.valid and slot.count then
			slot.overlay_button.number = slot.count
		end
	else
		-- Hide settings if no item selected
		gui_data.settings_frame.visible = false
	end
end

function gui.close_item_selector_gui(gui_data)
	if gui_data and gui_data.item_selector_gui and gui_data.item_selector_gui.valid then
		gui_data.item_selector_gui.destroy()
		gui_data.item_selector_gui = nil
	end
end

-- Shared toolbar system for spidertron vehicle GUIs
-- Multiple mods can add buttons to the same toolbar
-- First mod to open the GUI creates the toolbar, others add to it

-- Get or create the shared toolbar for spidertron vehicles
-- Removed: get_or_create_shared_toolbar is now in ceelos-vehicle-gui-util

function gui.add_spidertron_toggle_button(player, spider)
	-- Get spider data to determine initial state
	local spider_data = storage.spiders[spider.unit_number]
	local is_active = spider_data and spider_data.active ~= false
	
	-- Get the toolbar from shared utility
	local toolbar = shared_toolbar.get_or_create_shared_toolbar(player, spider)
	if not toolbar then return nil end
	
	-- Navigate through the structure: toolbar -> button_frame -> button_flow
	local button_frame = toolbar["button_frame"]
	if not button_frame or not button_frame.valid then return nil end
	
	local button_flow = button_frame["button_flow"]
	if not button_flow or not button_flow.valid then return nil end
	
	-- Check if buttons already exist
	local toggle_name = MOD_NAME .. "_toggle"
	local dump_name = MOD_NAME .. "_dump"
	local remote_name = MOD_NAME .. "_remote"
	local repath_name = MOD_NAME .. "_repath"
	local existing_toggle = button_flow[toggle_name]
	local existing_dump = button_flow[dump_name]
	local existing_remote = button_flow[remote_name]
	local existing_repath = button_flow[repath_name]
	
	if existing_toggle and existing_toggle.valid and existing_dump and existing_dump.valid then
		existing_toggle.tags = existing_toggle.tags or {}
		existing_toggle.tags.is_active = is_active
		-- Update visual state
		gui.update_toggle_button_color(existing_toggle, is_active)
		-- Always create remote button if it doesn't exist (get new remote each time)
		-- But check again right before creating to avoid duplicates
		local remote_check = button_flow[remote_name]
		if not remote_check or not remote_check.valid then
			local success, remote_button = pcall(function()
				return glib.add(button_flow, {
					args = {
						type = "sprite-button",
						name = remote_name,
						style = "slot_sized_button",
						sprite = "item/spidertron-remote",
						tooltip = {"gui.spidertron-remote-tooltip"}
					},
					ref = "remote"
				}, {})
			end)
			if not success then
				-- Button might have been created by another mod between check and creation
				-- Just continue, the button exists now
			end
		end
		-- Create repath button only if vehicle has autopilot queue
		local repath_check = button_flow[repath_name]
		local has_autopilot_queue = spider.autopilot_destinations and #spider.autopilot_destinations > 0
		if has_autopilot_queue then
			-- Vehicle has autopilot queue - create button if it doesn't exist
			if not repath_check or not repath_check.valid then
				local success, repath_button = pcall(function()
					return glib.add(button_flow, {
						args = {
							type = "sprite-button",
							name = repath_name,
							style = "slot_sized_button",
							sprite = "utility/no_path_icon",
							tooltip = {"gui.spidertron-repath-tooltip"}
						},
						ref = "repath"
					}, {})
				end)
				if not success then
					-- Button might have been created by another mod between check and creation
					-- Just continue, the button exists now
				end
			else
				-- Button exists - make sure it's visible
				repath_check.visible = true
			end
		else
			-- No autopilot queue - hide the button if it exists
			if repath_check and repath_check.valid then
				repath_check.visible = false
			end
		end
		return existing_toggle
	end
	
	-- Create buttons using glib in order: remote, toggle, dump
	local refs = {}
	
	-- Create spidertron remote button (first)
	-- Double-check it doesn't exist (race condition protection)
	local remote_check = button_flow[remote_name]
	if not remote_check or not remote_check.valid then
		local success, remote_button = pcall(function()
			return glib.add(button_flow, {
				args = {
					type = "sprite-button",
					name = remote_name,
					style = "slot_sized_button",
					sprite = "item/spidertron-remote",
					tooltip = {"gui.spidertron-remote-tooltip"}
				},
				ref = "remote"
			}, refs)
		end)
		if success and remote_button then
			refs.remote = remote_button
		end
	end
	
	-- Create toggle button (second) - use tool_button style with size matching slot_sized_button
	-- Tooltip will be set dynamically based on state in update_toggle_button_color
	-- Double-check it doesn't exist (race condition protection)
	local toggle_check = button_flow[toggle_name]
	local toggle
	if not toggle_check or not toggle_check.valid then
		local success, toggle_result = pcall(function()
			return glib.add(button_flow, {
				args = {
					type = "sprite-button",
					name = toggle_name,
					style = "tool_button",
					sprite = "utility/logistic_network_panel_black",
					tooltip = {"gui.spidertron-logistics-inactive"}  -- Default to inactive tooltip
				},
				ref = "toggle",
				style_mods = {
					width = 40,
					height = 40
				}
			}, refs)
		end)
		if success and toggle_result then
			toggle = toggle_result
			refs.toggle = toggle
		else
			-- Button might have been created by another mod, try to get it
			toggle = button_flow[toggle_name]
		end
	else
		toggle = toggle_check
	end
	
	if toggle and toggle.valid then
		toggle.tags = {is_active = is_active}
		-- Set initial visual state (this will also set the correct tooltip)
		gui.update_toggle_button_color(toggle, is_active)
	end
	
	-- Create dump button
	-- Double-check it doesn't exist (race condition protection)
	local dump_check = button_flow[dump_name]
	if not dump_check or not dump_check.valid then
		local success, dump_button = pcall(function()
			return glib.add(button_flow, {
				args = {
					type = "sprite-button",
					name = dump_name,
					style = "slot_sized_button",
					sprite = "utility.trash",
					tooltip = {"gui.spidertron-dump-tooltip"}
				},
				ref = "dump"
			}, refs)
		end)
		if success and dump_button then
			refs.dump = dump_button
		end
	end
	
	-- Create repath button (last) - only if vehicle has autopilot queue
	-- Double-check it doesn't exist (race condition protection)
	local repath_check = button_flow[repath_name]
	local has_autopilot_queue = spider.autopilot_destinations and #spider.autopilot_destinations > 0
	if has_autopilot_queue then
		-- Vehicle has autopilot queue - create button if it doesn't exist
		if not repath_check or not repath_check.valid then
			local success, repath_button = pcall(function()
				return glib.add(button_flow, {
					args = {
						type = "sprite-button",
						name = repath_name,
						style = "slot_sized_button",
						sprite = "utility/no_path_icon",
						tooltip = {"gui.spidertron-repath-tooltip"}
					},
					ref = "repath"
				}, refs)
			end)
			if success and repath_button then
				refs.repath = repath_button
			end
		else
			-- Button exists - make sure it's visible
			repath_check.visible = true
		end
	else
		-- No autopilot queue - hide the button if it exists
		if repath_check and repath_check.valid then
			repath_check.visible = false
		end
	end
	
	return toggle
end

-- Get spidertron remote and put it in player's hand, assigned to the spidertron
function gui.get_spidertron_remote(player, spider)
	if not player or not player.valid then return false end
	if not spider or not spider.valid then return false end
	
	-- Clear cursor if it's not empty
	if not player.is_cursor_empty() then
		player.clear_cursor()
	end
	
	-- Always give a new remote assigned to this spidertron
	local cursor_stack = player.cursor_stack
	if cursor_stack and cursor_stack.valid then
		-- Create a new remote
		cursor_stack.set_stack("spidertron-remote")
		
		-- Assign the remote to this spidertron using player.spidertron_remote_selection
		player.spidertron_remote_selection = {spider}
		
		-- Play sound feedback
		player.play_sound{path = "utility/smart_pipette"}
		
		return true
	end
	
	return false
end

-- Removed: remove_from_shared_toolbar is now in ceelos-vehicle-gui-util

-- Update toggle button state (for when it's clicked)
function gui.update_toggle_button_color(button, is_active)
	if not button or not button.valid then return end
	button.tags = button.tags or {}
	button.tags.is_active = is_active
	button.enabled = true
	
	-- Change button style: green when active, grey when inactive
	if is_active then
		-- Active: use tool_button_green style
		button.style = "tool_button_green"
		button.tooltip = {"gui.spidertron-logistics-active"}
	else
		-- Inactive: use default tool_button style (grey)
		button.style = "tool_button"
		button.tooltip = {"gui.spidertron-logistics-inactive"}
	end
	
	-- Ensure size remains consistent (40x40 to match slot_sized_button)
	button.style.width = 40
	button.style.height = 40
end

-- Create or update player GUI toolbar (in player GUI left) when holding spidertron remote
function gui.add_player_gui_toolbar(player)
	-- Use shared toolbar utility to get or create player GUI toolbar
	-- Buttons are registered via shared_toolbar.register_player_gui_button() in setup
	return shared_toolbar.get_or_create_player_gui_toolbar(player)
end

function gui.close_item_selector_gui(gui_data)
	if gui_data and gui_data.item_selector_gui and gui_data.item_selector_gui.valid then
		gui_data.item_selector_gui.destroy()
		gui_data.item_selector_gui = nil
	end
end

function gui.open_item_selector_gui(player_index, slot_index, gui_data, requester_data)
	local player = game.get_player(player_index)
	if not player or not player.valid then return end
	
	-- Close existing selector if open
	gui.close_item_selector_gui(gui_data)
	
	-- Create modal frame
	local modal_frame = player.gui.screen.add{
		type = 'frame',
		name = 'spidertron_item_selector',
		caption = 'Set request',
		direction = 'vertical'
	}
	modal_frame.style.width = 350
	modal_frame.force_auto_center()
	
	-- Item selection section
	local item_frame = modal_frame.add{
		type = 'frame',
		direction = 'vertical',
		style = 'inside_shallow_frame_with_padding'
	}
	
	local item_header = item_frame.add{
		type = 'label',
		caption = 'Select item:'
	}
	item_header.style.font = 'default-bold'
	item_header.style.bottom_margin = 8
	
	-- Item chooser button - clicking opens native picker while keeping this GUI open
	local item_chooser = item_frame.add{
		type = 'choose-elem-button',
		name = 'spidertron_item_chooser',
		elem_type = 'item'
	}
	item_chooser.style.width = 80
	item_chooser.style.height = 80
	
	-- Quantity section
	local quantity_frame = modal_frame.add{
		type = 'frame',
		direction = 'vertical',
		style = 'inside_shallow_frame_with_padding'
	}
	quantity_frame.style.top_margin = 12
	
	local quantity_header = quantity_frame.add{
		type = 'label',
		caption = 'Set quantity:'
	}
	quantity_header.style.font = 'default-bold'
	
	local quantity_value = quantity_frame.add{
		type = 'label',
		name = 'spidertron_quantity_label',
		caption = '0'
	}
	quantity_value.style.font = 'default-large-bold'
	quantity_value.style.top_margin = 4
	
	local slider = quantity_frame.add{
		type = 'slider',
		name = 'spidertron_quantity_slider',
		minimum_value = 0,
		maximum_value = 1000,
		value = 0
	}
	slider.set_slider_value_step(50)
	slider.style.horizontally_stretchable = true
	slider.style.top_margin = 8
	
	-- Action buttons
	local button_flow = modal_frame.add{
		type = 'flow',
		direction = 'horizontal'
	}
	button_flow.style.horizontal_align = 'center'
	button_flow.style.top_margin = 12
	button_flow.style.bottom_margin = 8
	
	local confirm_button = button_flow.add{
		type = 'button',
		name = 'spidertron_confirm_request',
		caption = 'Confirm',
		style = 'confirm_button'
	}
	
	local cancel_button = button_flow.add{
		type = 'button',
		name = 'spidertron_cancel_request',
		caption = 'Cancel'
	}
	cancel_button.style.left_margin = 8
	
	-- Store GUI references
	gui_data.item_selector_gui = modal_frame
	gui_data.item_selector_slot_index = slot_index
	gui_data.item_selector_quantity_label = quantity_value
	gui_data.item_selector_slider = slider
	gui_data.item_selector_item_chooser = item_chooser
	gui_data.item_selector_selected_item = nil
end

function gui.add_beacon_info_frame(player, beacon, beacon_data)
	-- Always destroy and recreate to ensure fresh data and correct positioning
	if player.gui.screen["spidertron_beacon_info_frame"] then
		player.gui.screen["spidertron_beacon_info_frame"].destroy()
	end
	
	-- Recalculate totals from assigned chests each time (beacon aggregates from its chests)
	-- The beacon doesn't have its own counts - it sums up pickup_count and dropoff_count
	-- from all assigned provider and requester chests
	local total_pickups = 0
	local total_dropoffs = 0
	local chest_count = 0
	
	if beacon_data.assigned_chests then
		-- Count only valid chests (that still exist in storage)
		-- Also clean up invalid entries from the list
		local valid_chest_count = 0
		local valid_chests = {}
		
		for _, chest_unit_number in ipairs(beacon_data.assigned_chests) do
			local provider_data = storage.providers[chest_unit_number]
			local requester_data = storage.requesters[chest_unit_number]
			
			-- Only count if chest data still exists (chest hasn't been destroyed)
			if provider_data then
				valid_chest_count = valid_chest_count + 1
				table.insert(valid_chests, chest_unit_number)
				total_pickups = total_pickups + (provider_data.pickup_count or 0)
				total_dropoffs = total_dropoffs + (provider_data.dropoff_count or 0)
			elseif requester_data then
				valid_chest_count = valid_chest_count + 1
				table.insert(valid_chests, chest_unit_number)
				total_pickups = total_pickups + (requester_data.pickup_count or 0)
				total_dropoffs = total_dropoffs + (requester_data.dropoff_count or 0)
			end
			-- If neither exists, the chest was destroyed - don't add to valid_chests
		end
		
		-- Update the assigned_chests list to remove invalid entries
		if #valid_chests < #beacon_data.assigned_chests then
			beacon_data.assigned_chests = valid_chests
		end
		
		chest_count = valid_chest_count
	end
	
	-- Create a frame as screen GUI (tooltips don't support relative GUI anchoring)
	local frame = player.gui.screen.add{
		type = "frame",
		name = "spidertron_beacon_info_frame",
		style = "slot_button_deep_frame",
		direction = "vertical"
	}
	
	frame.style.width = 200
	frame.style.right_padding = 10
	frame.style.top_padding = 10
	frame.style.bottom_padding = 10
	frame.style.left_padding = 10
	
	-- Title label
	local title = frame.add{
		type = "label",
		caption = "Logistic Network",
		style = "heading_2_label"
	}
	title.style.top_margin = 2
	title.style.bottom_margin = 4
	
	-- Assigned chests count
	local chest_label = frame.add{
		type = "label",
		name = "beacon_chest_count",
		caption = "Assigned Chests: " .. tostring(chest_count)
	}
	chest_label.style.top_margin = 2
	
	-- Total pickups
	local pickup_label = frame.add{
		type = "label",
		name = "beacon_pickup_count",
		caption = "Total Pickups: " .. tostring(total_pickups)
	}
	pickup_label.style.top_margin = 2
	
	-- Total dropoffs
	local dropoff_label = frame.add{
		type = "label",
		name = "beacon_dropoff_count",
		caption = "Total Dropoffs: " .. tostring(total_dropoffs)
	}
	dropoff_label.style.top_margin = 2
	dropoff_label.style.bottom_margin = 2
	
	-- Position using bottom-right corner as reference point (100% - frame size)
	-- Get actual frame size - width is explicitly set to 200
	local screen_resolution = player.display_resolution
	local frame_width = 200  -- Explicitly set width
	
	-- Calculate actual height from content we added:
	-- - Padding: 10px top + 10px bottom = 20px
	-- - Title label with margins: ~24px (20px content + 2px top + 2px bottom)
	-- - 3 data labels with margins: ~66px (3 * 22px each: 20px content + 2px top)
	-- - Bottom margin on last label: 2px
	-- Total: 20 + 24 + 66 + 2 = 112px, round up to 120px for safety
	local frame_height = 120
	
	-- Position top-left corner so that bottom-right of frame is at screen's bottom-right (100%)
	-- Reference point: bottom-right corner of frame at bottom-right of screen
	-- Calculate position: screen_size - frame_size - padding (moves up and left by frame size + padding)
	-- Pad right by frame width and bottom by frame height
	local x_pos = screen_resolution.width - frame_width - frame_width  -- Right edge minus frame width minus padding (frame width)
	local y_pos = screen_resolution.height - frame_height - frame_height  -- Bottom edge minus frame height minus padding (frame height)
	
	frame.location = {x_pos, y_pos}
	
	return frame
end

-- Close requests debug GUI
function gui.close_requests_debug_gui(player)
	if not player or not player.valid then return end
	local screen_gui = player.gui.screen
	if screen_gui then
		local frame = screen_gui["spidertron_requests_debug_frame"]
		if frame and frame.valid then
			frame.destroy()
		end
	end
end

-- Update requests debug GUI with current data
function gui.update_requests_debug_gui(player)
	if not player or not player.valid then return end
	local screen_gui = player.gui.screen
	if not screen_gui then return end
	
	local frame = screen_gui["spidertron_requests_debug_frame"]
	if not frame or not frame.valid then return end
	
	-- Find the scroll pane and table
	local scroll_pane = frame["spidertron_requests_debug_scroll"]
	if not scroll_pane or not scroll_pane.valid then return end
	
	local requests_table = scroll_pane["spidertron_requests_debug_table"]
	if not requests_table or not requests_table.valid then return end
	
	-- Clear existing rows
	requests_table.clear()
	
	-- Get all outstanding requests
	local all_requests = logistics.requesters()
	
	-- Flatten the network-keyed table into a single list
	local requests_list = {}
	for network_key, network_requests in pairs(all_requests) do
		for _, request in ipairs(network_requests) do
			table.insert(requests_list, request)
		end
	end
	
	-- Sort by item name for easier reading
	table.sort(requests_list, function(a, b)
		return a.requested_item < b.requested_item
	end)
	
	-- Populate table
	for _, request in ipairs(requests_list) do
		if request.entity and request.entity.valid then
			-- Get localised item name
			local item_name = request.requested_item
			local item_prototype = prototypes.item[item_name]
			local localised_name = item_name
			if item_prototype and item_prototype.localised_name then
				localised_name = item_prototype.localised_name
			end
			
			-- Format location
			local pos = request.entity.position
			local location_str = string.format("%.0f, %.0f", pos.x, pos.y)
			
			-- Add row
			local item_label = requests_table.add{type = "label", caption = localised_name}
			item_label.style.minimal_width = 200
			
			local requested_label = requests_table.add{type = "label", caption = tostring(request.request_size)}
			requested_label.style.minimal_width = 80
			requested_label.style.horizontal_align = "right"
			
			local current_label = requests_table.add{type = "label", caption = tostring(request.already_had)}
			current_label.style.minimal_width = 80
			current_label.style.horizontal_align = "right"
			
			local incoming_label = requests_table.add{type = "label", caption = tostring(request.incoming)}
			incoming_label.style.minimal_width = 80
			incoming_label.style.horizontal_align = "right"
			
			local location_label = requests_table.add{type = "label", caption = location_str}
			location_label.style.minimal_width = 100
		end
	end
	
	-- Update count label if it exists
	local count_label = frame["spidertron_requests_debug_count"]
	if count_label and count_label.valid then
		count_label.caption = "Total: " .. #requests_list .. " outstanding request" .. (#requests_list ~= 1 and "s" or "")
	end
end

-- Open requests debug GUI
function gui.open_requests_debug_gui(player)
	if not player or not player.valid then return end
	
	-- Close existing GUI if open
	gui.close_requests_debug_gui(player)
	
	local screen_gui = player.gui.screen
	if not screen_gui then return end
	
	-- Create modal frame
	local frame = screen_gui.add{
		type = "frame",
		name = "spidertron_requests_debug_frame",
		caption = "Outstanding Logistic Requests",
		direction = "vertical"
	}
	frame.style.width = 800
	frame.style.height = 600
	frame.force_auto_center()
	
	-- Title and count
	local title_flow = frame.add{
		type = "flow",
		direction = "horizontal"
	}
	title_flow.style.horizontal_spacing = 8
	title_flow.style.bottom_margin = 8
	
	local count_label = title_flow.add{
		type = "label",
		name = "spidertron_requests_debug_count",
		caption = "Total: 0 outstanding requests"
	}
	count_label.style.font = "default-semibold"
	
	local pusher = title_flow.add{
		type = "empty-widget"
	}
	pusher.style.horizontally_stretchable = true
	
	-- Scroll pane for table
	local scroll_pane = frame.add{
		type = "scroll-pane",
		name = "spidertron_requests_debug_scroll"
	}
	scroll_pane.style.width = 780
	scroll_pane.style.height = 500
	scroll_pane.style.vertically_stretchable = true
	
	-- Create table with headers
	local requests_table = scroll_pane.add{
		type = "table",
		name = "spidertron_requests_debug_table",
		column_count = 5
	}
	requests_table.style.horizontal_spacing = 8
	requests_table.style.vertical_spacing = 4
	
	-- Add header row
	local header_item = requests_table.add{type = "label", caption = "Item"}
	header_item.style.font = "default-semibold"
	header_item.style.minimal_width = 200
	
	local header_requested = requests_table.add{type = "label", caption = "Requested"}
	header_requested.style.font = "default-semibold"
	header_requested.style.minimal_width = 80
	header_requested.style.horizontal_align = "right"
	
	local header_current = requests_table.add{type = "label", caption = "Current"}
	header_current.style.font = "default-semibold"
	header_current.style.minimal_width = 80
	header_current.style.horizontal_align = "right"
	
	local header_incoming = requests_table.add{type = "label", caption = "Incoming"}
	header_incoming.style.font = "default-semibold"
	header_incoming.style.minimal_width = 80
	header_incoming.style.horizontal_align = "right"
	
	local header_location = requests_table.add{type = "label", caption = "Location"}
	header_location.style.font = "default-semibold"
	header_location.style.minimal_width = 100
	
	-- Button flow
	local button_flow = frame.add{
		type = "flow",
		direction = "horizontal"
	}
	button_flow.style.horizontal_align = "right"
	button_flow.style.top_margin = 8
	button_flow.style.horizontal_spacing = 8
	
	local refresh_button = button_flow.add{
		type = "button",
		name = "spidertron_requests_debug_refresh",
		caption = "Refresh"
	}
	refresh_button.style = "confirm_button"
	
	local close_button = button_flow.add{
		type = "button",
		name = "spidertron_requests_debug_close",
		caption = "Close"
	}
	
	-- Populate with data
	gui.update_requests_debug_gui(player)
end

return gui

