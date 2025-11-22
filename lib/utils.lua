-- Utility functions for spidertron logistics mod

local utils = {}

local sqrt = math.sqrt

function utils.distance(x1, y1, x2, y2)
	if not x2 and not y2 then
		x2, y2 = y1.x, y1.y
		x1, y1 = x1.x, x1.y
	end
	return sqrt((x1 - x2) ^ 2 + (y1 - y2) ^ 2)
end

function utils.random_order(l)
	local insert = table.insert
	local random = math.random
	local order = {}
	local i = 1
	for _, elem in pairs(l) do
		insert(order, random(1, i), elem)
		i = i + 1
	end
	
	return ipairs(order)
end

function utils.index_by_object(t, o)
	for k, v in pairs(t) do
		if k == o then return v end
	end
end

function utils.stack_size(item)
	if not item or item == '' or type(item) ~= 'string' then return 1 end
	local success, prototype = pcall(function() return game.item_prototypes[item] end)
	if not success or not prototype then return 1 end
	return prototype.stack_size
end

function utils.inventory_size(entity)
	return entity.get_inventory(defines.inventory.chest).get_bar() - 1
end

return utils

