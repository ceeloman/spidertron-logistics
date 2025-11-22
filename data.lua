local circuit_connections = require 'circuit-connections'

local nothing = {
	filename = '__spidertron-logistics__/graphics/nothing.png',
	priority = 'extra-high',
	size = 1
}

data:extend{
	{
		type = 'item',
		name = 'spidertron-requester-chest',
		icon = '__spidertron-logistics__/graphics/icon/spidertron-requester-chest.png',
		icon_size = 64,
		stack_size = 50,
		place_result = 'spidertron-requester-chest',
		order = 'b[personal-transport]-c[spidertron]-d[depot]',
		subgroup = 'transport',
	},
	{
		type = 'item',
		name = 'spidertron-provider-chest',
		icon = '__spidertron-logistics__/graphics/icon/spidertron-provider-chest.png',
		icon_size = 64,
		stack_size = 50,
		place_result = 'spidertron-provider-chest',
		order = 'b[personal-transport]-c[spidertron]-d[depot]',
		subgroup = 'transport',
	},
	{
		type = 'item',
		name = 'spidertron-logistic-controller',
		icon = '__spidertron-logistics__/graphics/icon/spidertron-logistic-controller.png',
		icon_size = 64,
		icon_mipmaps = 4,
		stack_size = 10,
		place_as_equipment_result = 'spidertron-logistic-controller',
		order = 'b[personal-transport]-c[spidertron]-c[controller]',
		subgroup = 'transport',
	},
	{
		type = 'item',
		name = 'spidertron-logistic-beacon',
		icon = '__spidertron-logistics__/graphics/new/graphics/radar.png',
		icon_size = 64,
		icon_mipmaps = 4,
		stack_size = 50,
		place_result = 'spidertron-logistic-beacon',
		order = 'b[personal-transport]-c[spidertron]-c[beacon]',
		subgroup = 'transport',
	},
	{
		type = 'equipment-category',
		name = 'spidertron-logistic-controller',
	},
	{
		type = 'container',
		name = 'spidertron-provider-chest',
		icon = '__spidertron-logistics__/graphics/icon/spidertron-provider-chest.png',
		icon_size = 64,
		inventory_size = 50,
		picture = {layers = {
			{
				filename = '__spidertron-logistics__/graphics/entity/spidertron-provider-chest.png',
				priority = 'extra-high',
				width = 104,
				height = 100,
				scale = 0.6,
				hr_version = {
					filename = '__spidertron-logistics__/graphics/entity/hr-spidertron-provider-chest.png',
					width = 207,
					height = 199,
					priority = 'high',
					scale = 0.3,
				},
			},
			{
				draw_as_shadow = true,
				filename = '__spidertron-logistics__/graphics/entity/shadow.png',
				width = 138,
				height = 75,
				scale = 0.6,
				hr_version = {
					draw_as_shadow = true,
					filename = '__spidertron-logistics__/graphics/entity/hr-shadow.png',
					width = 277,
					height = 149,
					priority = 'high',
					scale = 0.3,
					shift = {0.5625, 0.5},
				},
				priority = 'high',
				shift = {0.3125, 0.375},
			},
		}},
		circuit_connector_sprites = circuit_connections.circuit_connector_sprites,
		circuit_wire_connection_point = circuit_connections.circuit_wire_connection_point,
		circuit_wire_max_distance = circuit_connections.circuit_wire_max_distance,
		max_health = 600,
		minable = {mining_time = 1, result = 'spidertron-provider-chest'},
		corpse = 'artillery-turret-remnants',
		fast_replaceable_group = 'spidertron-container',
		close_sound = {
			filename = '__base__/sound/metallic-chest-close.ogg',
			volume = 0.6
		},
		open_sound = {
			filename = '__base__/sound/metallic-chest-open.ogg',
			volume = 0.6
		},
		collision_box = {{-0.7, -0.7}, {0.7, 0.7}},
		selection_box = {{-1, -1}, {1, 1}},
		flags = {'placeable-neutral', 'player-creation'},
		se_allow_in_space = true
	},
	{
		type = 'container',
		icon = '__spidertron-logistics__/graphics/icon/spidertron-requester-chest.png',
		icon_size = 64,
		name = 'spidertron-requester-chest',
		inventory_size = 50,
		picture = {layers = {
			{
				filename = '__spidertron-logistics__/graphics/entity/spidertron-requester-chest.png',
				priority = 'extra-high',
				width = 104,
				height = 100,
				scale = 0.6,
				hr_version = {
					filename = '__spidertron-logistics__/graphics/entity/hr-spidertron-requester-chest.png',
					width = 207,
					height = 199,
					priority = 'high',
					scale = 0.3,
				},
			},
			{
				draw_as_shadow = true,
				filename = '__spidertron-logistics__/graphics/entity/shadow.png',
				width = 138,
				height = 75,
				scale = 0.6,
				hr_version = {
					draw_as_shadow = true,
					filename = '__spidertron-logistics__/graphics/entity/hr-shadow.png',
					width = 277,
					height = 149,
					priority = 'high',
					scale = 0.3,
					shift = {0.5625, 0.5},
				},
				priority = 'high',
				shift = {0.3125, 0.375},
			},
		}},
		circuit_connector_sprites = circuit_connections.circuit_connector_sprites,
		circuit_wire_connection_point = circuit_connections.circuit_wire_connection_point,
		circuit_wire_max_distance = circuit_connections.circuit_wire_max_distance,
		max_health = 600,
		minable = {mining_time = 1, result = 'spidertron-requester-chest'},
		corpse = 'artillery-turret-remnants',
		fast_replaceable_group = 'spidertron-container',
		close_sound = {
			filename = '__base__/sound/metallic-chest-close.ogg',
			volume = 0.6
		},
		open_sound = {
			filename = '__base__/sound/metallic-chest-open.ogg',
			volume = 0.6
		},
		collision_box = {{-0.7, -0.7}, {0.7, 0.7}},
		selection_box = {{-1, -1}, {1, 1}},
		flags = {'placeable-neutral', 'player-creation'},
		se_allow_in_space = true
	},
	{
		name = 'spidertron-logistic-controller',
		type = 'movement-bonus-equipment',
		energy_consumption = '100kW',
		movement_bonus = settings.startup['spidertron-speed'].value / -100,
		categories = {'spidertron-logistic-controller'},
		items_to_place_this = {name = 'spidertron-logistic-controller', count = 1},
		shape = {
			type = 'full',
			width = 1,
			height = 1
		},
		energy_source = {
			usage_priority = 'secondary-input',
			type = 'electric',
		},
		sprite = {
			filename = '__spidertron-logistics__/graphics/equipment/spidertron-logistic-controller.png',
			size = {32, 32}
		}
	},
	{
		type = 'recipe',
		name = 'spidertron-requester-chest',
		ingredients = {
			{type = 'item', name = 'requester-chest', amount = 4},
			{type = 'item', name = 'spidertron-remote', amount = 1}
		},
		energy_required = 4,
		results = {{type = 'item', name = 'spidertron-requester-chest', amount = 1}},
		enabled = false
	},
	{
		type = 'recipe',
		name = 'spidertron-provider-chest',
		ingredients = {
			{type = 'item', name = 'storage-chest', amount = 4},
			{type = 'item', name = 'spidertron-remote', amount = 1}
		},
		energy_required = 4,
		results = {{type = 'item', name = 'spidertron-provider-chest', amount = 1}},
		enabled = false
	},
	{
		type = 'recipe',
		name = 'spidertron-logistic-controller',
		ingredients = {
			-- {type = 'item', name = 'rocket-control-unit', amount = 10},
			{type = 'item', name = 'processing-unit', amount = 10}
			-- {type = 'item', name = 'spidertron-remote', amount = 1}
		},
		results = {{type = 'item', name = 'spidertron-logistic-controller', amount = 1}},
		enabled = false
	},
	{
		type = 'recipe',
		name = 'spidertron-logistic-beacon',
		ingredients = {
			{type = 'item', name = 'steel-plate', amount = 10},
			{type = 'item', name = 'processing-unit', amount = 2}
			-- {type = 'item', name = 'spidertron-remote', amount = 1}
		},
		results = {{type = 'item', name = 'spidertron-logistic-beacon', amount = 1}},
		enabled = false
	},
	{
		type = 'technology',
		name = 'spidertron-logistic-system',
		icon = '__spidertron-logistics__/graphics/technology/spidertron-logistics-system.png',
		icon_size = 128,
		effects = {
			{
				recipe = 'spidertron-logistic-controller',
				type = 'unlock-recipe'
			},
			{
				recipe = 'spidertron-logistic-beacon',
				type = 'unlock-recipe'
			},
			{
				recipe = 'spidertron-requester-chest',
				type = 'unlock-recipe'
			},
			{
				recipe = 'spidertron-provider-chest',
				type = 'unlock-recipe'
			}
		},
		prerequisites = {
			'spidertron',
			'logistic-system'
		},
		unit = {
			count = 3000,
			ingredients = {
				{'automation-science-pack', 1},
				{'logistic-science-pack', 1},
				{'chemical-science-pack', 1},
				{'production-science-pack', 1},
				{'utility-science-pack', 1},
			},
			time = 30
		}
	},
	{
		name = 'spidertron-logistic-beacon',
		type = 'roboport',
		icon = '__spidertron-logistics__/graphics/new/graphics/radar.png',
		icon_size = 64,
		icon_mipmaps = 4,
		energy_source = {
			type = 'electric',
			usage_priority = 'secondary-input',
			buffer_capacity = '24MW'
		},
		energy_usage = '400kW',
		recharge_minimum = '400kW',
		robot_slots_count = 0,
		material_slots_count = 0,
		collision_box = {{-0.8, -0.8}, {0.8, 0.8}},
		selection_box = {{-1, -1}, {1, 1}},
		base = {
			filename = '__spidertron-logistics__/graphics/new/graphics/transparent.png',
			width = 1,
			height = 1
		},
		base_animation = {
			layers = {
				{
					filename = '__spidertron-logistics__/graphics/new/graphics/hr-radar-red.png',
					priority = 'medium',
					width = 196,
					height = 254,
					frame_count = 64,
					line_length = 8,
					shift = util.by_pixel(1, -13),
					scale = 0.335,
					direction_count = 1,
					animation_speed = 0.5,
					hr_version = {
						filename = '__spidertron-logistics__/graphics/new/graphics/hr-radar-red.png',
						priority = 'medium',
						width = 196,
						height = 254,
						frame_count = 64,
						line_length = 8,
						shift = util.by_pixel(1, -13),
						scale = 0.335,
						direction_count = 1,
						animation_speed = 0.5
					}
				},
				{
					filename = '__base__/graphics/entity/radar/radar-shadow.png',
					priority = 'medium',
					width = 336,
					height = 170,
					frame_count = 64,
					line_length = 8,
					draw_as_shadow = true,
					shift = util.by_pixel(26, 2),
					scale = 0.335,
					hr_version = {
						filename = '__base__/graphics/entity/radar/hr-radar-shadow.png',
						priority = 'medium',
						width = 336,
						height = 170,
						frame_count = 64,
						line_length = 8,
						draw_as_shadow = true,
						shift = util.by_pixel(26, 2),
						scale = 0.335
					}
				}
			}
		},
		base_patch = {
			filename = '__spidertron-logistics__/graphics/new/graphics/transparent.png',
			width = 1,
			height = 1
		},
		door_animation_up = {
			filename = '__spidertron-logistics__/graphics/new/graphics/transparent.png',
			width = 1,
			height = 1
		},
		door_animation_down = {
			filename = '__spidertron-logistics__/graphics/new/graphics/transparent.png',
			width = 1,
			height = 1
		},
		recharging_animation = {
			filename = '__spidertron-logistics__/graphics/new/graphics/transparent.png',
			width = 1,
			height = 1
		},
		request_to_open_door_timeout = 0,
		spawn_and_station_height = 0,
		charge_approach_distance = 0,
		logistics_radius = 8.5,
		construction_radius = 20,
		charging_energy = '0W',
		rotation_speed = 0.01,
		max_health = 100,
		minable = {mining_time = 1, result = 'spidertron-logistic-beacon'},
		corpse = 'beacon-remnants',
		flags = {'placeable-neutral', 'player-creation'},
		logistics_connection_distance = 10000,
		charging_station_shift = nil,
		charging_station_count = 0,
		charging_distance = nil,
		charging_offsets = nil,
		charging_threshold_distance = nil
	}
}

if mods["Insectitron"] then
    table.remove(data.raw.technology["spidertron-logistic-system"].prerequisites, 1)
    table.insert(data.raw.technology["spidertron-logistic-system"].prerequisites, "insectitron")
elseif mods["spidertrontiers-community-updates"] then
    table.remove(data.raw.technology["spidertron-logistic-system"].prerequisites, 1)
    table.insert(data.raw.technology["spidertron-logistic-system"].prerequisites, "spidertron_mk0")
end
