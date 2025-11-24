data:extend{
	{
		type = 'technology',
		name = 'spidertron-logistic-system',
		icon = '__spidertron-logistics__/graphics/technology/spidertron-logistics-system.png',
		icon_size = 128,
		effects = {
			{
				recipe = 'spidertron-requester-chest',
				type = 'unlock-recipe'
			},
			{
				recipe = 'spidertron-provider-chest',
				type = 'unlock-recipe'
			},
			{
				recipe = 'spidertron-logistic-beacon',
				type = 'unlock-recipe'
			}
		},
		prerequisites = {
			'spidertron'
		},
		unit = {
			count = 3000,
			ingredients = {
				{'automation-science-pack', 1},
				{'logistic-science-pack', 1},
				{'chemical-science-pack', 1},
				{'utility-science-pack', 1},
			},
			time = 30
		}
	}
}

