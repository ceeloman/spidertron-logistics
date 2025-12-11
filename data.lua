require 'data.items'
require 'data.entities'
require 'data.recipes'
require 'data.technology'

-- Custom input for requests debug GUI
data:extend({
	{
		type = "custom-input",
		name = "spidertron-logistics-requests-gui",
		key_sequence = "ALT + N",
		consuming = "game-only"
	}
})