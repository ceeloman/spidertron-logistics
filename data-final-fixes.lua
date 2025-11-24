-- Equipment requirement removed - spiders are activated by default

-- Find the first spider vehicle technology dynamically
local function find_first_spider_vehicle_technology()
	-- Find all spider-vehicle technologies
	local spider_technologies = {}
	local debug_info = {}
	
	-- log("=== SPIDERTRON DETECTION DEBUG ===")
	-- log("Looping through all spider-vehicle entities...")
	
	-- Loop through all spider-vehicle entities
	if not data.raw["spider-vehicle"] then
		-- log("WARNING: No spider-vehicle entities found in data.raw")
		return nil
	end
	
	for entity_name, entity_data in pairs(data.raw["spider-vehicle"]) do
		-- log("Checking spider-vehicle entity: " .. entity_name)
		
		-- Skip constructron and base spiderbot (but allow mk variants like spiderbot-mk2)
		local lower_name = entity_name:lower()
		if lower_name:find("constructron") or lower_name == "spiderbot" then
			-- log("  -> Skipping (constructron or base spiderbot)")
			goto next_entity
		end
		
		-- Check if entity has inventory (trunk) - simple check
		local has_inventory = entity_data.inventory_size or entity_data.trunk_inventory_size
		if not has_inventory then
			-- log("  -> Skipping (no inventory_size or trunk_inventory_size property)")
			goto next_entity
		end
		
		-- log("  -> Has inventory, processing...")
		
		-- Use entity name directly as item name (spidertron entity -> spidertron item)
		local item_name = entity_name
		-- log("  -> Using entity name as item name: " .. item_name)
		
		-- Verify item exists
		local item_prototype = data.raw.item[item_name] or data.raw["item-with-entity-data"][item_name]
		if not item_prototype then
			-- log("    -> WARNING: Item prototype not found in either 'item' or 'item-with-entity-data': " .. item_name)
			goto next_entity
		end
		
		-- Find all recipes that produce this item
		local recipes_for_item = {}
		for recipe_name, recipe in pairs(data.raw.recipe or {}) do
			local recipe_produces_item = false
			
			-- Check single result
			if recipe.result == item_name then
				recipe_produces_item = true
			-- Check results array
			elseif recipe.results then
				for _, result in ipairs(recipe.results) do
					local result_name = result.name or result[1]
					if result_name == item_name then
						recipe_produces_item = true
						break
					end
				end
			end
			
			if recipe_produces_item then
				table.insert(recipes_for_item, recipe_name)
				-- log("    -> Found recipe that produces item: " .. recipe_name)
			end
		end
		
		if #recipes_for_item == 0 then
			-- log("    -> WARNING: No recipes found that produce item: " .. item_name)
			goto next_entity
		end
		
		-- Iterate through all technologies to find which ones unlock these recipes
		for tech_name, tech in pairs(data.raw.technology or {}) do
			if tech.effects then
				for _, effect in ipairs(tech.effects) do
					-- Check if this technology unlocks any recipe that produces our item
					if effect.type == "unlock-recipe" then
						for _, recipe_name in ipairs(recipes_for_item) do
							if effect.recipe == recipe_name then
								-- log("    -> Found technology that unlocks recipe: " .. tech_name .. " (unlocks recipe: " .. recipe_name .. ")")
								local prereq_count = tech.prerequisites and #tech.prerequisites or 0
								
								-- Store this technology
								if not spider_technologies[tech_name] then
									spider_technologies[tech_name] = {
										tech = tech,
										entity_name = entity_name,
										item_name = item_name,
										prerequisite_count = prereq_count
									}
									table.insert(debug_info, {
										entity = entity_name,
										item = item_name,
										recipe = recipe_name,
										technology = tech_name,
										prereq_count = prereq_count
									})
								end
								goto next_tech  -- Found a match for this tech, move to next
							end
						end
					end
				end
			end
			::next_tech::
		end
		
		::next_entity::
	end
	
	-- log("Spider technologies found: " .. table_size(spider_technologies))
	
	-- Find the technology with the fewest prerequisites (earliest unlock)
	local first_tech = nil
	local min_prerequisites = math.huge
	
	for tech_name, tech_data in pairs(spider_technologies) do
		-- log("Evaluating tech: " .. tech_name .. " (prereqs: " .. tech_data.prerequisite_count .. ")")
		if tech_data.prerequisite_count < min_prerequisites then
			min_prerequisites = tech_data.prerequisite_count
			first_tech = tech_name
		end
	end
	
	if first_tech then
		-- log("Selected first spider tech: " .. first_tech .. " with " .. min_prerequisites .. " prerequisites")
	else
		-- log("WARNING: No spider technology found!")
	end
	
	-- log("=== END SPIDERTRON DETECTION DEBUG ===")
	
	-- Store debug info for runtime access
	_G.spidertron_detection_debug = debug_info
	_G.first_spider_tech_result = first_tech
	
	return first_tech
end

-- Helper function to get table size
function table_size(t)
	local count = 0
	for _ in pairs(t) do
		count = count + 1
	end
	return count
end

-- Find the technology that unlocks advanced-circuit recipe
local function find_advanced_circuit_technology()
	-- Check if advanced-circuit recipe exists
	local adv_circuit_recipe = data.raw.recipe["advanced-circuit"]
	if not adv_circuit_recipe then
		return nil
	end
	
	-- Find technology that unlocks advanced-circuit
	for tech_name, tech in pairs(data.raw.technology or {}) do
		if tech.effects then
			for _, effect in ipairs(tech.effects) do
				if effect.type == "unlock-recipe" and effect.recipe == "advanced-circuit" then
					return tech_name
				end
			end
		end
	end
	return nil
end

-- Update technology prerequisite to use the first spider vehicle technology
local first_spider_tech = find_first_spider_vehicle_technology()
local adv_circuit_tech = find_advanced_circuit_technology()

if data.raw.technology["spidertron-logistic-system"] then
	local tech = data.raw.technology["spidertron-logistic-system"]
	
	-- Build prerequisites list
	local prerequisites = {}
	if first_spider_tech then
		table.insert(prerequisites, first_spider_tech)
		-- log("Setting spidertron-logistic-system prerequisite to: " .. first_spider_tech)
	else
		-- log("WARNING: No spider tech found, keeping default prerequisite")
	end
	if adv_circuit_tech then
		table.insert(prerequisites, adv_circuit_tech)
		-- log("Adding advanced-circuit technology as prerequisite: " .. adv_circuit_tech)
		
		-- Get the advanced-circuit technology's cost and triple it
		local prereq_tech = data.raw.technology[adv_circuit_tech]
		if prereq_tech and prereq_tech.unit then
			-- Triple the count
			local tripled_count = prereq_tech.unit.count * 3
			
			-- Triple each ingredient amount
			local tripled_ingredients = {}
			if prereq_tech.unit.ingredients then
				for _, ingredient in ipairs(prereq_tech.unit.ingredients) do
					local pack_name = ingredient[1] or ingredient.name
					local pack_amount = (ingredient[2] or ingredient.amount or 1) * 3
					table.insert(tripled_ingredients, {pack_name, pack_amount})
				end
			end
			
			-- Apply tripled cost to our technology
			tech.unit = {
				count = tripled_count,
				ingredients = tripled_ingredients,
				time = prereq_tech.unit.time or 30
			}
			
			-- log("Tripled advanced-circuit prerequisite cost: " .. prereq_tech.unit.count .. " -> " .. tripled_count)
			-- local ingredient_str = ""
			-- for _, ing in ipairs(tripled_ingredients) do
			-- 	ingredient_str = ingredient_str .. ing[1] .. " x" .. ing[2] .. ", "
			-- end
			-- log("Ingredients: " .. ingredient_str)
		else
			-- log("WARNING: Could not get advanced-circuit technology unit data")
		end
	end
	
	if #prerequisites > 0 then
		tech.prerequisites = prerequisites
	else
		-- log("WARNING: No prerequisites set for spidertron-logistic-system")
	end
end

