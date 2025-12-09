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
	-- Use prototypes.item[item_name] in Factorio 2.0
	local success, prototype = pcall(function() return prototypes.item[item] end)
	if not success or not prototype then return 1 end
	return prototype.stack_size
end

function utils.inventory_size(entity)
	local inventory = entity.get_inventory(defines.inventory.chest)
	if not inventory then return 0 end
	return #inventory
end

-- Get spidertron's logistic requests
function utils.get_spider_logistic_requests(spider)
	if not spider.valid then return {} end
	
	-- Get all logistic points
	local logistic_points = spider.get_logistic_point()
	if not logistic_points then return {} end
	
	local requests = {}
	for point_index, logistic_point in pairs(logistic_points) do
		local filters = logistic_point.filters
		if filters then
			for _, filter in pairs(filters) do
				if filter then
					if filter.value and filter.value.name then
						local item_name = filter.value.name
						local min_count = filter.min or 0
						requests[item_name] = (requests[item_name] or 0) + min_count
					elseif filter.name then
						local min_count = filter.min or filter.count or 0
						requests[filter.name] = (requests[filter.name] or 0) + min_count
					end
				end
			end
		end
	end
	
	return requests
end

-- Check if a driver is a dummy engineer from neural-spider-control mod
-- Dummy engineers are automated and won't interfere with logistics
function utils.is_dummy_driver(driver)
	if not driver or not driver.valid then
		return false
	end
	
	-- Check if neural-spider-control mod is present and has dummy engineers
	-- Use storage (which neural-spider-control mod uses) or fall back to global
	local neural_data = (storage and storage.neural_spider_control) or (global and global.neural_spider_control)
	if not neural_data or not neural_data.dummy_engineers then
		return false
	end
	
	-- Check if this driver is in the dummy engineers list
	for player_index, dummy_data in pairs(neural_data.dummy_engineers) do
		if type(dummy_data) == "table" and dummy_data.entity then
			-- Table format with entity reference
			if dummy_data.entity == driver then
				return true
			end
			if driver.unit_number and dummy_data.unit_number == driver.unit_number then
				return true
			end
		elseif dummy_data and dummy_data.valid then
			-- Direct entity reference
			if dummy_data == driver then
				return true
			end
			if driver.unit_number and dummy_data.unit_number and dummy_data.unit_number == driver.unit_number then
				return true
			end
		end
	end
	
	return false
end

return utils

