-- Blueprint event handlers for spidertron logistics

local constants = require('lib.constants')
local registration = require('lib.registration')

local events_blueprint = {}

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

function events_blueprint.register()
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
end

return events_blueprint

