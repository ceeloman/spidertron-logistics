data:extend{
	{
		type = 'technology',
		name = 'spidertron-logistic-system',
		icon = '__spidertron-logistics__/graphics/technology/spidertron-logistics-system.png',
		icon_size = 128,
		effects = {
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
	}
}

if mods["Insectitron"] then
    table.remove(data.raw.technology["spidertron-logistic-system"].prerequisites, 1)
    table.insert(data.raw.technology["spidertron-logistic-system"].prerequisites, "insectitron")
elseif mods["spidertrontiers-community-updates"] then
    table.remove(data.raw.technology["spidertron-logistic-system"].prerequisites, 1)
    table.insert(data.raw.technology["spidertron-logistic-system"].prerequisites, "spidertron_mk0")
end

