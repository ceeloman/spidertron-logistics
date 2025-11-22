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
		
		local gui_data = gui.requester_gui(event.player_index)
		gui_data.last_opened_requester = requester_data
		gui.update_requester_gui(gui_data, requester_data)
		return
	end
	
	-- Handle spidertron GUI
	if entity.type == 'spider-vehicle' and entity.prototype.order ~= 'z[programmable]' then
		local player = game.get_player(event.player_index)
		if not player then return end
		
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
		for _, gui_data in pairs(storage.requester_guis) do
			if gui_data and gui_data.item_selector_item_chooser and gui_data.item_selector_item_chooser == element then
				gui_data.item_selector_selected_item = element.elem_value
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

-- Main logistics update loop
script.on_nth_tick(constants.update_cooldown, function(event)
	local requests = logistics.requesters()
	local spiders_list = logistics.spiders()
	local providers_list = logistics.providers()
	
	for network_key, requesters in pairs(requests) do
		local providers_for_network = providers_list[network_key]
		if not providers_for_network then 
			goto next_network 
		end
		
		local spiders_on_network = spiders_list[network_key]
		if not spiders_on_network or #spiders_on_network == 0 then 
			goto next_network 
		end
		
		for _, item_request in ipairs(requesters) do
			local item = item_request.requested_item
			local requester_data = item_request.requester_data
			if not item then goto next_requester end
			
			local max = 0
			local best_provider
			for _, provider_data in ipairs(providers_for_network) do
				local provider = provider_data.entity
				if not provider or not provider.valid then goto next_provider end
				
				local item_count = 0
				local allocated = 0
				
				if provider_data.is_robot_chest then
					-- For robot chests, check if item is available in the chest
					-- We don't track allocated_items for robot chests (robots handle that)
					item_count = provider.get_inventory(defines.inventory.chest).get_item_count(item)
					allocated = 0  -- Robot chests don't use allocation tracking
				else
					-- Custom provider chest logic (existing)
					item_count = provider.get_inventory(defines.inventory.chest).get_item_count(item)
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
				local assigned = logistics.assign_spider(spiders_on_network, temp_requester, best_provider, max)
				if not assigned then
					goto next_requester
				end
				if #spiders_on_network == 0 then
					goto next_network
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
	if spider_data == nil or spider_data.status == constants.idle then
		return
	elseif spider_data.status == constants.picking_up then
		if not spider_data.requester_target.valid then
			journey.end_journey(unit_number, true)
			return
		end
		goal = spider_data.provider_target
	elseif spider_data.status == constants.dropping_off then
		goal = spider_data.requester_target
	end
	
	if not goal or not goal.valid or goal.to_be_deconstructed() or spider.surface ~= goal.surface or utils.distance(spider.position, goal.position) > 6 then
		journey.end_journey(unit_number, true)
		return
	end
	
	local item = spider_data.payload_item
	local item_count = spider_data.payload_item_count
	local requester = spider_data.requester_target
	local requester_data = storage.requesters[requester.unit_number]
	
	if spider_data.status == constants.picking_up then
		local provider = spider_data.provider_target
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
		
		local contains = provider.get_item_count(item)
		if contains > item_count then contains = item_count end
		local already_had = spider.get_item_count(item)
		if already_had > item_count then already_had = item_count end
		
		if contains + already_had == 0 then
			journey.end_journey(unit_number, true)
			return
		end
		
		local can_insert = min(contains - already_had, item_count)
		local actually_inserted = can_insert <= 0 and 0 or spider.insert{name = item, count = can_insert}
		if actually_inserted + already_had == 0 then
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
		spider_data.payload_item_count = actually_inserted + already_had
		requester_data.incoming_items[item] = requester_data.incoming_items[item] - item_count + actually_inserted + already_had
		
		spider.add_autopilot_destination(spider_data.requester_target.position)
		
		-- Only update allocated_items for custom provider chests
		if not is_robot_chest and provider_data then
			local allocated_items = provider_data.allocated_items
			allocated_items[item] = allocated_items[item] - item_count
			if allocated_items[item] == 0 then allocated_items[item] = nil end
		end
		
		spider_data.status = constants.dropping_off
	elseif spider_data.status == constants.dropping_off then
		local can_insert = min(spider.get_item_count(item), item_count)
		local actually_inserted = can_insert <= 0 and 0 or requester.insert{name = item, count = can_insert}
			   
		if actually_inserted ~= 0 then
			spider.remove_item{name = item, count = actually_inserted}
			requester_data.dropoff_count = (requester_data.dropoff_count or 0) + actually_inserted
			rendering.draw_deposit_icon(requester)
		end
		
		journey.end_journey(unit_number, true)
		journey.deposit_already_had(spider_data)
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
			for _, chest_unit_number in ipairs(beacon_data.assigned_chests) do
				local chest = nil
				if storage.providers[chest_unit_number] then
					chest = storage.providers[chest_unit_number].entity
				elseif storage.requesters[chest_unit_number] then
					chest = storage.requesters[chest_unit_number].entity
				end
				if chest and chest.valid then
					beacon_assignment.assign_chest_to_nearest_beacon(chest)
				end
			end
		end
		storage.beacons[unit_number] = nil
	end
end)

local function built(event)
	local entity = event.created_entity or event.entity

	if entity.type == 'spider-vehicle' and entity.prototype.order ~= 'z[programmable]' then
		registration.register_spider(entity)
	elseif entity.name == constants.spidertron_requester_chest then
		registration.register_requester(entity, event.tags)
	elseif entity.name == constants.spidertron_provider_chest then
		registration.register_provider(entity)
	elseif entity.name == constants.spidertron_logistic_beacon then
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
				blueprint.set_blueprint_entity_tag(i, 'requested_item', requester_data.requested_item)
				blueprint.set_blueprint_entity_tag(i, 'request_size', requester_data.request_size)
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

script.on_init(setup)
script.on_configuration_changed(setup)
