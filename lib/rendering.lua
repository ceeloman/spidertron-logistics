-- Rendering functions for icons and visual feedback

local constants = require('lib.constants')

-- Store reference to global rendering API before creating local module
local global_rendering = rendering

local rendering = {}

-- Use global rendering API from Factorio
local draw_sprite = global_rendering.draw_sprite

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

return rendering

