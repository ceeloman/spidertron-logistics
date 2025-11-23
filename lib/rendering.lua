-- Rendering functions for icons and visual feedback

local constants = require('lib.constants')

-- Store reference to global rendering API before creating local module
local global_rendering = rendering

local rendering = {}

-- Use global rendering API from Factorio
local draw_sprite = global_rendering.draw_sprite
local draw_line = global_rendering.draw_line

function rendering.draw_no_energy_icon(target, offset)
	draw_sprite{
		sprite = 'utility.electricity_icon',
		x_scale = 0.5,
		y_scale = 0.5,
		target = target,
		surface = target.surface,
		time_to_live = constants.update_cooldown / 2,
		target_offset = offset
	}
end

function rendering.draw_missing_roboport_icon(target, offset)
	draw_sprite{
		sprite = 'utility.too_far_from_roboport_icon',
		x_scale = 0.5,
		y_scale = 0.5,
		target = target,
		surface = target.surface,
		time_to_live = constants.update_cooldown / 2,
		target_offset = offset
	}
end

function rendering.draw_deposit_icon(target)
	local requester_data = storage.requesters[target.unit_number]
	local old = requester_data.old_icon
	if old and old.valid then old.destroy() end
	
	requester_data.old_icon = draw_sprite{
		sprite = 'utility.indication_arrow',
		x_scale = 1.5,
		y_scale = 1.5,
		target = target,
		surface = target.surface,
		time_to_live = 120,
		target_offset = {0, -0.75},
		orientation = 0.5,
		only_in_alt_mode = true
	}
end

function rendering.draw_withdraw_icon(target)
	local provider_data = storage.providers[target.unit_number]
	
	-- For robot chests, provider_data will be nil, so we'll use a simple icon without tracking
	if provider_data then
		local old = provider_data.old_icon
		if old and old.valid then old.destroy() end
		
		provider_data.old_icon = draw_sprite{
			sprite = 'utility.indication_arrow',
			x_scale = 1.5,
			y_scale = 1.5,
			target = target,
			surface = target.surface,
			time_to_live = 120,
			target_offset = {0, -0.75},
			only_in_alt_mode = true
		}
	else
		-- For robot chests, just draw the icon without tracking
		draw_sprite{
			sprite = 'utility.indication_arrow',
			x_scale = 1.5,
			y_scale = 1.5,
			target = target,
			surface = target.surface,
			time_to_live = 120,
			target_offset = {0, -0.75},
			only_in_alt_mode = true
		}
	end
end

-- Draw connection lines between entities
function rendering.draw_connection_lines(entity)
	if not entity or not entity.valid then return {} end
	
	local lines = {}
	
	-- If it's a chest, draw line to its beacon
	if entity.name == constants.spidertron_requester_chest then
		local requester_data = storage.requesters[entity.unit_number]
		if requester_data and requester_data.beacon_owner then
			local beacon_data = storage.beacons[requester_data.beacon_owner]
			if beacon_data and beacon_data.entity and beacon_data.entity.valid then
				table.insert(lines, {
					from = entity.position,
					to = beacon_data.entity.position,
					color = {r = 0.2, g = 0.8, b = 0.2, a = 0.6}  -- Green for requester
				})
			end
		end
	elseif entity.name == constants.spidertron_provider_chest then
		local provider_data = storage.providers[entity.unit_number]
		if provider_data and provider_data.beacon_owner then
			local beacon_data = storage.beacons[provider_data.beacon_owner]
			if beacon_data and beacon_data.entity and beacon_data.entity.valid then
				table.insert(lines, {
					from = entity.position,
					to = beacon_data.entity.position,
					color = {r = 0.8, g = 0.2, b = 0.2, a = 0.6}  -- Red for provider
				})
			end
		end
	elseif entity.name == constants.spidertron_logistic_beacon then
		-- If it's a beacon, draw lines to all its assigned chests
		local beacon_data = storage.beacons[entity.unit_number]
		if beacon_data and beacon_data.assigned_chests then
			for _, chest_unit_number in ipairs(beacon_data.assigned_chests) do
				local chest = nil
				local color = {r = 0.5, g = 0.5, b = 0.5, a = 0.6}  -- Gray default
				
				if storage.providers[chest_unit_number] then
					chest = storage.providers[chest_unit_number].entity
					color = {r = 0.8, g = 0.2, b = 0.2, a = 0.6}  -- Red for provider
				elseif storage.requesters[chest_unit_number] then
					chest = storage.requesters[chest_unit_number].entity
					color = {r = 0.2, g = 0.8, b = 0.2, a = 0.6}  -- Green for requester
				end
				
				if chest and chest.valid then
					table.insert(lines, {
						from = entity.position,
						to = chest.position,
						color = color
					})
				end
			end
		end
	end
	
	-- Draw all lines
	for _, line_data in ipairs(lines) do
		draw_line{
			surface = entity.surface,
			from = line_data.from,
			to = line_data.to,
			color = line_data.color,
			width = 2,
			time_to_live = 30,  -- Update every 30 ticks (0.5 seconds)
			draw_on_ground = true
		}
	end
	
	return lines
end

-- Draw flashing warning icon above spider when it can't dump items
-- This should be called every tick to create a flashing effect
function rendering.draw_dump_failed_icon(spider, spider_data)
	if not spider or not spider.valid then return end
	if not spider_data then return end
	
	-- Only draw if spider is in dumping_items status and has no dump_target
	if spider_data.status ~= constants.dumping_items or spider_data.dump_target then return end
	
	-- Check if spider still has items
	local trunk = spider.get_inventory(defines.inventory.spider_trunk)
	if not trunk then return end
	local contents = trunk.get_contents()
	if not contents or next(contents) == nil then return end
	
	-- Create flashing effect by toggling based on game tick
	local tick = game.tick
	local flash_rate = 30  -- Flash every 30 ticks (0.5 seconds)
	local should_show = (tick % (flash_rate * 2)) < flash_rate
	
	if should_show then
		-- Draw warning icon
		draw_sprite{
			sprite = 'utility.warning_icon',
			x_scale = 1.0,
			y_scale = 1.0,
			target = spider,
			surface = spider.surface,
			time_to_live = flash_rate + 1,  -- Slightly longer than flash rate
			target_offset = {0, -2.0}  -- Above spider's head
		}
	end
end

return rendering

