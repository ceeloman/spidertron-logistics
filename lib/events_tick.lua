-- Tick event handlers for spidertron logistics

local constants = require('lib.constants')
local utils = require('lib.utils')
local beacon_assignment = require('lib.beacon_assignment')
local logistics = require('lib.logistics')
local journey = require('lib.journey')
local pathing = require('lib.pathing')
local rendering = require('lib.rendering')
local route_planning = require('lib.route_planning')
local logging = require('lib.logging')
local gui = require('lib.gui')

local events_tick = {}

-- Debug logging flags (set to false to disable verbose logs)
local DEBUG_IMMEDIATE_JOB_CHECK = false  -- Set to true to enable immediate job check logs
local DEBUG_240_TICK_HANDLER = false     -- Set to true to enable 240-tick handler logs

-- Helper function for conditional debug logging
local function debug_log(flag, message)
	if flag then
		log(message)
	end
end

-- Local references for performance
local min = math.min
local tostring = tostring

function events_tick.register()
	-- Single unified tick handler with staged processing
	script.on_event(defines.events.on_tick, function(event)
		local tick = event.tick
		
		-- EVERY 5 MINUTES (18000 ticks): Periodic global validation to catch any stale data
		-- This is a safety net - most stale data is already handled by live inventory checks
		if tick % 18000 == 0 then
			logistics.validate_all_requesters()
		end
		
		-- EVERY TICK: Close item picker GUI (needs to be immediate)
		if storage.close_item_picker_next_tick then
			for player_index, should_close in pairs(storage.close_item_picker_next_tick) do
				if should_close then
					local player = game.get_player(player_index)
					if player and player.valid then
						local gui_data = storage.requester_guis[player_index]
						if gui_data and gui_data.last_opened_requester then
							local requester_entity = gui_data.last_opened_requester.entity
							if requester_entity and requester_entity.valid then
								-- Ensure player.opened is set to our requester
								if player.opened ~= requester_entity then
									player.opened = requester_entity
								end
								
								-- Close selection list GUI (the item picker opened by choose-elem-button)
								-- Selection list GUIs are screen GUIs, look for them and close
								local screen = player.gui.screen
								if screen then
									-- Iterate through screen children to find selection list GUI
									-- Selection list GUIs are usually frames with specific structure
									for _, child in pairs(screen.children) do
										if child and child.valid then
											local child_name = child.name or ""
											-- Check if this looks like a selection list GUI
											-- Selection list GUIs typically have a list-box or similar structure
											-- We can identify them by checking for list-box children or specific names
											local has_list_box = false
											for _, subchild in pairs(child.children) do
												if subchild and subchild.valid and subchild.type == "list-box" then
													has_list_box = true
													break
												end
											end
											
											-- If it has a list-box, it's likely the selection list GUI - close it
											if has_list_box then
												child.destroy()
												break
											end
											
											-- Also check if it's a frame with a name that suggests it's a selection list
											if child.type == "frame" and child_name ~= "" and (child_name:find("selection") or child_name:find("list") or child_name:find("picker")) then
												child.destroy()
												break
											end
										end
									end
								end
							end
						end
						-- Clear the flag after one tick
						storage.close_item_picker_next_tick[player_index] = nil
					end
				end
			end
		end
		
		-- EVERY TICK: Check for spiders that need immediate job assignment (after dumping)
		-- THIS MUST RUN BEFORE THE 240-TICK HANDLER TO PREVENT PREMATURE JOB ASSIGNMENT
		if next(storage.spiders) then
			for unit_number, spider_data in pairs(storage.spiders) do
				if spider_data.needs_immediate_job_check then
					debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] ========== START Tick " .. tick .. " ==========")
					debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] Spider " .. unit_number .. " - status=" .. spider_data.status .. " (idle=" .. constants.idle .. ", picking_up=" .. constants.picking_up .. ", dropping_off=" .. constants.dropping_off .. "), active=" .. tostring(spider_data.active) .. ", position=(" .. math.floor(spider_data.entity.position.x) .. "," .. math.floor(spider_data.entity.position.y) .. ")")
					
					-- Clear the flag FIRST to prevent it from running every tick
					spider_data.needs_immediate_job_check = nil
					
					-- If status is already picking_up or dropping_off, something assigned a job BEFORE this check ran
					if spider_data.status == constants.picking_up or spider_data.status == constants.dropping_off then
						debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] ✗✗✗ CRITICAL: Spider " .. unit_number .. " already has job (status=" .. spider_data.status .. ") - SOMETHING ASSIGNED A JOB BEFORE IMMEDIATE CHECK RAN!")
						debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] ✗✗✗ This means the 240-tick handler or another system assigned a job, bypassing multi-job checks!")
						debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] ========== END Tick " .. tick .. " (spider " .. unit_number .. ") ==========")
					elseif spider_data.active then
						-- Allow check to run if spider is active
						-- Status should be idle after end_journey, but if it's not, we'll still try to assign a job
						debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] Processing immediate job check - status=" .. spider_data.status .. " (expected idle=" .. constants.idle .. ")")
						local spider = spider_data.entity
						if spider and spider.valid then
							debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] Tick " .. tick .. ": Processing immediate job check for spider " .. unit_number)
							
							-- FIRST: Check if spider has an incomplete route that should continue
							if spider_data.route and spider_data.current_route_index then
								local route = spider_data.route
								local current_index = spider_data.current_route_index
								debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [ROUTE] Tick " .. tick .. ": Spider " .. unit_number .. " has route - current_index=" .. current_index .. ", route_length=" .. #route .. ", status=" .. spider_data.status)
								if current_index <= #route then
									-- Route is incomplete, continue it
									debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [ROUTE] Tick " .. tick .. ": Continuing route for spider " .. unit_number .. " (stop " .. current_index .. " of " .. #route .. ")")
									local advanced = journey.advance_route(unit_number)
									if advanced then
										debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [ROUTE] Tick " .. tick .. ": ✓ Successfully advanced route for spider " .. unit_number .. ", new_status=" .. spider_data.status)
										goto next_spider_immediate_check
									else
										debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [ROUTE] Tick " .. tick .. ": ✗ Failed to advance route for spider " .. unit_number .. ", route ended")
										-- Route ended, continue to check for new jobs below
									end
								else
									debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [ROUTE] Tick " .. tick .. ": Route complete (current_index " .. current_index .. " > route_length " .. #route .. ")")
								end
							else
								debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [ROUTE] Tick " .. tick .. ": Spider " .. unit_number .. " has no route (route=" .. tostring(spider_data.route ~= nil) .. ", current_route_index=" .. tostring(spider_data.current_route_index) .. ")")
							end
							
							-- Get spider's network
							local network = beacon_assignment.spidertron_network(spider)
							if network then
								debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] Tick " .. tick .. ": Spider " .. unit_number .. " has network " .. network.network_key)
								
								-- CRITICAL: Refresh inventory caches BEFORE getting providers/requesters
								-- This ensures can_provider_supply uses fresh data
								debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] Tick " .. tick .. ": Refreshing inventory caches to ensure fresh data")
								logistics.refresh_inventory_caches(true)  -- Force refresh
								
								-- Get available requests, spiders, and providers for this network
								local requests = logistics.requesters()
								local spiders_list = logistics.spiders()
								local providers_list = logistics.providers()
								
								-- DEBUG: Log what providers actually have after refresh
								debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] Tick " .. tick .. ": After cache refresh, checking provider data:")
								for network_key_check, providers_check in pairs(providers_list) do
									if network_key_check == network.network_key then
										for idx, prov_data in ipairs(providers_check) do
											if prov_data.entity and prov_data.entity.valid then
												local has_cache = prov_data.cached_contents ~= nil
												local cache_size = 0
												if prov_data.cached_contents then
													for _ in pairs(prov_data.cached_contents) do
														cache_size = cache_size + 1
													end
												end
												debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] Tick " .. tick .. ": Provider " .. idx .. " (unit=" .. prov_data.entity.unit_number .. ") - has_cached_contents=" .. tostring(has_cache) .. ", cache_has " .. cache_size .. " item type(s)")
											end
										end
									end
								end
								
								local network_key = network.network_key
								local requesters = requests[network_key]
								local spiders_on_network = spiders_list[network_key]
								local providers_for_network = providers_list[network_key]
								
								debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] Tick " .. tick .. ": Network " .. network_key .. " - requesters=" .. (requesters and #requesters or 0) .. ", providers=" .. (providers_for_network and #providers_for_network or 0) .. ", spiders=" .. (spiders_on_network and #spiders_on_network or 0))
								
								-- If no requesters available, path to beacon
								if not requesters or #requesters == 0 then
									debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] Tick " .. tick .. ": No requesters available, pathing spider " .. unit_number .. " to beacon")
									local beacon = network.beacon
									if beacon and beacon.valid then
										pathing.set_smart_destination(spider, beacon.position, beacon)
									else
										-- Fallback: find nearest beacon
										local nearest_beacon = beacon_assignment.find_nearest_beacon(spider.surface, spider.position, spider.force, nil, "immediate_job_check_no_requests")
										if nearest_beacon then
											pathing.set_smart_destination(spider, nearest_beacon.position, nearest_beacon)
										end
									end
									goto next_spider_immediate_check
								end
								
								-- Only process if we have requests, providers, and this spider is available
								if providers_for_network and #providers_for_network > 0 and spiders_on_network then
									-- Find this spider in the list
									local spider_found = false
									for _, candidate in ipairs(spiders_on_network) do
										if candidate.unit_number == spider.unit_number then
											spider_found = true
											break
										end
									end
									
									debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] Tick " .. tick .. ": Spider " .. unit_number .. " found in network list: " .. tostring(spider_found))
									
									-- If spider is in the list, try to assign a job
									if spider_found then
										-- Create a list with only this spider to ensure it gets the job
										local single_spider_list = {spider}
										
										-- Log what we're checking for multi-jobs
										debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [MULTI_JOB] Tick " .. tick .. ": ========== STARTING MULTI-JOB CHECKS ==========")
										debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [MULTI_JOB] Tick " .. tick .. ": Requirements - requesters=" .. #requesters .. ", providers=" .. #providers_for_network .. ", spider=" .. unit_number)
										
										-- Log what each requester needs
										for idx, req in ipairs(requesters) do
											if req.real_amount > 0 then
												debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [MULTI_JOB] Tick " .. tick .. ": Requester " .. idx .. " - item=" .. (req.requested_item or "nil") .. ", amount=" .. req.real_amount .. ", requester_unit=" .. (req.requester_data and req.requester_data.entity and req.requester_data.entity.unit_number or "nil"))
											end
										end
										
										-- Log what each provider can provide
										for idx, prov in ipairs(providers_for_network) do
											if prov.entity and prov.entity.valid then
												local contents = prov.entity.get_inventory(defines.inventory.chest).get_contents()
												local item_count = 0
												for item_name, count in pairs(contents) do
													item_count = item_count + 1
												end
												debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [MULTI_JOB] Tick " .. tick .. ": Provider " .. idx .. " - unit=" .. prov.entity.unit_number .. ", has " .. item_count .. " item type(s)")
											end
										end
										
										-- SECOND: Check for multi-item, multi-requester routes (most efficient)
										debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [MULTI_JOB] Tick " .. tick .. ": Checking for multi-item, multi-requester routes - spider=" .. unit_number .. ", requesters=" .. #requesters .. ", providers=" .. #providers_for_network)
										local best_spider_pos = spider.position
										debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [MULTI_JOB] Tick " .. tick .. ": Calling find_multi_item_multi_requester_route with spider_pos=(" .. math.floor(best_spider_pos.x) .. "," .. math.floor(best_spider_pos.y) .. ")")
										local multi_item_multi_req_route = route_planning.find_multi_item_multi_requester_route(requesters, providers_for_network, best_spider_pos)
										if multi_item_multi_req_route then
											debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [MULTI_JOB] Tick " .. tick .. ": ✓✓✓ FOUND multi-item, multi-requester route! Stops=" .. #multi_item_multi_req_route)
										else
											debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [MULTI_JOB] Tick " .. tick .. ": ✗ No multi-item, multi-requester route found")
										end
										if multi_item_multi_req_route then
											debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [MULTI_JOB] Tick " .. tick .. ": ✓ Found multi-item, multi-requester route for spider " .. unit_number .. " (stops=" .. #multi_item_multi_req_route .. ")")
											local assigned = logistics.assign_spider_with_route(single_spider_list, multi_item_multi_req_route, "multi_item_multi_requester")
											if assigned then
												debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [MULTI_JOB] Tick " .. tick .. ": ✓✓ SUCCESS - Assigned multi-item, multi-requester route to spider " .. unit_number)
												-- Mark all affected requests as assigned
												for _, item_req in ipairs(requesters) do
													if item_req.real_amount > 0 then
														item_req.real_amount = 0
													end
												end
												goto next_spider_immediate_check
											else
												debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [MULTI_JOB] Tick " .. tick .. ": ✗ Failed to assign multi-item, multi-requester route to spider " .. unit_number)
											end
										else
											debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [MULTI_JOB] Tick " .. tick .. ": ✗ No multi-item, multi-requester route found for spider " .. unit_number)
										end
										
										-- THIRD: Group requests by item and check for mixed routes (same item, multiple requesters)
										debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [MULTI_JOB] Tick " .. tick .. ": Grouping requests by item for mixed route check - spider=" .. unit_number)
										local all_requests_by_item = {}
										for _, item_request in ipairs(requesters) do
											local item = item_request.requested_item
											if item and item_request.real_amount > 0 then
												if not all_requests_by_item[item] then
													all_requests_by_item[item] = {}
												end
												table.insert(all_requests_by_item[item], item_request)
											end
										end
										
										local items_with_multiple_requesters = 0
										for item, item_requests_list in pairs(all_requests_by_item) do
											if #item_requests_list >= 2 then
												items_with_multiple_requesters = items_with_multiple_requesters + 1
											end
										end
										debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [MULTI_JOB] Tick " .. tick .. ": Grouped into " .. items_with_multiple_requesters .. " item(s) with 2+ requesters - spider=" .. unit_number)
										
										-- Check for same-item routes (mixed, multi-pickup, multi-delivery)
										for item, item_requests_list in pairs(all_requests_by_item) do
											-- Calculate total needed
											local total_needed = 0
											for _, item_req in ipairs(item_requests_list) do
												total_needed = total_needed + item_req.real_amount
											end
											
											-- Check for mixed route (2+ providers AND 2+ requesters)
											if #item_requests_list >= 2 and #providers_for_network >= 2 then
												debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [MULTI_JOB] Tick " .. tick .. ": Checking mixed route - item=" .. item .. ", requesters=" .. #item_requests_list .. ", providers=" .. #providers_for_network .. ", total_needed=" .. total_needed .. ", spider=" .. unit_number)
												
												local mixed_route = route_planning.find_mixed_route(item, total_needed, providers_for_network, requesters, best_spider_pos)
												if mixed_route then
													debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [MULTI_JOB] Tick " .. tick .. ": ✓ Found mixed route for spider " .. unit_number .. " - item=" .. item .. " (stops=" .. #mixed_route .. ")")
													local assigned = logistics.assign_spider_with_route(single_spider_list, mixed_route, "mixed")
													if assigned then
														debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [MULTI_JOB] Tick " .. tick .. ": ✓✓ SUCCESS - Assigned mixed route to spider " .. unit_number)
														-- Mark all affected requests as assigned
														for _, item_req in ipairs(item_requests_list) do
															if item_req.real_amount > 0 then
																item_req.real_amount = 0
															end
														end
														goto next_spider_immediate_check
													else
														debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [MULTI_JOB] Tick " .. tick .. ": ✗ Failed to assign mixed route to spider " .. unit_number)
													end
												else
													debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [MULTI_JOB] Tick " .. tick .. ": ✗ No mixed route found for item=" .. item .. ", spider=" .. unit_number)
												end
											end
											
											-- Check for multi-pickup route (2+ providers, 1 requester)
											if #item_requests_list == 1 and #providers_for_network >= 2 then
												local item_request = item_requests_list[1]
												local requester_data = item_request.requester_data
												local requester = requester_data.entity
												
												debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [MULTI_JOB] Tick " .. tick .. ": Checking multi-pickup route - item=" .. item .. ", requester=" .. requester.unit_number .. ", providers=" .. #providers_for_network .. ", needed=" .. item_request.real_amount .. ", spider=" .. unit_number)
												
												local multi_pickup_route = route_planning.find_multi_pickup_route(requester, item, item_request.real_amount, providers_for_network, best_spider_pos)
												if multi_pickup_route then
													debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [MULTI_JOB] Tick " .. tick .. ": ✓ Found multi-pickup route for spider " .. unit_number .. " - item=" .. item .. " (stops=" .. #multi_pickup_route .. ")")
													local assigned = logistics.assign_spider_with_route(single_spider_list, multi_pickup_route, "multi_pickup")
													if assigned then
														debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [MULTI_JOB] Tick " .. tick .. ": ✓✓ SUCCESS - Assigned multi-pickup route to spider " .. unit_number)
														item_request.real_amount = 0
														goto next_spider_immediate_check
													else
														debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [MULTI_JOB] Tick " .. tick .. ": ✗ Failed to assign multi-pickup route to spider " .. unit_number)
													end
												else
													debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [MULTI_JOB] Tick " .. tick .. ": ✗ No multi-pickup route found for item=" .. item .. ", spider=" .. unit_number)
												end
											end
											
											-- Check for multi-delivery route (1 provider, 2+ requesters)
											-- Only check if we didn't already try mixed route (which requires 2+ providers)
											if #item_requests_list >= 2 and #providers_for_network == 1 then
												-- Find best provider for this item
												local best_provider = nil
												local max_available = 0
												for _, provider_data in ipairs(providers_for_network) do
													local provider = provider_data.entity
													if provider and provider.valid then
														local inv = provider.get_inventory(defines.inventory.chest)
														if inv then
															local item_count = inv.get_item_count(item)
															local allocated = (provider_data.allocated_items and provider_data.allocated_items[item]) or 0
															local available = item_count - allocated
															if available > max_available then
																max_available = available
																best_provider = provider_data
															end
														end
													end
												end
												
												if best_provider and max_available > 0 then
													debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [MULTI_JOB] Tick " .. tick .. ": Checking multi-delivery route - item=" .. item .. ", provider=" .. best_provider.entity.unit_number .. ", requesters=" .. #item_requests_list .. ", available=" .. max_available .. ", spider=" .. unit_number)
													
													local multi_delivery_route = route_planning.find_multi_delivery_route(best_provider.entity, item, max_available, requesters, best_spider_pos)
													if multi_delivery_route then
														debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [MULTI_JOB] Tick " .. tick .. ": ✓ Found multi-delivery route for spider " .. unit_number .. " - item=" .. item .. " (stops=" .. #multi_delivery_route .. ")")
														local assigned = logistics.assign_spider_with_route(single_spider_list, multi_delivery_route, "multi_delivery")
														if assigned then
															debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [MULTI_JOB] Tick " .. tick .. ": ✓✓ SUCCESS - Assigned multi-delivery route to spider " .. unit_number)
															-- Mark all affected requests as assigned
															for _, item_req in ipairs(item_requests_list) do
																if item_req.real_amount > 0 then
																	item_req.real_amount = 0
																end
															end
															goto next_spider_immediate_check
														else
															debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [MULTI_JOB] Tick " .. tick .. ": ✗ Failed to assign multi-delivery route to spider " .. unit_number)
														end
													else
														debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [MULTI_JOB] Tick " .. tick .. ": ✗ No multi-delivery route found for item=" .. item .. ", spider=" .. unit_number)
													end
												end
											end
										end
										
										-- FOURTH: Group requests by requester and check for multi-item routes (one requester, multiple items)
										debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [MULTI_JOB] Tick " .. tick .. ": ========== CHECKING MULTI-ITEM ROUTES ==========")
										debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [MULTI_JOB] Tick " .. tick .. ": Grouping requests by requester for multi-item route check - spider=" .. unit_number)
										local requests_by_requester = {}
										for _, item_request in ipairs(requesters) do
											local requester_data = item_request.requester_data
											local requester_unit_number = requester_data.entity.unit_number
											if not requests_by_requester[requester_unit_number] then
												requests_by_requester[requester_unit_number] = {}
											end
											table.insert(requests_by_requester[requester_unit_number], item_request)
											debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [MULTI_JOB] Tick " .. tick .. ": Added request - requester=" .. requester_unit_number .. ", item=" .. (item_request.requested_item or "nil") .. ", amount=" .. item_request.real_amount)
										end
										
										local requesters_with_multiple_items = 0
										for requester_unit_number, requester_item_requests in pairs(requests_by_requester) do
											debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [MULTI_JOB] Tick " .. tick .. ": Requester " .. requester_unit_number .. " has " .. #requester_item_requests .. " item request(s)")
											if #requester_item_requests >= 2 then
												requesters_with_multiple_items = requesters_with_multiple_items + 1
											end
										end
										debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [MULTI_JOB] Tick " .. tick .. ": Grouped into " .. requesters_with_multiple_items .. " requester(s) with 2+ items - spider=" .. unit_number)
										
										-- Check for multi-item routes for each requester
										for requester_unit_number, requester_item_requests in pairs(requests_by_requester) do
											-- Need at least 2 items for this requester to consider multi-item route
											if #requester_item_requests >= 2 then
												local first_request = requester_item_requests[1]
												local requester_data = first_request.requester_data
												local requester = requester_data.entity
												
												debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [MULTI_JOB] Tick " .. tick .. ": Checking multi-item route - requester=" .. requester_unit_number .. ", items=" .. #requester_item_requests .. ", spider=" .. unit_number)
												
												local multi_item_route = route_planning.find_multi_item_route(requester, requester_item_requests, providers_for_network, best_spider_pos)
												if multi_item_route then
													debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [MULTI_JOB] Tick " .. tick .. ": ✓ Found multi-item route for spider " .. unit_number .. " - requester=" .. requester_unit_number .. " (stops=" .. #multi_item_route .. ")")
													local assigned = logistics.assign_spider_with_route(single_spider_list, multi_item_route, "multi_item")
													if assigned then
														debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [MULTI_JOB] Tick " .. tick .. ": ✓✓ SUCCESS - Assigned multi-item route to spider " .. unit_number)
														-- Mark all affected requests as assigned
														for _, item_req in ipairs(requester_item_requests) do
															if item_req.real_amount > 0 then
																item_req.real_amount = 0
															end
														end
														goto next_spider_immediate_check
													else
														debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [MULTI_JOB] Tick " .. tick .. ": ✗ Failed to assign multi-item route to spider " .. unit_number)
													end
												else
													debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [MULTI_JOB] Tick " .. tick .. ": ✗ No multi-item route found for requester=" .. requester_unit_number .. ", spider=" .. unit_number)
												end
											end
										end
										
										debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [SINGLE_JOB] Tick " .. tick .. ": No multi-routes found, checking single-item requests - spider=" .. unit_number .. ", available_requests=" .. #requesters)
										
										-- FIFTH: Process single-item requests in order
										local single_job_found = false
										for _, item_request in ipairs(requesters) do
											if item_request.real_amount > 0 then
												local item = item_request.requested_item
												local requester_data = item_request.requester_data
												
												debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [SINGLE_JOB] Tick " .. tick .. ": Checking single-item request - item=" .. item .. ", real_amount=" .. item_request.real_amount .. ", requester=" .. requester_data.entity.unit_number .. ", spider=" .. unit_number)
												
												-- Find best provider for this item
												debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [SINGLE_JOB] Tick " .. tick .. ": Checking " .. #providers_for_network .. " provider(s) for item=" .. item)
												local best_provider = nil
												local max = 0
												for idx, provider_data in ipairs(providers_for_network) do
													local provider = provider_data.entity
													if provider and provider.valid then
														local is_requester_excess = provider_data.is_requester_excess or false
														
														debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [SINGLE_JOB] Tick " .. tick .. ": Provider " .. idx .. " (unit=" .. provider.unit_number .. ") - type=" .. provider.type .. ", name=" .. provider.name .. ", is_requester_excess=" .. tostring(is_requester_excess))
														
														local direct_item_count = 0
														if is_requester_excess then
															if provider_data.contains and provider_data.contains[item] then
																direct_item_count = provider_data.contains[item]
															else
																direct_item_count = 0
															end
														else
															-- Regular provider - use get_item_count directly like 240-tick handler
															local inv = provider.get_inventory(defines.inventory.chest)
															if inv then
																direct_item_count = inv.get_item_count(item)
															end
														end
														
														local allocated = (provider_data.allocated_items and provider_data.allocated_items[item]) or 0
														local can_provide = math.max(0, direct_item_count - allocated)
														
														debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [SINGLE_JOB] Tick " .. tick .. ": Provider " .. idx .. " - direct_item_count=" .. direct_item_count .. ", can_provide(direct)=" .. can_provide)
														
														if can_provide > 0 and can_provide > max then
															max = can_provide
															best_provider = provider_data
															debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [SINGLE_JOB] Tick " .. tick .. ": Provider " .. idx .. " (unit=" .. provider.unit_number .. ") is new best provider (can_provide=" .. can_provide .. ")")
														end
													else
														debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [SINGLE_JOB] Tick " .. tick .. ": Provider " .. idx .. " is invalid or nil")
													end
												end
												
												debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [SINGLE_JOB] Tick " .. tick .. ": Provider search complete - best_provider=" .. (best_provider and best_provider.entity.unit_number or "nil") .. ", max=" .. max)
												
												if best_provider and max > 0 then
													debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [SINGLE_JOB] Tick " .. tick .. ": Found provider - item=" .. item .. ", provider=" .. best_provider.entity.unit_number .. ", can_provide=" .. max .. ", spider=" .. unit_number)
													
													-- Create temporary requester object
													local temp_requester = {
														entity = requester_data.entity,
														requested_item = item,
														real_amount = item_request.real_amount,
														incoming_items = requester_data.incoming_items
													}
													
													debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [SINGLE_JOB] Tick " .. tick .. ": Attempting assignment - spider=" .. unit_number .. ", status_before=" .. spider_data.status)
													
													-- Try to assign to this specific spider
													local assigned = logistics.assign_spider(single_spider_list, temp_requester, best_provider, max)
													
													if assigned then
														debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [SINGLE_JOB] Tick " .. tick .. ": ✓✓ SUCCESS - Assigned single-item job to spider " .. unit_number .. ", status_after=" .. spider_data.status)
														-- Successfully assigned, update real_amount and exit
														item_request.real_amount = temp_requester.real_amount
														single_job_found = true
														break
													else
														debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [SINGLE_JOB] Tick " .. tick .. ": ✗ FAILED - assign_spider returned false for spider " .. unit_number .. ", status=" .. spider_data.status)
													end
												else
													debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [SINGLE_JOB] Tick " .. tick .. ": ✗ No provider found for item=" .. item .. ", spider=" .. unit_number)
												end
											end
										end
										
										if not single_job_found then
											debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] [SINGLE_JOB] Tick " .. tick .. ": ✗ No single-item job assigned to spider " .. unit_number)
											debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] Tick " .. tick .. ": No job assigned to spider " .. unit_number .. ", pathing to beacon.")
											local nearest_beacon = beacon_assignment.find_nearest_beacon(spider.surface, spider.position, spider.force, nil, "immediate_job_no_assignment")
											if nearest_beacon then
												pathing.set_smart_destination(spider, nearest_beacon.position, nearest_beacon)
											end
										end
									else
										debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] Tick " .. tick .. ": Spider " .. unit_number .. " NOT found in network list!")
										-- Path to beacon if spider not in network list
										local nearest_beacon = beacon_assignment.find_nearest_beacon(spider.surface, spider.position, spider.force, nil, "immediate_job_check_not_in_list")
										if nearest_beacon then
											pathing.set_smart_destination(spider, nearest_beacon.position, nearest_beacon)
										end
									end
								else
									debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] Tick " .. tick .. ": Cannot process - missing requirements (requesters=" .. (requesters and #requesters or 0) .. ", providers=" .. (providers_for_network and #providers_for_network or 0) .. ", spiders=" .. (spiders_on_network and #spiders_on_network or 0) .. ")")
									-- If no providers but we have requesters, path to beacon to wait
									if (not providers_for_network or #providers_for_network == 0) and requesters and #requesters > 0 then
										debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] Tick " .. tick .. ": No providers available but have requesters, pathing spider " .. unit_number .. " to beacon")
										local beacon = network.beacon
										if beacon and beacon.valid then
											pathing.set_smart_destination(spider, beacon.position, beacon)
										else
											local nearest_beacon = beacon_assignment.find_nearest_beacon(spider.surface, spider.position, spider.force, nil, "immediate_job_check_no_providers")
											if nearest_beacon then
												pathing.set_smart_destination(spider, nearest_beacon.position, nearest_beacon)
											end
										end
									elseif not requesters or #requesters == 0 then
										-- No requesters, path to beacon
										debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] Tick " .. tick .. ": No requesters available, pathing spider " .. unit_number .. " to beacon")
										local beacon = network.beacon
										if beacon and beacon.valid then
											pathing.set_smart_destination(spider, beacon.position, beacon)
										else
											local nearest_beacon = beacon_assignment.find_nearest_beacon(spider.surface, spider.position, spider.force, nil, "immediate_job_check_no_requesters")
											if nearest_beacon then
												pathing.set_smart_destination(spider, nearest_beacon.position, nearest_beacon)
											end
										end
									end
								end
							else
								debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] Tick " .. tick .. ": Spider " .. unit_number .. " has NO network!")
								-- Path to nearest beacon if no network
								local nearest_beacon = beacon_assignment.find_nearest_beacon(spider.surface, spider.position, spider.force, nil, "immediate_job_check_no_network")
								if nearest_beacon then
									pathing.set_smart_destination(spider, nearest_beacon.position, nearest_beacon)
								end
							end
						else
							debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] Tick " .. tick .. ": Spider " .. unit_number .. " entity invalid!")
						end
						::next_spider_immediate_check::
					else
						debug_log(DEBUG_IMMEDIATE_JOB_CHECK, "[IMMEDIATE_JOB_CHECK] Tick " .. tick .. ": Spider " .. unit_number .. " conditions not met (status=" .. spider_data.status .. " != " .. constants.idle .. " or active=" .. tostring(spider_data.active) .. ")")
					end
				end
			end
		end
		
		-- EVERY 10 TICKS: UI updates, connection lines, flashing icons
		if tick % 10 == 0 then
			-- Check all players for selected/hovered entities
			for _, player in pairs(game.players) do
				if player and player.valid then
					local entity = player.selected
					if entity and entity.valid then
						-- Check if it's a chest or beacon
						if entity.name == constants.spidertron_requester_chest or 
						   entity.name == constants.spidertron_provider_chest or 
						   entity.name == constants.spidertron_logistic_beacon then
							-- Draw connection lines
							-- rendering.draw_connection_lines(entity)
						end
						
						-- Always remove beacon GUI if it exists (cleanup)
						if player.gui.screen["spidertron_beacon_info_frame"] then
							player.gui.screen["spidertron_beacon_info_frame"].destroy()
						end
					else
						-- No entity selected, remove beacon GUI if it exists
						if player.gui.screen["spidertron_beacon_info_frame"] then
							player.gui.screen["spidertron_beacon_info_frame"].destroy()
						end
					end
				end
			end
			
			-- Draw flashing icons for spiders that can't dump items
			for unit_number, spider_data in pairs(storage.spiders) do
				if spider_data.status == constants.dumping_items then
					local spider = spider_data.entity
					if spider and spider.valid then
						rendering.draw_dump_failed_icon(spider, spider_data)
					end
				end
			end
			
			-- Status text is now only updated when status changes (in journey.lua, logistics.lua, etc.)
			-- No periodic update needed - this prevents text from being recreated every second
		end
		
		-- EVERY 60 TICKS: Memory cleanup, cache expiration
		if tick % 60 == 0 then
			local current_tick = tick
			
			-- Clean up old pathfinding requests (older than 5 seconds)
			if storage.path_requests then
				for request_id, request_data in pairs(storage.path_requests) do
					if request_data.start_tick and (current_tick - request_data.start_tick) > 300 then
						storage.path_requests[request_id] = nil
					end
				end
			end
			
			-- Clean up expired pathfinding cache entries
			if storage.pathfinding_cache then
				for cache_key, cached_path in pairs(storage.pathfinding_cache) do
					if cached_path.cache_tick and (current_tick - cached_path.cache_tick) > constants.pathfinding_cache_ttl then
						storage.pathfinding_cache[cache_key] = nil
					end
				end
			end
			
			-- Clean up expired distance cache entries
			if storage.distance_cache then
				for cache_key, cached_dist in pairs(storage.distance_cache) do
					if cached_dist.cache_tick and (current_tick - cached_dist.cache_tick) > constants.distance_cache_ttl then
						storage.distance_cache[cache_key] = nil
					end
				end
			end
			
			-- Clean up old pathfinder statuses (older than 10 seconds)
			if storage.pathfinder_statuses then
				for spider_unit_number, statuses in pairs(storage.pathfinder_statuses) do
					for tick_key, status in pairs(statuses) do
						if (current_tick - tick_key) > 600 then
							statuses[tick_key] = nil
						end
					end
					-- Remove empty status tables
					local has_entries = false
					for _ in pairs(statuses) do
						has_entries = true
						break
					end
					if not has_entries then
						storage.pathfinder_statuses[spider_unit_number] = nil
					end
				end
			end
			
			-- Update player GUI toolbar for all players (check remote selection)
			for _, player in pairs(game.players) do
				if player and player.valid then
					gui.add_player_gui_toolbar(player)
				end
			end
		end
	end)

	-- Main logistics update loop
	script.on_nth_tick(constants.update_cooldown, function(event)
		-- Check all spiders in dumping_items status
		for unit_number, spider_data in pairs(storage.spiders) do
			if spider_data.status == constants.dumping_items then
				local spider = spider_data.entity
				if not spider or not spider.valid then
					spider_data.status = constants.idle
					goto next_dumping_spider
				end
				
				-- If no dump_target, try to find one
				if not spider_data.dump_target or not spider_data.dump_target.valid then
					local dump_success = journey.attempt_dump_items(unit_number)
					-- If attempt_dump_items failed and still no dump_target, end journey and set idle
					if not dump_success and (not spider_data.dump_target or not spider_data.dump_target.valid) then
						-- No storage chests available - end journey and set to idle
						spider_data.dump_target = nil
						journey.end_journey(unit_number, true)
					end
					goto next_dumping_spider
				end
				
				-- Check if spider is close enough to dump target and try to dump
				local dump_target = spider_data.dump_target
				if dump_target and dump_target.valid then
					local distance = utils.distance(spider.position, dump_target.position)
					if distance <= 6 then
						-- Spider is close enough, try to dump items
						
						-- Clear autopilot to ensure spider stops
						if spider.autopilot_destinations and #spider.autopilot_destinations > 0 then
							spider.autopilot_destination = nil
						end
						
						-- Get spidertron's logistic requests to avoid dumping requested items
						local logistic_requests = utils.get_spider_logistic_requests(spider)

						-- Try to dump items
						-- Iterate through inventory slots directly instead of using get_contents()
						local trunk = spider.get_inventory(defines.inventory.spider_trunk)
						if not trunk then
							journey.end_journey(unit_number, true)
							return
						end


						local dumped_any = false
						local processed_items = {}  -- Track which items we've already decided on
						local item_excess = {}  -- Cache the excess amount for each item

						-- First pass: calculate excess for each item type
						for i = 1, #trunk do
							local stack = trunk[i]
							if stack and stack.valid_for_read and stack.count > 0 then
								local item_name = stack.name
								
								-- Skip if we've already calculated excess for this item
								if processed_items[item_name] then goto next_calc_slot end
								
								-- Get total count of this item in spider
								local total_count = spider.get_item_count(item_name)
								local requested_count = logistic_requests[item_name] or 0
								
								if requested_count > 0 and total_count <= requested_count then
									-- Keep all of this item - it's requested and we don't have excess
									item_excess[item_name] = 0
									processed_items[item_name] = true
								elseif requested_count > 0 then
									-- Have excess beyond what's requested
									item_excess[item_name] = total_count - requested_count
								else
									-- Not requested at all - dump everything
									item_excess[item_name] = total_count
								end
								
								::next_calc_slot::
							end
						end

						-- Second pass: actually dump the excess items
						local dumped_counts = {}
						for i = 1, #trunk do
							local stack = trunk[i]
							if stack and stack.valid_for_read and stack.count > 0 then
								local item_name = stack.name
								local stack_count = stack.count
								
								-- Check if we have excess to dump
								local excess = item_excess[item_name] or 0
								if excess <= 0 then goto next_dump_slot end
								
								-- Check how much we've already dumped
								local already_dumped = dumped_counts[item_name] or 0
								local can_dump = excess - already_dumped
								
								if can_dump <= 0 then goto next_dump_slot end
								
								-- Limit to what we can actually dump from this stack
								local to_dump = math.min(stack_count, can_dump)
								
								-- Get chest inventory
								local chest_inv = dump_target.get_inventory(defines.inventory.chest)
								if not chest_inv then goto next_dump_slot end
								
								-- Try to insert
								local inserted = chest_inv.insert{name = item_name, count = to_dump}
								
								if inserted > 0 then
									local removed = spider.remove_item{name = item_name, count = inserted}
									dumped_any = true
									dumped_counts[item_name] = (dumped_counts[item_name] or 0) + inserted
								end
								
								::next_dump_slot::
							end
						end
						
						-- Check if done dumping
						local has_items = false
						for i = 1, #trunk do
							local stack = trunk[i]
							if stack and stack.valid_for_read and stack.count > 0 then
								has_items = true
								break
							end
						end
						
						if not has_items then
							-- No items left, done dumping
							spider_data.dump_target = nil
							-- End journey will set needs_immediate_job_check flag
							journey.end_journey(unit_number, true)
						elseif not dumped_any then
							-- Couldn't dump anything - check if we have any dumpable items left
							local has_dumpable = false
							
							for i = 1, #trunk do
								local stack = trunk[i]
								if stack and stack.valid_for_read and stack.count > 0 then
									local item_name = stack.name
									local total_count = spider.get_item_count(item_name)
									local requested_count = logistic_requests[item_name] or 0
									
									if requested_count == 0 or total_count > requested_count then
										has_dumpable = true
										break
									end
								end
							end
							
							if has_dumpable then
								-- Try to find another chest
								spider_data.dump_target = nil
								local dump_success = journey.attempt_dump_items(unit_number)
								-- If attempt_dump_items failed and still no dump_target, end journey and set idle
								if not dump_success and (not spider_data.dump_target or not spider_data.dump_target.valid) then
									-- No storage chests available - end journey and set to idle
									spider_data.dump_target = nil
									journey.end_journey(unit_number, true)
								end
							else
								-- No dumpable items, done
								spider_data.dump_target = nil
								journey.end_journey(unit_number, true)
							end
						end
					end
				end
				
				::next_dumping_spider::
			end
		end
		
		-- Check for saved tasks to resume (spiders that were interrupted)
		for unit_number, spider_data in pairs(storage.spiders) do
			if spider_data.status == constants.idle and spider_data.saved_task and spider_data.active then
				local spider = spider_data.entity
				if spider and spider.valid then
					-- Try to resume the saved task
					local resumed = journey.resume_task(unit_number)
					if not resumed then
						-- Resume failed (entities invalid), clear saved task
						spider_data.saved_task = nil
					end
				else
					-- Spider invalid, clear saved task
					spider_data.saved_task = nil
				end
			end
		end
		
		-- Beacon validation is now event-driven (handled in handle_entity_removal and built functions)
		-- No periodic validation needed - beacons are validated when:
		-- 1. Beacon is destroyed (handle_entity_removal reassigns all chests)
		-- 2. Chest is created (built function assigns to nearest beacon)
		-- 3. Chest loses beacon (validated on-demand in logistics functions)
		
		-- Stuck detection for active spiders
		for unit_number, spider_data in pairs(storage.spiders) do
			if spider_data.status ~= constants.idle and spider_data.status ~= constants.dumping_items then
				local spider = spider_data.entity
				if spider and spider.valid then
					local current_pos = spider.position
					local current_tick = event.tick
					
					-- Initialize position tracking if needed
					if not spider_data.last_position then
						spider_data.last_position = current_pos
						spider_data.last_position_tick = current_tick
						spider_data.stuck_count = 0
					else
						-- Check if spider has moved (more than 0.5 tiles)
						local distance_moved = utils.distance(spider_data.last_position, current_pos)
						local ticks_since_last_check = current_tick - spider_data.last_position_tick
						
						-- If spider hasn't moved much in the last 5 seconds (300 ticks), it might be stuck
						if distance_moved < 0.5 and ticks_since_last_check >= 300 then
							spider_data.stuck_count = (spider_data.stuck_count or 0) + 1
							
							-- If stuck for 2+ checks (10+ seconds), trigger repath
							if spider_data.stuck_count >= 2 then
								local pos_x = math.floor(current_pos.x)
								local pos_y = math.floor(current_pos.y)
								
								-- Clear current path
								if spider.autopilot_destinations and #spider.autopilot_destinations > 0 then
									spider.autopilot_destination = nil
								end
								
								-- Try to repath to current destination
								local destination = nil
								if spider_data.status == constants.picking_up and spider_data.provider_target and spider_data.provider_target.valid then
									destination = spider_data.provider_target
								elseif spider_data.status == constants.dropping_off and spider_data.requester_target and spider_data.requester_target.valid then
									destination = spider_data.requester_target
								end
								
								if destination then
									local pathing_success = pathing.set_smart_destination(spider, destination.position, destination)
									if pathing_success then
										-- Reset stuck detection
										spider_data.last_position = current_pos
										spider_data.last_position_tick = current_tick
										spider_data.stuck_count = 0
									end
								else
									journey.end_journey(unit_number, true)
								end
							else
								-- Update position but keep tracking
								spider_data.last_position = current_pos
								spider_data.last_position_tick = current_tick
							end
						else
							-- Spider moved, reset stuck counter
							if distance_moved >= 0.5 then
								spider_data.last_position = current_pos
								spider_data.last_position_tick = current_tick
								spider_data.stuck_count = 0
							end
						end
					end
				end
			else
				-- Reset stuck detection for idle/dumping spiders
				if spider_data.last_position then
					spider_data.last_position = nil
					spider_data.last_position_tick = nil
					spider_data.stuck_count = 0
				end
			end
		end
		
		-- Process all networks every update cycle (stagger removed - update loop already runs every 240 ticks)
		local current_tick = event.tick
		local networks_to_process = {}
		
		local requests = logistics.requesters()
		local spiders_list = logistics.spiders()
		local providers_list = logistics.providers()
		
		-- Check if any spiders have needs_immediate_job_check flag
		local spiders_with_immediate_flag = 0
		for unit_number, spider_data in pairs(storage.spiders) do
			if spider_data.needs_immediate_job_check then
				spiders_with_immediate_flag = spiders_with_immediate_flag + 1
				debug_log(DEBUG_240_TICK_HANDLER, "[240_TICK_HANDLER] Tick " .. current_tick .. ": WARNING - Spider " .. unit_number .. " has needs_immediate_job_check flag (should have been handled by immediate check!)")
			end
		end
		
		-- Process all networks that have requests, spiders, and providers
		for network_key, requesters in pairs(requests) do
			-- Skip idle networks (no requests, no spiders, or no providers)
			local providers_for_network = providers_list[network_key]
			local spiders_on_network = spiders_list[network_key]
			
			if not providers_for_network or #providers_for_network == 0 then
				goto skip_network
			end
			if not spiders_on_network or #spiders_on_network == 0 then
				goto skip_network
			end
			if not requesters or #requesters == 0 then
				goto skip_network
			end
			
			-- Add network to processing list (no stagger - process all valid networks)
			networks_to_process[network_key] = requesters
			
			::skip_network::
		end
		
		for network_key, requesters in pairs(networks_to_process) do
			local providers_for_network = providers_list[network_key]
			local spiders_on_network = spiders_list[network_key]
			
			-- CRITICAL: Filter out spiders that have needs_immediate_job_check flag
			-- These spiders should be handled by the immediate job check, not the 240-tick handler
			local filtered_spiders = {}
			for _, spider in ipairs(spiders_on_network) do
				local spider_data = storage.spiders[spider.unit_number]
				if spider_data and spider_data.needs_immediate_job_check then
					debug_log(DEBUG_240_TICK_HANDLER, "[240_TICK_HANDLER] Tick " .. current_tick .. ": SKIPPING spider " .. spider.unit_number .. " - has needs_immediate_job_check flag (will be handled by immediate check)")
				elseif spider_data and (spider_data.status == constants.idle or spider_data.status == nil) then
					table.insert(filtered_spiders, spider)
				else
					debug_log(DEBUG_240_TICK_HANDLER, "[240_TICK_HANDLER] Tick " .. current_tick .. ": SKIPPING spider " .. spider.unit_number .. " - status=" .. (spider_data and spider_data.status or "nil") .. " (not idle)")
				end
			end
			spiders_on_network = filtered_spiders
			
			if not providers_for_network then 
				goto next_network 
			end
			
			if not spiders_on_network or #spiders_on_network == 0 then 
				debug_log(DEBUG_240_TICK_HANDLER, "[240_TICK_HANDLER] Tick " .. current_tick .. ": Network " .. network_key .. " - all spiders filtered out (have immediate job check flags or not idle)")
				goto next_network 
			end
			
			-- Check for mixed routes (multi-pickup + multi-delivery) BEFORE grouping by requester
			-- This allows us to see ALL requesters needing the same item across all requester groups
			local best_spider_pos = nil
			if #spiders_on_network > 0 then
				best_spider_pos = spiders_on_network[1].position
			end
			
			if best_spider_pos then
				-- Feature 5: Check for multi-item, multi-requester route (different items, multiple providers, multiple requesters)
				-- This should be checked first as it's the most general case
				local multi_item_multi_req_route = route_planning.find_multi_item_multi_requester_route(requesters, providers_for_network, best_spider_pos)
				if multi_item_multi_req_route then
					local assigned = logistics.assign_spider_with_route(spiders_on_network, multi_item_multi_req_route, "multi_item_multi_requester")
					if assigned then
						-- Mark all affected requests as assigned
						for _, item_req in ipairs(requesters) do
							if item_req.real_amount > 0 then
								item_req.real_amount = 0
							end
						end
						if #spiders_on_network == 0 then
							goto next_network
						end
						goto next_network
					end
				end
				
				-- Group ALL requests by item type (across all requesters)
				local all_requests_by_item = {}
				for _, item_request in ipairs(requesters) do
					local item = item_request.requested_item
					if item and item_request.real_amount > 0 then
						if not all_requests_by_item[item] then
							all_requests_by_item[item] = {}
						end
						table.insert(all_requests_by_item[item], item_request)
					end
				end
				
				-- Check for mixed routes for each item
				for item, item_requests_list in pairs(all_requests_by_item) do
					-- Need at least 2 requesters for this item to consider mixed route
					if #item_requests_list >= 2 then
						-- Calculate total needed
						local total_needed = 0
						for _, item_req in ipairs(item_requests_list) do
							total_needed = total_needed + item_req.real_amount
						end
						
						local mixed_route = route_planning.find_mixed_route(item, total_needed, providers_for_network, requesters, best_spider_pos)
						if mixed_route then
							local assigned = logistics.assign_spider_with_route(spiders_on_network, mixed_route, "mixed")
							if assigned then
								-- Mark all affected requests as assigned
								for _, item_req in ipairs(item_requests_list) do
									item_req.real_amount = 0
								end
								if #spiders_on_network == 0 then
									goto next_network
								end
								-- Continue to next network (all requests for this item are assigned)
								goto next_network
							end
						end
					end
				end
			end
			
			-- Group requests by requester for multi-item route detection
			local requests_by_requester = {}
			for _, item_request in ipairs(requesters) do
				local requester_data = item_request.requester_data
				local requester_unit_number = requester_data.entity.unit_number
				if not requests_by_requester[requester_unit_number] then
					requests_by_requester[requester_unit_number] = {}
				end
				table.insert(requests_by_requester[requester_unit_number], item_request)
			end
			
			-- Process each requester's requests
			for requester_unit_number, requester_item_requests in pairs(requests_by_requester) do
				local first_request = requester_item_requests[1]
				local requester_data = first_request.requester_data
				local requester = requester_data.entity
				
				-- Feature 3: Check for multi-item route (one requester, multiple items)
				if #requester_item_requests >= 2 then
					local requested_items = {}
					for _, item_req in ipairs(requester_item_requests) do
						if item_req.requested_item and item_req.real_amount > 0 then
							requested_items[item_req.requested_item] = item_req.real_amount
						end
					end
					
					if next(requested_items) then
						-- Find best spider position for route comparison
						local best_spider_pos = nil
						local best_spider = nil
						if #spiders_on_network > 0 then
							best_spider = spiders_on_network[1]
							best_spider_pos = best_spider.position
						else
							goto skip_multi_item
						end
						
						-- Try to find multi-item route
						local multi_item_route = route_planning.find_multi_item_route(requester, requested_items, providers_for_network, best_spider_pos)
						if multi_item_route then
							local assigned = logistics.assign_spider_with_route(spiders_on_network, multi_item_route, "multi_item")
							if assigned then
								-- Mark all items in this route as assigned
								for _, item_req in ipairs(requester_item_requests) do
									item_req.real_amount = 0  -- Mark as assigned
								end
								if #spiders_on_network == 0 then
									goto next_network
								end
								goto next_requester_group
							end
						end
					end
				end
				
				::skip_multi_item::
				
				-- Process each item request for this requester
				for _, item_request in ipairs(requester_item_requests) do
					local item = item_request.requested_item
					if not item or item_request.real_amount <= 0 then 
						goto next_item_request 
					end
					
					-- Feature 1: Check for multi-pickup route (multiple providers for same item)
					if best_spider_pos then
						local multi_pickup_route = route_planning.find_multi_pickup_route(requester, item, item_request.real_amount, providers_for_network, best_spider_pos)
						if multi_pickup_route then
							local assigned = logistics.assign_spider_with_route(spiders_on_network, multi_pickup_route, "multi_pickup")
							if assigned then
								item_request.real_amount = 0  -- Mark as assigned
								if #spiders_on_network == 0 then
									goto next_network
								end
								goto next_item_request
							end
						end
					end
					
					-- Feature 2: Check for multi-delivery route (one provider, multiple requesters)
					-- Find best provider first
					local max = 0
					local best_provider
					for _, provider_data in ipairs(providers_for_network) do
						local provider = provider_data.entity
						if not provider or not provider.valid then goto next_provider end
						
						local item_count = 0
						local allocated = 0
						
						if provider_data.is_requester_excess then
							-- For requester excess providers, use the contains field which has the excess amount
							if provider_data.contains and provider_data.contains[item] then
								item_count = provider_data.contains[item]
							else
								item_count = 0
							end
							if not provider_data.allocated_items then
								provider_data.allocated_items = {}
							end
							allocated = provider_data.allocated_items[item] or 0
						else
							item_count = provider.get_inventory(defines.inventory.chest).get_item_count(item)
							if not provider_data.allocated_items then
								provider_data.allocated_items = {}
							end
							allocated = provider_data.allocated_items[item] or 0
						end
						
						if item_count <= 0 then goto next_provider end
						
						local can_provide = item_count - allocated
						
						if can_provide > 0 and can_provide > max then
							max = can_provide
							best_provider = provider_data
						end
						
						::next_provider::
					end
					
					if not best_provider or max <= 0 then
						goto next_item_request
					end
					
					if best_provider and max > 0 then
						-- Check for multi-delivery route
						if best_spider_pos then
							local multi_delivery_route = route_planning.find_multi_delivery_route(best_provider.entity, item, max, requesters, best_spider_pos)
							if multi_delivery_route then
								local assigned = logistics.assign_spider_with_route(spiders_on_network, multi_delivery_route, "multi_delivery")
								if assigned then
									-- Mark all affected requests as assigned
									for _, req in ipairs(requesters) do
										if req.requested_item == item and req.requester_data.entity.unit_number ~= requester_unit_number then
											-- Check if this requester is in the route
											for _, stop in ipairs(multi_delivery_route) do
												if stop.type == "delivery" and stop.entity.unit_number == req.requester_data.entity.unit_number then
													req.real_amount = math.max(0, req.real_amount - stop.amount)
													break
												end
											end
										end
									end
									item_request.real_amount = 0  -- Mark as assigned
									if #spiders_on_network == 0 then
										goto next_network
									end
									goto next_item_request
								end
							end
						end
						
						-- Fallback to single assignment
						-- Buffer threshold is now handled in should_request_item, so no need for delay check here
						
						-- Check if we should delay this assignment to batch more items
						if logistics.should_delay_assignment(requester_data, best_provider, max, item_request.real_amount, item_request.percentage_filled) then
							goto next_item_request  -- Skip this assignment, try again next cycle
						end
						
						-- Create a temporary requester_data-like object for assign_spider
						local temp_requester = {
							entity = requester_data.entity,
							requested_item = item,
							real_amount = item_request.real_amount,
							incoming_items = requester_data.incoming_items
						}
						
						debug_log(DEBUG_240_TICK_HANDLER, "[240_TICK_HANDLER] Tick " .. current_tick .. ": ========== ASSIGNING SINGLE JOB ==========")
						debug_log(DEBUG_240_TICK_HANDLER, "[240_TICK_HANDLER] Tick " .. current_tick .. ": Item=" .. item .. ", requester=" .. requester_data.entity.unit_number .. ", provider=" .. best_provider.entity.unit_number .. ", can_provide=" .. max)
						debug_log(DEBUG_240_TICK_HANDLER, "[240_TICK_HANDLER] Tick " .. current_tick .. ": Available spiders=" .. #spiders_on_network)
						for idx, spider in ipairs(spiders_on_network) do
							local spider_data = storage.spiders[spider.unit_number]
							debug_log(DEBUG_240_TICK_HANDLER, "[240_TICK_HANDLER] Tick " .. current_tick .. ": Spider " .. idx .. " (unit=" .. spider.unit_number .. ") - status=" .. (spider_data and spider_data.status or "nil") .. ", needs_immediate_job_check=" .. tostring(spider_data and spider_data.needs_immediate_job_check or false))
						end
						local assigned = logistics.assign_spider(spiders_on_network, temp_requester, best_provider, max)
						if assigned then
							debug_log(DEBUG_240_TICK_HANDLER, "[240_TICK_HANDLER] Tick " .. current_tick .. ": ✓✓✓ JOB ASSIGNED by 240-tick handler (this should NOT happen if immediate check ran first!)")
						end
						if not assigned then
							goto next_item_request
						end
						
						-- Update item_request.real_amount to reflect the remaining amount after assignment
						-- This prevents the same request from being assigned to multiple spiders
						item_request.real_amount = temp_requester.real_amount
						
						if #spiders_on_network == 0 then
							goto next_network
						end
					end
					
					::next_item_request::
				end
				
				::next_requester_group::
			end
			::next_network::
		end
	end)
end

return events_tick

