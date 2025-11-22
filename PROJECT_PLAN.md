# Spidertron Logistics System Refactor - Project Plan

## Overview
Major refactor to remove force-based connectivity, implement beacon-to-chest assignment (unlimited range), improve pathing with water/cliff/enemy awareness, remove equipment requirement, add GUI controls, support multi-item requests, and modularize code.

## Key Changes

### 1. Remove Force System
- Remove `spidertron_network_force()` and force switching logic
- Remove force-related event handlers (cursor stack, planner tracking)
- Beacons will be custom entity type (not roboport) to avoid logistic network interference
- Custom beacon entity serves as connectivity marker without roboport functionality

### 2. Beacon-Chest Assignment System (Unlimited Range)
- On beacon placement: scan ALL provider/requester chests on surface, assign to this beacon
- On chest placement: find ALL beacons on surface, assign to nearest (or allow multiple?)
- NO range limit - every chest gets a beacon owner regardless of distance
- Each chest tracks: `pickup_count`, `dropoff_count` (total counts, not per item)
- Beacon reads chest statistics for future home assignment features
- Recalculate assignments when beacons/chests are removed

### 3. Remove Equipment Requirement
- Remove `spidertron-logistic-controller` equipment entirely
- Remove equipment category registration from data-final-fixes.lua
- Remove `count_controllers()` and related logic
- Spiders activate via GUI toggle instead of equipment presence
- Remove movement bonus/hinder logic

### 4. GUI Activation Toggle
- Add toggle button to spidertron equipment GUI
- Store activation state in spider data: `active = true/false`
- Only active spiders participate in logistics tasks
- Toggle persists across saves

### 5. Multi-Item Request Support
- Expand requester chest to support multiple item types
- Update GUI to allow adding/removing multiple item requests
- Update storage structure: `requested_items = {[item_name] = count, ...}`
- Update task assignment logic to handle multiple items per requester

### 6. Pathing Improvements
- **Water Detection**: Check spider prototype collision mask for water tiles
  - If collides with water: path only on land tiles
  - If doesn't collide: can path over water
- **Cliff Detection**: Check spider size/collision mask
  - If spider size < threshold: collides with cliffs, avoid cliff paths
  - Larger spiders can cross cliffs
- **Enemy Avoidance**: Detect enemy entities along path, prefer routes avoiding them
- **Unit Selection**: Prefer larger units for longer distances or bigger cargos
- **Waypoint System**: Prepare structure for multi-waypoint pathing (implementation deferred)

### 7. Multi-Delivery Optimization (Future Enhancement)
- Allow spider to pick up multiple items and complete multiple deliveries in one trip
- Requires path optimization and cargo management
- Deferred for later implementation

### 8. Code Modularization
- **Data Stage**: Split into modules:
  - `data/items.lua` - Item definitions
  - `data/entities.lua` - Entity definitions (chests, beacon)
  - `data/recipes.lua` - Recipe definitions
  - `data/technology.lua` - Technology definition
- **Control Stage**: Split into modules:
  - `control/beacons.lua` - Beacon registration and assignment logic
  - `control/chests.lua` - Chest registration, tracking, and assignment
  - `control/spiders.lua` - Spider registration, activation, and task assignment
  - `control/pathing.lua` - Pathfinding and waypoint logic
  - `control/gui.lua` - GUI handling (requester chest multi-item, spider activation)
  - `control/storage.lua` - Storage initialization
  - `control/main.lua` - Event handlers and main loop

### 9. Chest Size Update
- ✅ Update collision/selection boxes from 3x3 to 1x1 - COMPLETED
- ✅ Updated to: collision_box = {{-0.35, -0.35}, {0.35, 0.35}}, selection_box = {{-0.5, -0.5}, {0.5, 0.5}}
- ✅ Applied to both provider and requester chests

## Implementation Order

1. **Modularize Data Stage** - Split data.lua into modules
2. **Remove Force System** - Delete force switching logic
3. **Create Custom Beacon Entity** - Replace roboport with simple entity
4. **Beacon-Chest Assignment** - Implement unlimited range assignment system
5. **Chest Tracking** - Add pickup/dropoff counters
6. **Remove Equipment** - Delete controller equipment and related code
7. **GUI Activation Toggle** - Add spider activation button
8. **Multi-Item Requests** - Expand requester chest GUI and logic
9. **Pathing Improvements** - Water, cliff, and enemy awareness
10. **Modularize Control Stage** - Split control.lua into modules

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
- Created `utils.lua` with pathfinding, water detection, and cliff detection functions
- Functions organized and annotated for integration into refactor
- See `utils.lua` for available pathfinding utilities including:
  - `is_position_on_water()` - Water tile detection
  - `is_position_near_corner_cliff()` - Cliff corner detection
  - `is_waypoint_parallel_to_cliff()` - Path-cliff alignment detection
  - `is_waypoint_crossing_straight_cliff()` - Straight cliff crossing detection
  - `request_multiple_paths()` - Multi-waypoint pathfinding support
  - Various utility functions for chunk operations and distance calculations

