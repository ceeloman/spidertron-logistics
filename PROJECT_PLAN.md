# Spidertron Logistics System Refactor - Project Plan

## Overview
Major refactor to remove force-based connectivity, implement beacon-to-chest assignment (unlimited range), improve pathing with water/cliff/enemy awareness, remove equipment requirement, add GUI controls, support multi-item requests, and modularize code.

## Key Changes

### 1. Remove Force System - ✅ COMPLETED
- ✅ Remove `spidertron_network_force()` and force switching logic
- ✅ Remove force-related event handlers (cursor stack, planner tracking)
- ✅ Beacons are custom entity type (radar) to avoid logistic network interference
- ✅ Custom beacon entity serves as connectivity marker without roboport functionality

### 2. Beacon-Chest Assignment System (Unlimited Range) - ✅ COMPLETED
- ✅ On beacon placement: scan ALL provider/requester chests on surface, assign to this beacon
- ✅ On chest placement: find ALL beacons on surface, assign to nearest
- ✅ NO range limit - every chest gets a beacon owner regardless of distance
- ✅ Each chest tracks: `pickup_count`, `dropoff_count` (total counts, not per item)
- ✅ Beacon reads chest statistics for future home assignment features
- ✅ Recalculate assignments when beacons/chests are removed

### 3. Remove Equipment Requirement - ✅ COMPLETED
- ✅ Remove `spidertron-logistic-controller` equipment entirely
- ✅ Remove equipment category registration from data-final-fixes.lua
- ✅ Remove `count_controllers()` and related logic
- ✅ Spiders activate via GUI toggle instead of equipment presence
- ✅ Remove movement bonus/hinder logic

### 4. GUI Activation Toggle - ✅ COMPLETED
- ✅ Add toggle button to spidertron equipment GUI
- ✅ Store activation state in spider data: `active = true/false`
- ✅ Only active spiders participate in logistics tasks
- ✅ Toggle persists across saves

### 5. Multi-Item Request Support - ✅ COMPLETED
- ✅ Expand requester chest to support multiple item types
- ✅ Update GUI to allow adding/removing multiple item requests
- ✅ Update storage structure: `requested_items = {[item_name] = count, ...}`
- ✅ Update task assignment logic to handle multiple items per requester

### 6. Pathing Improvements - ✅ COMPLETED
- ✅ **Water Detection**: Check spider prototype collision mask for water tiles
  - If collides with water: path only on land tiles
  - If doesn't collide: can path over water
- ✅ **Cliff Detection**: Check spider size/collision mask
  - If spider size < threshold: collides with cliffs, avoid cliff paths
  - Larger spiders can cross cliffs
- ✅ **Enemy Avoidance**: Detect enemy entities along path, prefer routes avoiding them
- ✅ **Unit Selection**: Prefer larger units for longer distances or bigger cargos
- ✅ **Waypoint System**: Multi-waypoint pathing with simplification and smoothing implemented

### 7. Multi-Pickup and Multi-Delivery Optimization (TODO)
- **Route-Based Opportunistic Job Assignment**:
  - Spiders pick up and deliver items that are "on the route" as they travel
  - Example: Pick up iron plates → pick up copper plates → deliver iron to two chests → 
    pick up more copper (nearby, on route) → pick up steel → deliver steel → deliver copper
  - Jobs are dynamically added to the route if they're along the way to current destination
  - Key concept: **Jobs are on the route, not queued sequentially**
  - Route is built up opportunistically: if a job is "on the way", add it to the route
  - Not about queuing job after job - it's about jobs being on the route
- **Multi-Pickup for Single Delivery**: 
  - If requester needs 500 pipes, and Provider A has 200 and Provider B has 300
  - One spider should pick up from BOTH providers before delivering to requester
  - Only if it's faster than assigning two separate spiders
  - Optimize route: visit Provider A, then Provider B, then Requester
  - Calculate if combined route is faster than parallel spider assignments
- **Multi-Pickup for Multiple Items**:
  - If Requester A is requesting two different items (e.g., pipes and gears)
  - If it's quicker for one spider to pick up both items before going to requester
  - Visit Provider A (pipes), then Provider B (gears), then Requester A
  - Compare total travel time vs assigning two spiders
- **Multi-Delivery from Single Pickup**:
  - If spider picks up items from one provider
  - And multiple requesters in similar locations need those items
  - Deliver to all nearby requesters in one journey (like similar postcodes)
  - Optimize delivery route to minimize travel distance between requesters
- **Opportunistic Pickups Along Route**:
  - If spider is going to deliver iron plates to a location
  - And there are copper plates nearby that are needed
  - Spider can grab copper plates "on the way" (opportunistic pickup)
  - Then continue to deliver iron, and later deliver copper when it's on route
  - Route is dynamically updated as new opportunities arise
- **Mixed Pickup and Delivery Routes**:
  - Pick up from Provider A and Provider B (if they're close together)
  - Deliver to Requester C, then pick up more items nearby (opportunistic)
  - Deliver to Requester D, then pick up steel nearby
  - Deliver steel, then deliver remaining items
  - Route is optimized to minimize total travel time
- **Route Planning Logic**:
  - Calculate optimal order of stops (pickups and deliveries mixed based on route)
  - Consider inventory capacity constraints
  - Compare single-spider multi-stop route vs multiple-spider parallel routes
  - Choose faster option: one spider doing multiple stops OR multiple spiders doing single stops
  - Dynamically add stops to route if they're "on the way" to current destination
  - Re-optimize route when new jobs become available along the current route
  - Key concept: **Jobs are on the route, not queued sequentially**
  - Re-optimize route when new jobs become available along the current route

### 8. Code Modularization - ✅ COMPLETED
- ✅ **Data Stage**: Split into modules:
  - ✅ `data/items.lua` - Item definitions
  - ✅ `data/entities.lua` - Entity definitions (chests, beacon)
  - ✅ `data/recipes.lua` - Recipe definitions
  - ✅ `data/technology.lua` - Technology definition
- ✅ **Control Stage**: Split into modules (using lib/ structure):
  - ✅ `lib/beacon_assignment.lua` - Beacon registration and assignment logic
  - ✅ `lib/registration.lua` - Chest and spider registration
  - ✅ `lib/logistics.lua` - Spider assignment and logistics coordination
  - ✅ `lib/pathing.lua` - Pathfinding and waypoint logic
  - ✅ `lib/gui.lua` - GUI handling (requester chest multi-item, spider activation)
  - ✅ `lib/journey.lua` - Journey and status management
  - ✅ `lib/rendering.lua` - Visual rendering
  - ✅ `lib/utils.lua` - Utility functions
  - ✅ `lib/terrain.lua` - Terrain detection
  - ✅ `lib/logging.lua` - Logging system

### 9. Chest Size Update
- ✅ Update collision/selection boxes from 3x3 to 1x1 - COMPLETED
- ✅ Updated to: collision_box = {{-0.35, -0.35}, {0.35, 0.35}}, selection_box = {{-0.5, -0.5}, {0.5, 0.5}}
- ✅ Applied to both provider and requester chests

## Implementation Order

### Phase 1: Core Refactor (✅ COMPLETED)
1. ✅ **Modularize Data Stage** - Split data.lua into modules - COMPLETED
2. ✅ **Remove Force System** - Delete force switching logic - COMPLETED
3. ✅ **Create Custom Beacon Entity** - Using radar type (as chosen) - COMPLETED
4. ✅ **Beacon-Chest Assignment** - Implement unlimited range assignment system - COMPLETED
5. ✅ **Chest Tracking** - Add pickup/dropoff counters - COMPLETED
6. ✅ **Remove Equipment** - Delete controller equipment and related code - COMPLETED
7. ✅ **GUI Activation Toggle** - Add spider activation button - COMPLETED
8. ✅ **Multi-Item Requests** - Expand requester chest GUI and logic - COMPLETED (with blueprint fix)
9. ✅ **Pathing Improvements** - Water, cliff, and enemy awareness - COMPLETED
10. ✅ **Modularize Control Stage** - Split control.lua into modules - COMPLETED

### Phase 2: Advanced Logistics (TODO)
11. **Multi-Pickup and Multi-Delivery** - Implement Uber-style multi-stop routes
12. **Beacon Waiting and Return Logic** - Smart return behavior and job assignment while returning
13. **Spider Availability System** - Real-time availability updates and dynamic rerouting
14. **Popular Pickup Location System** - Reroute spiders to high-traffic areas

## Storage Structure Changes

### Current Storage
```lua
storage.spiders = {} -- {unit_number = {entity, status, requester_target, provider_target, payload_item, payload_item_count}}
storage.requesters = {} -- {unit_number = {entity, requested_item, request_size, incoming_items}}
storage.providers = {} -- {unit_number = {entity, allocated_items}}
storage.beacons = {} -- {unit_number = beacon_entity}
```

### New Storage
```lua
storage.spiders = {} -- {unit_number = {entity, status, active, requester_target, provider_target, payload_item, payload_item_count}}
storage.requesters = {} -- {unit_number = {entity, requested_items = {[item] = count}, incoming_items = {[item] = count}, pickup_count, dropoff_count, beacon_owner}}
storage.providers = {} -- {unit_number = {entity, allocated_items = {[item] = count}, pickup_count, dropoff_count, beacon_owner}}
storage.beacons = {} -- {unit_number = {entity, assigned_chests = {requester_unit_numbers, provider_unit_numbers}}}
storage.beacon_assignments = {} -- {chest_unit_number = beacon_unit_number}
```

## File Structure

```
spidertron-logistics/
├── data/
│   ├── items.lua
│   ├── entities.lua
│   ├── recipes.lua
│   └── technology.lua
├── control/
│   ├── beacons.lua
│   ├── chests.lua
│   ├── spiders.lua
│   ├── pathing.lua
│   ├── gui.lua
│   ├── storage.lua
│   └── main.lua
├── data.lua (requires all data modules)
├── control.lua (requires all control modules)
├── data-final-fixes.lua
├── circuit-connections.lua
├── settings.lua
└── info.json
```

## Notes
- **NO backward compatibility needed** - mod is new to 2.0 and unreleased
- Debug prints can be removed after testing
- Waypoint pathing, graphics updates, and multi-delivery optimization deferred for later phases
- Beacon GUI for delivery tracking deferred for later

## Completed Pre-Refactor Changes

### Chest Size Update (1x1) - ✅ COMPLETED
- Updated collision boxes from 3x3 to 1x1: `{{-0.35, -0.35}, {0.35, 0.35}}`
- Updated selection boxes: `{{-0.5, -0.5}, {0.5, 0.5}}`
- Applied to both provider and requester chests in data.lua

### Beacon Updates - ✅ COMPLETED
- Updated `logistics_connection_distance` to 10000 (unlimited range for surface-wide connectivity)
- Beacon still uses roboport type (will be converted to custom entity in refactor)

### Utility Functions - ✅ COMPLETED
- Created `lib/terrain.lua` with terrain detection functions (water, cliffs)
- Created `lib/pathing.lua` with smart pathfinding that integrates terrain awareness
- Pathfinding now checks:
  - Spider collision mask for water traversal capability
  - Spider size for cliff crossing capability
  - Water tiles along path and adjusts destination if needed
  - Cliff corners near destination and finds alternatives
  - Enemy entities along path (detection implemented, can be enhanced)
- All `add_autopilot_destination()` calls replaced with `pathing.set_smart_destination()`

### Multi-Item Requests - ✅ COMPLETED
- Requester chest GUI supports up to 10 item slots
- Storage uses `requested_items = {[item_name] = count, ...}` format
- Blueprint saving/loading updated to support multi-item format
- Legacy single-item format still supported for backward compatibility

## Future Enhancements

### 8. Beacon Waiting and Return Logic (TODO)
- **Return to Beacon After Job**: 
  - Current: Spiders return to beacon after completing delivery (via `find_beacon` parameter)
  - Question: Should spiders always return to beacon, or can they wait at delivery location?
  - Option A: Always return to beacon (current behavior)
  - Option B: Wait at last delivery location if nearby requests are likely
  - Option C: Return to beacon only if no nearby jobs available
- **Job Assignment While Returning**:
  - Allow spiders to be assigned new jobs while returning to beacon
  - If spider is en route to beacon but a closer job becomes available, reroute
  - Cancel beacon return path and assign new job immediately
  - Track spider's "intended destination" (beacon vs job target)
- **Beacon Waiting Zones**:
  - Define waiting areas around beacons where spiders idle
  - Spiders wait at beacon until assigned a job
  - Consider beacon as "home base" for spider assignment
  - Track which spiders are "at beacon" vs "returning to beacon" vs "on job"

### 9. Spider Availability System (TODO)
- **Availability Updates**:
  - Send update/notification when spider becomes available (completes job)
  - Trigger immediate job assignment check when spider becomes idle
  - Don't wait for next update cycle - check for jobs immediately
  - Maintain "available spiders" queue that updates in real-time
- **Dynamic Rerouting**:
  - If next available spider is far away and coming back to do a delivery
  - But a closer spider becomes available (completes job or returns to beacon)
  - The closer spider can take the job instead
  - Reroute the far away spider to a popular pickup location (if configured)
  - Prevent unnecessary long-distance assignments when closer options exist
- **Proximity-Based Assignment**:
  - When assigning jobs, check if any spider is closer than currently assigned spider
  - If closer spider becomes available, reassign job to closer spider
  - Cancel previous assignment and update spider status
  - Track "pending assignments" that can be cancelled if better option appears

### 10. Popular Pickup Location System (TODO)
- **Identify High-Traffic Providers**:
  - Track which provider chests are frequently accessed
  - Calculate "popularity" based on pickup_count and request frequency
  - Maintain list of popular pickup locations per beacon network
- **Reroute to Popular Locations**:
  - When spider's job is reassigned to closer spider, reroute original spider
  - Send original spider to popular pickup location to wait for next job
  - Reduces idle time and positions spiders near likely job sources
  - Only reroute if spider is far from beacon and no immediate jobs available

### 11. Active Provider Chest for Failed Deliveries (TODO)
- Create a custom "spidertron-active-provider-chest" entity
- When deliveries fail, spiders dump items into this chest
- Bots can then sort items from the active provider chest to appropriate storage
- This provides a fallback when storage chests can't be found or used
- Implementation deferred - current system uses storage chests directly

