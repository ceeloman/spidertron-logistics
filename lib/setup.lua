-- Setup and initialization functions for spidertron logistics

local constants = require('lib.constants')
local beacon_assignment = require('lib.beacon_assignment')
local gui = require('lib.gui')
local registration = require('lib.registration')
local logistics = require('lib.logistics')
local logging = require('lib.logging')
local debug_commands = require('lib.commands')
local shared_toolbar = require("__ceelos-vehicle-gui-util__/lib/shared_toolbar")

local setup_module = {}

local function cleanup_invalid_requested_items()
	local cleaned_count = 0
	local items_removed = 0
	
	for unit_number, requester_data in pairs(storage.requesters) do
		if not requester_data.entity or not requester_data.entity.valid then
			goto next_requester
		end
		
		if not requester_data.requested_items then
			goto next_requester
		end
		
		local had_invalid_items = false
		local items_to_remove = {}
		
		-- Check each requested item to see if it still exists
		-- Only check if game.item_prototypes is available (may not be during early configuration changes)
		local can_check_prototypes = false
		if game then
			local success, _ = pcall(function() return game.item_prototypes end)
			can_check_prototypes = success
		end
		
		for item_name, item_data in pairs(requester_data.requested_items) do
			-- Check if item prototype still exists
			if not item_name or item_name == '' then
				items_to_remove[item_name] = true
				had_invalid_items = true
			elseif can_check_prototypes then
				local item_prototype = game.item_prototypes[item_name]
				if not item_prototype then
					-- Item no longer exists (mod was removed)
					items_to_remove[item_name] = true
					had_invalid_items = true
					items_removed = items_removed + 1
				end
			end
			-- If can_check_prototypes is false, skip validation (prototypes not loaded yet)
		end
		
		-- Remove invalid items
		if had_invalid_items then
			for item_name, _ in pairs(items_to_remove) do
				requester_data.requested_items[item_name] = nil
				-- Also clear from incoming_items if present
				if requester_data.incoming_items then
					requester_data.incoming_items[item_name] = nil
				end
			end
			
			-- Update entity tags if entity is valid
			if requester_data.entity and requester_data.entity.valid then
				registration.update_requester_entity_tags(requester_data.entity, requester_data.requested_items)
			end
			
			cleaned_count = cleaned_count + 1
		end
		
		::next_requester::
	end
	
	if cleaned_count > 0 then
		logging.info("Cleanup", "Cleaned up invalid items from " .. cleaned_count .. " requester chest(s), removed " .. items_removed .. " invalid item(s)")
	end
end

function setup_module.setup()
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
	-- TODO: Robot chest cache initialization kept for save compatibility
	-- Future implementation should use chunk-based scanning instead of full cache
	storage.robot_chest_cache = storage.robot_chest_cache or {}
	
	-- Clean up invalid items from requester chests (items from removed mods)
	cleanup_invalid_requested_items()
	
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
	
	-- TODO: Robot chest scan on load removed
	-- Previously scanned all surfaces for existing robot chests and cached them
	-- Future implementation should use chunk-based periodic scanning instead
	
	-- Register all commands
	debug_commands.register_all()
	
	-- Register player GUI toolbar buttons with shared toolbar utility
	-- These buttons appear in the player GUI (left panel) when holding a spidertron remote
	-- Use remote interface to ensure registrations are stored in ceelos-vehicle-gui-util's storage
	if remote.interfaces["ceelos-vehicle-gui-util"] then
		remote.call("ceelos-vehicle-gui-util", "register_player_gui_button", "spidertron-logistics", "remote", {
			sprite = "item/spidertron-remote",
			tooltip = {"gui.spidertron-remote-tooltip"},
			vehicle_types = {"spider-vehicle"},
			priority = 1,
			style = "slot_sized_button"
		})
		
		-- Note: Functions can't be serialized, so we register toggle button with condition/tags functions via direct call
		-- The remote interface will handle storage, but functions need to be registered separately
		if shared_toolbar then
			shared_toolbar.register_player_gui_button("spidertron-logistics", "toggle", {
				sprite = "utility/logistic_network_panel_black",
				tooltip = {"gui.spidertron-logistics-inactive"},
				vehicle_types = {"spider-vehicle"},
				priority = 2,
				style = "tool_button",
				update_tags = function(player, selected_vehicles, button)
					-- Check if any spider has logistics active
					local any_active = false
					for _, vehicle in ipairs(selected_vehicles) do
						if vehicle and vehicle.valid and vehicle.type == "spider-vehicle" then
							local spider_data = storage.spiders[vehicle.unit_number]
							if spider_data and spider_data.active ~= false then
								any_active = true
								break
							end
						end
					end
					button.tags = {is_active = any_active}
					gui.update_toggle_button_color(button, any_active)
				end
			})
		end
		
		remote.call("ceelos-vehicle-gui-util", "register_player_gui_button", "spidertron-logistics", "dump", {
			sprite = "utility.trash",
			tooltip = {"gui.spidertron-dump-tooltip"},
			vehicle_types = {"spider-vehicle"},
			priority = 3,
			style = "slot_sized_button"
		})
		
		-- Repath button has condition function - register via direct call
		-- Note: Functions can't be serialized, so this will be stored in ceelos-vehicle-gui-util's storage
		-- but the function won't persist across saves (will need to re-register on load)
		if shared_toolbar then
			shared_toolbar.register_player_gui_button("spidertron-logistics", "repath", {
				sprite = "utility/no_path_icon",
				tooltip = {"gui.spidertron-repath-tooltip"},
				vehicle_types = {"spider-vehicle"},
				priority = 4,
				style = "slot_sized_button",
				condition = function(player, selected_vehicles)
					-- Only show if any spider has autopilot queue
					for _, vehicle in ipairs(selected_vehicles) do
						if vehicle and vehicle.valid and vehicle.type == "spider-vehicle" then
							if vehicle.autopilot_destinations and #vehicle.autopilot_destinations > 0 then
								return true
							end
						end
					end
					return false
				end
			})
		end
	end
end

return setup_module

