data:extend{
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
		name = 'spidertron-logistic-beacon',
		ingredients = {
			{type = 'item', name = 'steel-plate', amount = 10},
			{type = 'item', name = 'processing-unit', amount = 2}
			-- {type = 'item', name = 'spidertron-remote', amount = 1}
		},
		results = {{type = 'item', name = 'spidertron-logistic-beacon', amount = 1}},
		enabled = false
	}
}

