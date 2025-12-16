-- Spider-related event handlers for spidertron logistics

local constants = require('lib.constants')
local utils = require('lib.utils')
local journey = require('lib.journey')
local pathing = require('lib.pathing')
local rendering = require('lib.rendering')
local logging = require('lib.logging')

local events_spider = {}

-- Local references for performance
local min = math.min

function events_spider.register()
	-- Save task state when spider is moved/interrupted
	script.on_event(defines.events.on_player_driving_changed_state, function(event)
		local spider = event.entity
		if spider and storage.spiders[spider.unit_number] then
			-- Save task state for resumption
			journey.end_journey(spider.unit_number, false, true)
		end
	end)

	script.on_event(defines.events.on_player_used_spidertron_remote, function(event)
		local spider = event.vehicle
		if event.success and storage.spiders[spider.unit_number] then
			-- Save task state for resumption
			journey.end_journey(spider.unit_number, false, true)
		end
	end)

	-- Handle pathfinding results
	script.on_event(defines.events.on_script_path_request_finished, function(event)
		pathing.handle_path_result(event)
	end)

	script.on_event(defines.events.on_spider_command_completed, function(event)
		local spider = event.vehicle
		local unit_number = spider.unit_number
		local spider_data = storage.spiders[unit_number]
		
		-- Don't check pickup_in_progress here - check it only when status is picking_up
		-- This allows delivery to proceed even if the flag wasn't cleared properly
		
		local goal
		if spider_data == nil or not spider_data.status or spider_data.status == constants.idle then
			return
		elseif spider_data.status == constants.picking_up then
			-- NOW check pickup_in_progress - only block if we're actually picking up
			if spider_data.pickup_in_progress then
				return
			end
			-- For routes, requester_target may be nil (we're picking up first)
			-- Only require requester_target for non-route pickups
			if not spider_data.route then
				if not spider_data.requester_target or not spider_data.requester_target.valid then
					journey.end_journey(unit_number, true)
					return
				end
			end
			goal = spider_data.provider_target
		elseif spider_data.status == constants.dropping_off then
			-- Don't check pickup_in_progress for delivery - it should have been cleared
			-- But clear it here just in case it wasn't
			if spider_data.pickup_in_progress then
				spider_data.pickup_in_progress = nil
			end
			if not spider_data.requester_target or not spider_data.requester_target.valid then
				journey.end_journey(unit_number, true)
				return
			end
			goal = spider_data.requester_target
		elseif spider_data.status == constants.dumping_items then
			-- Dumping items is handled separately, don't process here
			return
		end
		
		-- Check if goal is valid (but don't check distance - spider might still be traveling)
		if not goal or not goal.valid or goal.to_be_deconstructed() or spider.surface ~= goal.surface then
			local reason = "unknown"
			if not goal then reason = "goal is nil"
			elseif not goal.valid then reason = "goal invalid"
			elseif goal.to_be_deconstructed() then reason = "goal marked for deconstruction"
			elseif spider.surface ~= goal.surface then reason = "different surface"
			end
			journey.end_journey(unit_number, true)
			return
		end
		
		-- Check distance separately - only cancel if spider is way too far (likely lost/stuck)
		-- Normal travel distance can be hundreds of tiles, so we use a much larger threshold
		local distance_to_goal = utils.distance(spider.position, goal.position)
		if distance_to_goal > 1000 then
			journey.end_journey(unit_number, true)
			return
		end
		
		local requester = spider_data.requester_target
		local requester_data = nil
		if requester and requester.valid then
			requester_data = storage.requesters[requester.unit_number]
		end
		
		if spider_data.status == constants.picking_up then
			-- Declare ALL variables in this block to avoid goto scope issues
			-- These variables are used after the batch_pickup_complete label
			-- They must all be declared here, not in outer scope, so goto can jump to label
			local item = spider_data.payload_item
			local item_count = spider_data.payload_item_count
			local provider = spider_data.provider_target
			local provider_data = nil
			-- Note: Robot chest support was removed in version 3.0.2
			local actually_inserted = 0
			local already_had = 0
			local start_tick = event.tick
			local operation_count = 0
			local distance_to_provider = 0
			local provider_inventory = nil
			local contains = 0
			local stop_amount = 0
			local trunk = nil
			local max_can_insert = 0
			local can_insert = 0
			local provider_inv_size = 0
			local removed_via_api = 0
			-- Timing variables
			local tick_before_spider_count = 0
			local tick_after_spider_count = 0
			local tick_before_get_count = 0
			local tick_after_get_count = 0
			local tick_before_loop = 0
			local tick_after_loop = 0
			local tick_before_empty = 0
			local tick_after_empty = 0
			local tick_before_insert = 0
			local tick_after_insert = 0
			local tick_before_remove = 0
			local tick_after_remove = 0
			local tick_before_find = 0
			local tick_after_find = 0
			local tick_before_verify = 0
			local tick_after_verify = 0
			-- Other variables
			local total_count = 0
			local requester_data_for_excess = nil
			local item_data = nil
			local requested_count = 0
			local current_stop = nil
			local stack_size = 0
			local space_in_existing = 0
			local trunk_size = 0
			local stack = nil
			local empty_slots = 0
			local space_in_empty = 0
			local remaining_to_remove = 0
			local slots_checked = 0
			local to_remove = 0
			local nearest_provider = nil
			local final_spider_count = 0
			
			-- Simple pickup - insert all items at once (no batching)
			if not provider or not provider.valid then
				logging.warn("Pickup", "Provider target is invalid!")
				if spider_data.pickup_in_progress then
					spider_data.pickup_in_progress = nil
				end
				journey.end_journey(unit_number, true)
				return
			end
			
			-- Verify spider is actually close enough to the provider
			-- (pickup_in_progress is already checked at the top of the handler)
			distance_to_provider = utils.distance(spider.position, provider.position)
			
			-- Check if spider already has the items it needs (pickup might have completed in a previous tick)
			local item = spider_data.payload_item
			local item_count = spider_data.payload_item_count
			local spider_has = item and spider.get_item_count(item) or 0
			local needs_more = item_count and (spider_has < item_count) or true
			
			if distance_to_provider > 6 then
				-- Spider not close enough yet, wait for next command completion
				return
			end
			
			-- If spider already has enough items, don't start pickup again
			if not needs_more and spider_has >= item_count then
				-- Update status and proceed to delivery
				spider_data.status = constants.dropping_off
				if spider_data.requester_target and spider_data.requester_target.valid then
					pathing.set_smart_destination(spider, spider_data.requester_target.position, spider_data.requester_target)
					rendering.draw_status_text(spider, spider_data)
				end
				return
			end
			
			-- Mark pickup as in progress BEFORE starting (prevents loops)
			spider_data.pickup_in_progress = true
			
			-- Clear any remaining autopilot destinations to ensure spider stops
			-- This prevents the spider from continuing to move and triggering more command_completed events
			if spider.autopilot_destinations and #spider.autopilot_destinations > 0 then
				spider.autopilot_destination = nil
			end
			
			-- Get how many items spider already has BEFORE attempting pickup
			-- This must be done AFTER clearing destinations but BEFORE any insert operations
			tick_before_spider_count = event.tick
			already_had = spider.get_item_count(item) or 0
			tick_after_spider_count = event.tick
			start_tick = event.tick
			operation_count = 0
			
			-- Get provider data if not already set
			if not provider_data then
				provider_data = storage.providers[provider.unit_number]
			end
			
			-- Note: Robot chest detection was removed in version 3.0.2
			-- Only custom spidertron logistics provider chests are supported
			
			-- Get item count from provider chest inventory
			if not item then
				logging.warn("Pickup", "Spider " .. unit_number .. " cancelling: item is nil")
				journey.end_journey(unit_number, true)
				return
			end
			
			provider_inventory = provider.get_inventory(defines.inventory.chest)
			contains = 0
			if provider_inventory then
				-- For requester excess providers, only take the excess amount, not the full requested amount
				if provider_data and provider_data.is_requester_excess then
					-- Get the total count in the chest
					tick_before_get_count = event.tick
					total_count = provider_inventory.get_item_count(item) or 0
					tick_after_get_count = event.tick
					operation_count = operation_count + 1
					-- Get the requested amount for this item
					requester_data_for_excess = storage.requesters[provider.unit_number]
					if requester_data_for_excess and requester_data_for_excess.requested_items and requester_data_for_excess.requested_items[item] then
						item_data = requester_data_for_excess.requested_items[item]
						requested_count = type(item_data) == "number" and item_data or (item_data.count or 0)
						-- Only take the excess (amount above requested)
						contains = math.max(0, total_count - requested_count)
					else
						-- Fallback: use total count if we can't determine requested amount
						contains = total_count
					end
				else
					-- Regular provider: use total count
					tick_before_get_count = event.tick
					contains = provider_inventory.get_item_count(item) or 0
					tick_after_get_count = event.tick
					operation_count = operation_count + 1
				end
			else
				logging.warn("Pickup", "Provider has no inventory")
				spider_data.pickup_in_progress = nil
				journey.end_journey(unit_number, true)
				return
			end
			
			-- For routes, get the stop's amount (what this provider should give)
			-- For non-routes, use item_count (the amount assigned to this spider)
			stop_amount = item_count
			if spider_data.route and spider_data.current_route_index then
				current_stop = spider_data.route[spider_data.current_route_index]
				if current_stop and current_stop.amount then
					stop_amount = current_stop.amount
				end
			end
			
			-- Get spider trunk inventory
			trunk = spider.get_inventory(defines.inventory.spider_trunk)
			if not trunk then
				logging.warn("Pickup", "Spider has no trunk inventory")
				spider_data.pickup_in_progress = nil
				journey.end_journey(unit_number, true)
				return
			end
			
			-- already_had was set earlier, right after clearing destinations
			-- This section is only reached if we didn't set it above (shouldn't happen, but safety check)
			if already_had == nil then
				tick_before_spider_count = event.tick
				already_had = spider.get_item_count(item) or 0
				tick_after_spider_count = event.tick
				operation_count = operation_count + 1
			end
			
			-- Check how much we can actually insert (respects stack sizes and inventory limits)
			-- trunk.can_insert() is boolean, so we need to calculate the actual limit
			max_can_insert = 0
			if trunk.can_insert({name = item, count = 1}) then
				-- Spider can insert at least 1, calculate how many
				stack_size = utils.stack_size(item)
				
				-- Calculate space in existing stacks of this item
				tick_before_loop = event.tick
				space_in_existing = 0
				trunk_size = #trunk
				for i = 1, trunk_size do
					stack = trunk[i]
					if stack and stack.valid_for_read and stack.name == item then
						space_in_existing = space_in_existing + (stack_size - stack.count)
					end
				end
				tick_after_loop = event.tick
				operation_count = operation_count + 1
				
				-- Calculate space in empty slots
				tick_before_empty = event.tick
				empty_slots = trunk.count_empty_stacks(false, false)
				tick_after_empty = event.tick
				operation_count = operation_count + 1
				space_in_empty = empty_slots * stack_size
				
				-- Total space available
				max_can_insert = space_in_existing + space_in_empty
			end
			
			-- Limit to what provider has and what this stop should provide
			can_insert = min(max_can_insert, contains, stop_amount)
			
			-- CRITICAL: Ensure we don't collect more than stop_amount (the requested amount)
			-- If stop_amount is 0 or invalid, something is wrong
			if stop_amount <= 0 then
				logging.warn("Pickup", "Spider " .. unit_number .. " has invalid stop_amount: " .. stop_amount)
				journey.end_journey(unit_number, true)
				return
			end
			
			if can_insert <= 0 then
				-- Inventory is full - check if we have items to deliver
				local requester = spider_data.requester_target
				if requester and requester.valid and already_had > 0 then
					-- Spider has items, switch to delivery instead of going to beacon
					spider_data.pickup_in_progress = nil
					spider_data.status = constants.dropping_off
					spider_data.payload_item_count = already_had
					-- Update incoming_items to reflect what we actually have
					if requester_data then
						if not requester_data.incoming_items then
							requester_data.incoming_items = {}
						end
						-- Adjust incoming_items to match what we actually have
						local current_incoming = requester_data.incoming_items[item] or 0
						requester_data.incoming_items[item] = math.min(current_incoming, already_had)
					end
					-- Go to requester
					pathing.set_smart_destination(spider, requester.position, requester)
					-- Draw status text
					rendering.draw_status_text(spider, spider_data)
					return
				end
				
				-- If we already have some items and this is a route, continue with route
				if already_had > 0 and spider_data.route and spider_data.current_route_index then
					-- Update payload and continue
					if not spider_data.route_payload then
						spider_data.route_payload = {}
					end
					spider_data.route_payload[item] = already_had
					spider_data.payload_item_count = already_had
					spider_data.pickup_in_progress = nil
					-- Advance route
					local advanced = journey.advance_route(unit_number)
					if not advanced then
						return
					end
					return
				end
				
				-- No items to deliver, cancel
				spider_data.pickup_in_progress = nil
				journey.end_journey(unit_number, true)
				return
			end
			
			-- Simple single insert - items transfer all at once
			tick_before_insert = event.tick
			local count_before_insert = spider.get_item_count(item)
			actually_inserted = spider.insert{name = item, count = can_insert}
			local count_after_insert = spider.get_item_count(item)
			local actual_added = count_after_insert - count_before_insert
			tick_after_insert = event.tick
			operation_count = operation_count + 1
			
			if actually_inserted == 0 and already_had == 0 then
				logging.warn("Pickup", "Spider " .. unit_number .. " cancelling: failed to insert items (can_insert: " .. can_insert .. ", actually_inserted: " .. actually_inserted .. ", already_had: " .. already_had .. ")")
				spider_data.pickup_in_progress = nil
				journey.end_journey(unit_number, true)
				return
			end
			
			if actually_inserted ~= 0 then
				-- CRITICAL: Only remove what was actually inserted, not what we requested
				-- Use actually_inserted (what insert() returned) to ensure we don't remove more than we took
				local amount_to_remove = math.min(actually_inserted, can_insert)
				
				-- Remove items from the end of the inventory (last slots first)
				provider_inventory = provider.get_inventory(defines.inventory.chest)
				remaining_to_remove = amount_to_remove
				
				-- OPTIMIZATION: Use remove_item instead of iterating through all slots
				-- This is much faster for large inventories
				tick_before_remove = event.tick
				provider_inv_size = #provider_inventory
				
				-- Try using remove_item first (faster for Factorio to handle internally)
				removed_via_api = provider.remove_item{name = item, count = amount_to_remove}
				
				-- If remove_item didn't remove everything (shouldn't happen, but fallback)
				if removed_via_api < amount_to_remove then
					remaining_to_remove = amount_to_remove - removed_via_api
					-- Fallback to manual removal only if needed
					slots_checked = 0
					for i = provider_inv_size, 1, -1 do
						if remaining_to_remove <= 0 then
							break
						end
						slots_checked = slots_checked + 1
						stack = provider_inventory[i]
						if stack and stack.valid_for_read and stack.name == item then
							to_remove = math.min(remaining_to_remove, stack.count)
							stack.count = stack.count - to_remove
							remaining_to_remove = remaining_to_remove - to_remove
						end
					end
				end
				
				tick_after_remove = event.tick
				operation_count = operation_count + 1
			end
			
			-- Completion logic (process after pickup completes)
			-- DON'T clear pickup_in_progress flag here - clear it AFTER we've updated the spider's destination
			-- This prevents command_completed events from firing while we're transitioning to delivery
			-- The flag will be cleared after we set the new destination below
			
			-- Verify we didn't pick up more than stop_amount
			local final_spider_count = spider.get_item_count(item)
			local total_picked_up = final_spider_count - already_had
			
			-- Track pickup_count for provider chests
			-- Note: Robot chest support was removed in version 3.0.2
			if provider_data then
				provider_data.pickup_count = (provider_data.pickup_count or 0) + actually_inserted
			end
			rendering.draw_withdraw_icon(provider)
			
			-- Verify pickup actually succeeded before proceeding
			tick_before_verify = event.tick
			final_spider_count = spider.get_item_count(item)
			tick_after_verify = event.tick
			operation_count = operation_count + 1
			-- Calculate expected count: what we had before + what we inserted
			-- Note: already_had is set at the start of pickup, actually_inserted is what we just inserted
			local expected_count = already_had + actually_inserted
			
			if final_spider_count < expected_count then
				-- Pickup didn't complete as expected - retry
				-- Initialize retry counter if not exists
				if not spider_data.pickup_retry_count then
					spider_data.pickup_retry_count = 0
				end
				spider_data.pickup_retry_count = spider_data.pickup_retry_count + 1
				
				-- If we've retried too many times, abort
				if spider_data.pickup_retry_count > 5 then
					-- Too many retries, something is wrong - end journey
					journey.end_journey(unit_number, true)
					return
				end
				
				-- Retry by setting destination to provider again
				if provider and provider.valid then
					pathing.set_smart_destination(spider, provider.position, provider)
				else
					-- Provider is invalid, abort
					journey.end_journey(unit_number, true)
				end
				return
			end
			
			-- Successfully picked up, reset retry counter
			spider_data.pickup_retry_count = nil
			local end_tick = event.tick
			local total_ticks = end_tick - start_tick
			
			-- Update payload count - for routes, accumulate items from multiple pickups
			if spider_data.route and spider_data.current_route_index then
				-- In a route, accumulate items
				local current_stop = spider_data.route[spider_data.current_route_index]
				if current_stop then
					-- Update the stop with actual amount picked up
					current_stop.actual_amount = actually_inserted
					-- Accumulate total payload
					if not spider_data.route_payload then
						spider_data.route_payload = {}
					end
					spider_data.route_payload[item] = (spider_data.route_payload[item] or 0) + actually_inserted
					spider_data.payload_item_count = spider_data.route_payload[item] or 0
				end
			else
				-- Single pickup, update normally
				spider_data.payload_item_count = actually_inserted + already_had
			end
			
			-- Only proceed to next destination if we actually have items
			if spider_data.payload_item_count > 0 then
				-- Check if we got the full requested amount (for non-route pickups)
				-- If not, continue collecting from the same provider
				if not spider_data.route then
					-- Get the original requested amount (before pickup updated payload_item_count)
					local original_requested = item_count
					local current_has = spider.get_item_count(item) or 0
					
					if original_requested and current_has < original_requested then
						-- Didn't get full amount - check if we can get more
						local still_needed = original_requested - current_has
						local provider_still_has = provider_inventory and provider_inventory.get_item_count(item) or 0
						local spider_can_take_more = trunk and trunk.can_insert({name = item, count = 1}) or false
						
						if provider_still_has > 0 and spider_can_take_more and still_needed > 0 then
							-- Can get more - stay at provider and continue collecting
							-- Clear pickup_in_progress to allow next command_completed to process
							spider_data.pickup_in_progress = nil
							-- Stay at provider - next command_completed will trigger another pickup attempt
							pathing.set_smart_destination(spider, provider.position, provider)
							rendering.draw_status_text(spider, spider_data)
							return
						end
					end
				end
				
				-- IMPORTANT: Clear the current autopilot destination BEFORE setting a new one
				-- This prevents the spider from continuing to path to the provider and triggering more command_completed events
				if spider.autopilot_destinations and #spider.autopilot_destinations > 0 then
					spider.autopilot_destination = nil
				end
				
				-- NOW clear the pickup_in_progress flag - we're done with pickup and about to set new destination
				spider_data.pickup_in_progress = nil
				
				-- Check if spider has a route - if so, advance to next stop
				if spider_data.route and spider_data.current_route_index then
					local advanced = journey.advance_route(unit_number)
					if not advanced then
						-- Route complete or failed, journey already ended
						return
					end
				else
					-- No route, proceed with single pickup/delivery
					-- Set status to dropping_off and set destination to requester
					spider_data.status = constants.dropping_off
					
					-- Use pre-validated requester path if available (from dual-path validation)
					if spider_data.requester_path_waypoints and spider_data.requester_path_target then
						-- Apply pre-validated waypoints
						spider.autopilot_destination = nil
						
						local spider_pos = spider.position
						local min_distance = math.huge
						local start_index = 1
						
						for i, wp in ipairs(spider_data.requester_path_waypoints) do
							local pos = wp.position or wp
							local dist = math.sqrt((pos.x - spider_pos.x)^2 + (pos.y - spider_pos.y)^2)
							if dist < min_distance then
								min_distance = dist
								start_index = i
							end
						end
						
						local last_pos = spider_pos
						local min_spacing = (spider.prototype.height + 0.5) * 7.5
						
						for i = start_index + 1, #spider_data.requester_path_waypoints do
							local wp = spider_data.requester_path_waypoints[i].position or spider_data.requester_path_waypoints[i]
							local dist = math.sqrt((wp.x - last_pos.x)^2 + (wp.y - last_pos.y)^2)
							
							if dist > min_spacing then
								spider.add_autopilot_destination(wp)
								last_pos = wp
							end
						end
						
						local waypoint_count = #spider_data.requester_path_waypoints
						spider.add_autopilot_destination(spider_data.requester_path_target)
						
						-- Clean up stored path data
						spider_data.requester_path_waypoints = nil
						spider_data.requester_path_target = nil
						
						logging.info("Pickup", "Applied pre-validated requester path (" .. waypoint_count .. " waypoints)")
						-- Draw status text
						rendering.draw_status_text(spider, spider_data)
					else
						-- No pre-validated path (shouldn't happen with dual-path validation, but fallback)
						local pathing_success = pathing.set_smart_destination(spider, spider_data.requester_target.position, spider_data.requester_target)
						if not pathing_success then
							journey.end_journey(unit_number, true)
						else
							-- Draw status text
							rendering.draw_status_text(spider, spider_data)
						end
					end
				end
			else
				-- No items picked up, end journey
				spider_data.pickup_in_progress = nil
				journey.end_journey(unit_number, true)
			end
			
			-- Update allocated_items for provider chests
			-- Note: Robot chest support was removed in version 3.0.2
			if provider_data then
				local allocated_items = provider_data.allocated_items
				if allocated_items then
					allocated_items[item] = (allocated_items[item] or 0) - item_count
					if allocated_items[item] <= 0 then allocated_items[item] = nil end
				end
			end
		end  -- End of "if spider_data.status == constants.picking_up then" block
		
		-- Delivery logic (separate block, not part of the outer if/elseif chain)
		if spider_data.status == constants.dropping_off then
			-- Get item and item_count for delivery (they're not in scope here)
			local item = spider_data.payload_item
			local item_count = spider_data.payload_item_count
			
			-- Get requester - for routes, it comes from the route stop, otherwise from requester_target
			local requester = nil
			if spider_data.route and spider_data.current_route_index then
				local current_stop = spider_data.route[spider_data.current_route_index]
				if current_stop and current_stop.type == "delivery" and current_stop.entity then
					requester = current_stop.entity
				end
			end
			
			-- Fallback to requester_target if not from route
			if not requester then
				requester = spider_data.requester_target
			end
			
			if not requester or not requester.valid then
				journey.end_journey(unit_number, true)
				return
			end
			
			-- Get requester_data for delivery calculations
			local requester_data = storage.requesters[requester.unit_number]
			if not requester_data then
				journey.end_journey(unit_number, true)
				return
			end
			
			-- Verify spider is actually close enough to the requester
			local distance_to_requester = utils.distance(spider.position, requester.position)
			if distance_to_requester > 6 then
				-- Spider not close enough yet, wait for next command completion
				return
			end
			
			-- Clear any remaining autopilot destinations to ensure spider stops
			if spider.autopilot_destinations and #spider.autopilot_destinations > 0 then
				spider.autopilot_destination = nil
			end
			
			-- Handle delivery - check if this is a route with multi-item delivery
			local items_to_deliver = {}
			
			if spider_data.route and spider_data.current_route_index then
				local current_stop = spider_data.route[spider_data.current_route_index]
				if current_stop and current_stop.type == "delivery" then
					if current_stop.items then
						-- Multi-item delivery - deliver what spider has (up to route amount)
						-- Let requester.insert() handle capacity - don't limit to actual_need for routes
						for req_item, req_amount in pairs(current_stop.items) do
							local spider_has = spider.get_item_count(req_item)
							if spider_has > 0 then
								-- Deliver what spider has, up to the route amount
								-- requester.insert() will handle capacity limits
								items_to_deliver[req_item] = math.min(spider_has, req_amount)
							end
						end
					elseif current_stop.item then
						-- Single item delivery - deliver what spider has (up to route amount)
						-- Let requester.insert() handle capacity - don't limit to actual_need for routes
						local spider_item_count = spider.get_item_count(current_stop.item)
						if spider_item_count > 0 then
							local route_amount = current_stop.amount or spider_item_count
							items_to_deliver[current_stop.item] = math.min(spider_item_count, route_amount)
						end
					end
				end
			else
				-- Single delivery - deliver what spider has (up to item_count)
				-- Let requester.insert() handle capacity - don't limit to actual_need
				local spider_item_count = spider.get_item_count(item)
				if spider_item_count > 0 then
					-- Deliver what spider has, up to the assigned amount
					-- requester.insert() will handle capacity limits
					local deliver_amount = math.min(spider_item_count, item_count or spider_item_count)
					items_to_deliver[item] = deliver_amount
				end
			end
			
			-- Capture route_payload BEFORE delivery for success check
			local payload_before_delivery = {}
			if spider_data.route and spider_data.route_payload then
				for item_name, amount in pairs(spider_data.route_payload) do
					payload_before_delivery[item_name] = amount
				end
			end
			
			-- Deliver all items
			local total_delivered = 0
			for deliver_item, deliver_amount in pairs(items_to_deliver) do
				if deliver_amount > 0 then
					local can_insert_check = requester.can_insert(deliver_item)
					
					if can_insert_check then
						local actually_inserted = requester.insert{name = deliver_item, count = deliver_amount}
						
						if actually_inserted > 0 then
							local removed = spider.remove_item{name = deliver_item, count = actually_inserted}
							
							if removed > 0 then
								total_delivered = total_delivered + actually_inserted
								requester_data.dropoff_count = (requester_data.dropoff_count or 0) + actually_inserted
								
								-- Update incoming_items
								if not requester_data.incoming_items then
									requester_data.incoming_items = {}
								end
								requester_data.incoming_items[deliver_item] = (requester_data.incoming_items[deliver_item] or 0) - actually_inserted
								if requester_data.incoming_items[deliver_item] <= 0 then
									requester_data.incoming_items[deliver_item] = nil
								end
								
								-- Invalidate inventory cache since items were added to requester
								requester_data.cached_item_counts = nil
								requester_data.cache_tick = nil
								
								-- Update route payload if in route
								if spider_data.route and spider_data.route_payload then
									spider_data.route_payload[deliver_item] = (spider_data.route_payload[deliver_item] or 0) - actually_inserted
									if spider_data.route_payload[deliver_item] <= 0 then
										spider_data.route_payload[deliver_item] = nil
									end
								end
							end
						end
					end
				end
			end
			
			if total_delivered > 0 then
				rendering.draw_deposit_icon(requester)
			end
			
			-- Check if delivery was successful (items were removed from spider)
			local delivery_successful = false
			if spider_data.route and spider_data.current_route_index then
				-- For routes, check if we delivered what we intended
				local current_stop = spider_data.route[spider_data.current_route_index]
				if current_stop then
					if current_stop.items then
						-- Multi-item: check if we delivered at least some items
						delivery_successful = total_delivered > 0
					elseif current_stop.item then
						-- Single item: check if we have less of this item now
						-- Use payload_before_delivery which was captured BEFORE route_payload was decremented
						local remaining = spider.get_item_count(current_stop.item)
						local had_before = payload_before_delivery[current_stop.item] or 0
						delivery_successful = remaining < had_before or total_delivered > 0
					end
				end
			else
				-- Single delivery: check if items were removed
				local spider_item_count = spider.get_item_count(item) + total_delivered  -- What we had before delivery
				local remaining_spider_count = spider.get_item_count(item)
				delivery_successful = remaining_spider_count < spider_item_count or total_delivered > 0
			end
			
			if not delivery_successful and total_delivered == 0 then
				-- Delivery failed - retry
				if not spider_data.dropoff_retry_count then
					spider_data.dropoff_retry_count = 0
				end
				spider_data.dropoff_retry_count = spider_data.dropoff_retry_count + 1
				
				if spider_data.dropoff_retry_count > 5 then
					journey.end_journey(unit_number, true)
					return
				end
				
				if requester and requester.valid then
					pathing.set_smart_destination(spider, requester.position, requester)
					-- Draw status text
					rendering.draw_status_text(spider, spider_data)
				else
					journey.end_journey(unit_number, true)
				end
				return
			end
			
			-- Successfully dropped off, reset retry counter
			spider_data.dropoff_retry_count = nil
			
			
			-- Check if spider has a route - if so, advance to next stop
			if spider_data.route and spider_data.current_route_index then
				local advanced = journey.advance_route(unit_number)
				if not advanced then
					-- Route complete or failed, journey already ended
					return
				end
			else
				-- No route, end journey normally
				journey.end_journey(unit_number, true)
				journey.deposit_already_had(spider_data)
			end
		elseif spider_data.status == constants.dumping_items then
			-- Handle dumping items to storage chest
			local dump_target = spider_data.dump_target
			if not dump_target or not dump_target.valid then
				-- No valid dump target, try to find one
				local dump_success = journey.attempt_dump_items(unit_number)
				-- If attempt_dump_items failed and still no dump_target, end journey and set idle
				if not dump_success and (not spider_data.dump_target or not spider_data.dump_target.valid) then
					-- No storage chests available - end journey and set to idle
					spider_data.dump_target = nil
					journey.end_journey(unit_number, true)
				end
				return
			end
			
			-- Check if spider is close enough to dump target
			local distance_to_dump = utils.distance(spider.position, dump_target.position)
			
			if distance_to_dump > 6 then
				-- Not close enough yet, wait for next command completion
				return
			end
			
			-- Clear any remaining autopilot destinations to ensure spider stops
			if spider.autopilot_destinations and #spider.autopilot_destinations > 0 then
				spider.autopilot_destination = nil
			end
			
			-- Get spidertron's logistic requests to avoid dumping requested items
			local logistic_requests = utils.get_spider_logistic_requests(spider)
			
			-- Try to dump items
			local trunk = spider.get_inventory(defines.inventory.spider_trunk)
			if not trunk then
				journey.end_journey(unit_number, true)
				return
			end
			
			local contents = trunk.get_contents()
			if not contents or next(contents) == nil then
				-- No items left, done dumping
				spider_data.dump_target = nil
				journey.end_journey(unit_number, true)
				return
			end
			
			-- Try to insert items into storage chest
			local dumped_any = false
			for item_name, item_data in pairs(contents) do
				-- Handle new format
				local actual_item_name = item_name
				local item_count = 0
				
				if type(item_data) == "table" and item_data.name then
					actual_item_name = item_data.name
					item_count = item_data.count or 0
				elseif type(item_data) == "number" then
					item_count = item_data
				elseif type(item_data) == "table" then
					for quality, qty in pairs(item_data) do
						if type(qty) == "number" then
							item_count = item_count + qty
						end
					end
				end
				
				if not actual_item_name or actual_item_name == "" or item_count <= 0 then
					goto next_dump_item
				end
				
				-- Get how many items the spider actually has
				local spider_has = spider.get_item_count(actual_item_name)
				if spider_has > item_count then spider_has = item_count end
				
				-- Check if this item is requested
				local requested_count = logistic_requests[actual_item_name] or 0
				if requested_count > 0 then
					-- Only dump excess
					if spider_has <= requested_count then
						goto next_dump_item
					else
						spider_has = spider_has - requested_count
						if spider_has <= 0 then
							goto next_dump_item
						end
					end
				end
				
				if spider_has > 0 then
					local inserted = dump_target.insert{name = actual_item_name, count = spider_has}
					
					if inserted > 0 then
						local removed = spider.remove_item{name = actual_item_name, count = inserted}
						if removed > 0 then
							dumped_any = true
						end
					end
				end
				::next_dump_item::
			end
			
			if dumped_any then
				-- Check if there are more dumpable items
				local remaining_contents = trunk.get_contents()
				if not remaining_contents or next(remaining_contents) == nil then
					-- All items dumped
					spider_data.dump_target = nil
					journey.end_journey(unit_number, true)
					return
				end
				
				-- Check if remaining items are dumpable
				local has_more_dumpable = false
				
				for item_name, item_data in pairs(remaining_contents) do
					local actual_item_name = item_name
					local item_count = 0
					
					if type(item_data) == "table" and item_data.name then
						actual_item_name = item_data.name
						item_count = item_data.count or 0
					elseif type(item_data) == "number" then
						item_count = item_data
					elseif type(item_data) == "table" then
						for quality, qty in pairs(item_data) do
							if type(qty) == "number" then
								item_count = item_count + qty
							end
						end
					end
					
					if item_count > 0 and actual_item_name and actual_item_name ~= "" then
						local requested = logistic_requests[actual_item_name] or 0
						local total = spider.get_item_count(actual_item_name)
						if requested == 0 or total > requested then
							has_more_dumpable = true
							break
						end
					end
				end
				
				if has_more_dumpable then
					-- Find another chest
					spider_data.dump_target = nil
					local dump_success = journey.attempt_dump_items(unit_number)
					-- If attempt_dump_items failed and still no dump_target, end journey and set idle
					if not dump_success and (not spider_data.dump_target or not spider_data.dump_target.valid) then
						-- No storage chests available - end journey and set to idle
						spider_data.dump_target = nil
						journey.end_journey(unit_number, true)
					end
				else
					-- Done dumping
					spider_data.dump_target = nil
					journey.end_journey(unit_number, true)
				end
			else
				-- Couldn't dump anything
				spider_data.dump_target = nil
				local dump_success = journey.attempt_dump_items(unit_number)
				-- If attempt_dump_items failed and still no dump_target, end journey and set idle
				if not dump_success and (not spider_data.dump_target or not spider_data.dump_target.valid) then
					-- No storage chests available - end journey and set to idle
					spider_data.dump_target = nil
					journey.end_journey(unit_number, true)
				end
			end
		end
	end)
end

return events_spider

