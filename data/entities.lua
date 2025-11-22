local circuit_connections = require 'circuit-connections'

data:extend{
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
		name = 'spidertron-logistic-beacon',
		type = 'radar',
		icon = '__spidertron-logistics__/graphics/new/graphics/radar.png',
		icon_size = 64,
		icon_mipmaps = 4,
		energy_source = {
			type = 'electric',
			usage_priority = 'secondary-input',
			buffer_capacity = '24MW'
		},
		energy_usage = '400kW',
		energy_per_sector = '10MJ',
		energy_per_nearby_scan = '250kJ',
		max_distance_of_sector_revealed = 14,
		max_distance_of_nearby_sector_revealed = 3,
		radius_minimap_visualisation_color = {r = 0.059, g = 0.092, b = 0.235, a = 0.275},
		rotation_speed = 0.01,
		collision_box = {{-0.8, -0.8}, {0.8, 0.8}},
		selection_box = {{-1, -1}, {1, 1}},
		pictures = {
			layers = {
				{
					filename = '__spidertron-logistics__/graphics/new/graphics/hr-radar-red.png',
					priority = 'medium',
					width = 196,
					height = 254,
					apply_projection = false,
					direction_count = 64,
					line_length = 8,
					shift = util.by_pixel(1, -13),
					scale = 0.335,
					hr_version = {
						filename = '__spidertron-logistics__/graphics/new/graphics/hr-radar-red.png',
						priority = 'medium',
						width = 196,
						height = 254,
						apply_projection = false,
						direction_count = 64,
						line_length = 8,
						shift = util.by_pixel(1, -13),
						scale = 0.335
					}
				},
				{
					filename = '__base__/graphics/entity/radar/radar-shadow.png',
					priority = 'medium',
					width = 336,
					height = 170,
					apply_projection = false,
					direction_count = 64,
					line_length = 8,
					draw_as_shadow = true,
					shift = util.by_pixel(26, 2),
					scale = 0.335,
					hr_version = {
						filename = '__base__/graphics/entity/radar/hr-radar-shadow.png',
						priority = 'medium',
						width = 336,
						height = 170,
						apply_projection = false,
						direction_count = 64,
						line_length = 8,
						draw_as_shadow = true,
						shift = util.by_pixel(26, 2),
						scale = 0.335
					}
				}
			}
		},
		max_health = 100,
		minable = {mining_time = 1, result = 'spidertron-logistic-beacon'},
		flags = {'placeable-neutral', 'player-creation'}
	}
}

