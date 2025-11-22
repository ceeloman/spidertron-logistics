-- Directly modify the spidertron equipment grid (Factorio 2.0 name)
local grid = data.raw['equipment-grid']['spidertron-equipment-grid']
if grid then
	if not grid.equipment_categories then
		grid.equipment_categories = {}
	end
	grid.equipment_categories[#grid.equipment_categories + 1] = 'spidertron-logistic-controller'
end

-- -- Also handle any modded spidertrons
-- for _, spider in pairs(data.raw['spider-vehicle']) do
-- 	local grid_name = spider.equipment_grid
-- 	if grid_name then
-- 		local grid = data.raw['equipment-grid'][grid_name]
-- 		if grid then
-- 			if not grid.equipment_categories then
-- 				grid.equipment_categories = {}
-- 			end
-- 			grid.equipment_categories[#grid.equipment_categories + 1] = 'spidertron-logistic-controller'
-- 		end
-- 	end
-- end
