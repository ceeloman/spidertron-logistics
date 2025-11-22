-- GUI handling for requester chests and spidertron toggle

local constants = require('lib.constants')
local registration = require('lib.registration')

local gui = {}

function gui.cleanup_old_guis(player_index)
	local player = game.get_player(player_index)
	if not player or not player.valid then return end
	
	-- Clean up old GUI structures that might exist
	local relative_gui = player.gui.relative
	if not relative_gui then return end
	
	-- Remove old frame-based GUI (if it exists)
	local old_frame = relative_gui[constants.spidertron_requester_chest]
	if old_frame and old_frame.valid then
		-- Check if it's the old structure (has frame property, not vertical_flow)
		if old_frame.type == 'frame' and old_frame.name == constants.spidertron_requester_chest then
			-- Check if it has old structure (no vertical_flow child)
			local has_vertical_flow = false
			for _, child in ipairs(old_frame.children) do
				if child.type == 'flow' and child.direction == 'vertical' then
					has_vertical_flow = true
					break
				end
			end
			-- If it's the old structure, destroy it
			if not has_vertical_flow then
				old_frame.destroy()
			end
		end
	end
	
	-- Also check for any orphaned GUI elements
	-- Remove any frames with old names or structures
	for _, child in ipairs(relative_gui.children) do
		if child.valid and child.name == constants.spidertron_requester_chest then
			-- Check if it's an old structure
			if child.type == 'frame' then
				local has_new_structure = false
				for _, subchild in ipairs(child.children) do
					if subchild.type == 'frame' and subchild.caption == 'Logistic Requests' then
						has_new_structure = true
						break
					end
				end
				if not has_new_structure then
					child.destroy()
				end
			end
		end
	end
end

function gui.requester_gui(player_index)
	local gui_data = storage.requester_guis[player_index]
	-- If GUI exists and is valid, return it
	if gui_data and gui_data.vertical_flow and gui_data.vertical_flow.valid then
		return gui_data
	end
	
	-- Clean up any old GUIs first
	gui.cleanup_old_guis(player_index)
	
	-- Destroy old GUI if it exists but is invalid
	if gui_data and gui_data.vertical_flow and not gui_data.vertical_flow.valid then
		gui_data = nil
	end
	
	local player = game.get_player(player_index)
	
	-- Create vertical flow
	local vertical_flow = player.gui.relative.add{
		type = 'flow',
		direction = 'vertical',
		anchor = {
			gui = defines.relative_gui_type.container_gui,
			position = defines.relative_gui_position.right,
			name = constants.spidertron_requester_chest
		}
	}
	
	-- Item logistic GUI (about 400 wide) - replicating ItemAndDoubleCountSelectGui structure
	local item_logistic_gui = vertical_flow.add{
		type = 'frame',
		direction = 'vertical',
		caption = 'Logistic Requests'
	}
	item_logistic_gui.style.minimal_width = 400
	
	-- Create 10 item slots in a horizontal row
	local slots_flow = item_logistic_gui.add{
		type = 'flow',
		direction = 'horizontal'
	}
	
	local buttons = {}
	for i = 1, 10 do
		-- Each slot is a sprite button that shows the item and quantity
		local slot_button = slots_flow.add{
			type = 'sprite-button',
			style = 'slot_button'
		}
		slot_button.style.size = 40
		
		table.insert(buttons, {
			slot_button = slot_button,
			item_name = nil,
			count = 0
		})
	end
	
	gui_data = {
		vertical_flow = vertical_flow,
		item_logistic_gui = item_logistic_gui,
		slots_flow = slots_flow,
		buttons = buttons,
		last_opened_requester = nil,
		item_selector_gui = nil  -- Modal GUI for item selection
	}
	
	storage.requester_guis[player_index] = gui_data
	return gui_data
end

function gui.add_spidertron_toggle_button(player, spider)
	-- Check if the button already exists to avoid duplicates
	if player.gui.relative["spidertron_logistics_toggle_frame"] then
		player.gui.relative["spidertron_logistics_toggle_frame"].destroy()
	end
	
	-- Create a frame to contain our button
	local frame = player.gui.relative.add{
		type = "frame",
		name = "spidertron_logistics_toggle_frame",
		style = "slot_button_deep_frame",
		anchor = {
			gui = defines.relative_gui_type.spider_vehicle_gui,
			position = defines.relative_gui_position.right
		}
	}
	
	frame.style.padding = 2
	frame.style.top_margin = 5
	frame.style.left_margin = 5
	
	-- Create the toggle switch inside the frame
	local spider_data = storage.spiders[spider.unit_number]
	local is_active = spider_data and spider_data.active ~= false
	
	local toggle = frame.add{
		type = "switch",
		name = "spidertron_logistics_toggle_button",
		switch_state = is_active and "left" or "right",
		left_label_caption = {'gui.spidertron-active'},
		right_label_caption = {'gui.spidertron-inactive'},
		tooltip = {'gui.spidertron-logistics-toggle'}
	}
	
	return toggle
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
		value = 0,
		value_step = 50
	}
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

function gui.update_requester_gui(gui_data, requester_data)
	if not gui_data or not requester_data then return end
	
	-- Ensure requested_items exists
	if not requester_data.requested_items then
		requester_data.requested_items = {}
		-- Migrate old format if needed
		if requester_data.requested_item then
			requester_data.requested_items[requester_data.requested_item] = requester_data.request_size or 0
			requester_data.requested_item = nil
			requester_data.request_size = nil
		end
	end
	
	-- Update buttons with requested items
	local item_list = {}
	for item_name, count in pairs(requester_data.requested_items) do
		if count > 0 and item_name and item_name ~= '' then
			table.insert(item_list, {name = item_name, count = count})
		end
	end
	
	-- Sort items for consistent display
	table.sort(item_list, function(a, b) return a.name < b.name end)
	
	-- Update slot buttons (up to 10)
	for i = 1, 10 do
		if gui_data.buttons[i] and gui_data.buttons[i].slot_button and gui_data.buttons[i].slot_button.valid then
			if i <= #item_list then
				local item_name = item_list[i].name
				local count = item_list[i].count
				gui_data.buttons[i].slot_button.sprite = 'item/' .. item_name
				gui_data.buttons[i].slot_button.number = count
				gui_data.buttons[i].slot_button.tooltip = item_name .. ': ' .. tostring(count)
				gui_data.buttons[i].item_name = item_name
				gui_data.buttons[i].count = count
			else
				gui_data.buttons[i].slot_button.sprite = nil
				gui_data.buttons[i].slot_button.number = nil
				gui_data.buttons[i].slot_button.tooltip = 'Click to set request'
				gui_data.buttons[i].item_name = nil
				gui_data.buttons[i].count = 0
			end
		end
	end
end

return gui

