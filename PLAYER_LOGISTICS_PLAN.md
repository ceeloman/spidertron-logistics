# Player Logistics Requests Feature Plan

## Overview
Add functionality for spiders to automatically fill player character logistics requests when logistic robots are unavailable (available_logistic_robots <= 0). Include a force button in the character inventory GUI to manually trigger spider delivery. Process player requests less frequently (every 1200 ticks / 20 seconds) and spread the work across multiple ticks.

## Requirements

### Core Functionality
- Spiders fill player logistics requests when logistic robots are unavailable
- Check `available_logistic_robots <= 0` in player's current network
- Handle players outside roboport logistic zones
- Process requests less frequently than regular requester chests (every 20 seconds)
- Spread processing across multiple ticks (don't do everything in 1 tick)
- Support dummy engineers (players without characters)

### Pathing & Delivery
- **Continuous pathing updates**: Player moves, so update spider destinations regularly
- Update pathing every 60 ticks (1 second) or when player moves >2 tiles
- **Following behavior**: If player inventory is full when spider arrives, spider follows player until items can be delivered
- Check player inventory capacity before attempting transfer
- Keep spider in "dropping_off" status while following

### Force Button
- Button anchored to character inventory GUI (same style as spidertron GUI)
- Only assign if spiders are available (ignore robot availability check)
- Button triggers immediate spider assignment
- Only visible when character exists and has logistic requests enabled

## Implementation Details

### 1. Player Request Processing System
- **Location**: `lib/logistics.lua` - Add new function `logistics.player_requesters()`
- **Frequency**: Check every 1200 ticks (20 seconds) via `on_nth_tick(1200)`
- **Processing**: Spread work across multiple ticks (process 1-2 players per tick to avoid lag)
- **Conditions**: 
  - Only process if `character_logistic_requests == true`
  - Only assign spiders if `available_logistic_robots <= 0` in player's network
  - Check correct surface (player.character.surface)
  - Handle dummy engineers (players without characters)

### 2. Network Detection
- **Location**: `lib/logistics.lua` - Helper function to find player's logistic network
- Use `player.character.logistic_network` if available
- Fallback to `find_logistic_network_by_position(player.character.position, player.character.surface)`
- Check `available_logistic_robots` from the network
- Handle cases where player has no network (outside roboport range)

### 3. Request Extraction
- **Location**: `lib/logistics.lua` - Extract requests from `player.character.logistic_sections`
- Iterate through `logistic_sections.sections` to get all request filters
- Use `section.filters` to get requested items and counts
- Build request list similar to requester chest format
- Track player requests separately from requester chests
- Cache requests to avoid frequent API calls

### 4. Spider Assignment
- **Location**: `lib/logistics.lua` - Reuse existing `assign_spider()` function or create player-specific version
- Create temporary requester data structure for player
- Find available spiders on same surface/network
- Assign spiders to deliver items to player character position
- **Special handling for player deliveries**:
  - Mark delivery as "player_target" type in spider_data
  - Store player reference (not just position) for continuous updates
  - Store player character reference for inventory access
  - Handle delivery similar to requester chests but with dynamic target

### 5. Distributed Processing
- **Location**: `control.lua` - New `on_nth_tick(1200)` handler
- Process players in batches (1-2 per tick)
- Track processing state in `storage.player_request_processing`
- Store current player index and continue on next tick
- Skip players without characters or logistic requests enabled

### 6. Continuous Pathing Updates
- **Location**: `control.lua` - In main `on_tick` handler
- Check all spiders with `player_target` status
- Update pathing destination to current player position every 60 ticks (1 second)
- Only update if player has moved significantly (e.g., > 2 tiles)
- Use `pathing.set_smart_destination()` to update spider's target
- Validate player and character still exist before updating
- Handle surface changes (player switches surfaces)

### 7. Following Behavior
- **Location**: `lib/journey.lua` - Modify delivery completion logic
- When spider reaches player position (within delivery range, e.g., 6 tiles):
  - Attempt to transfer items to player character inventory
  - Check if player inventory has space for requested items
  - If player inventory is full for requested items:
    - Keep spider in "dropping_off" status
    - Set flag `following_player = true` in spider_data
    - Don't end journey - continue following
    - Continue updating pathing to player position
  - If items successfully transferred or player no longer needs them:
    - End journey normally
    - Clear following flag
- Check player inventory capacity before attempting transfer
- Re-check every few ticks (e.g., every 30 ticks) if following

### 8. Force Button GUI
- **Location**: `lib/gui.lua` - Add character GUI button
- **Anchor**: `defines.relative_gui_type.character_gui` with position `right`
- **Style**: Match spidertron GUI style (frame with inside_shallow_frame)
- **Button**: Sprite button to trigger immediate spider assignment
- **Behavior**: Ignore robot availability check, only check spider availability
- **Visibility**: Only show when character exists and has logistic requests enabled

### 9. Shared Toolbar Extension
- **Location**: `ceelos-vehicle-gui-util/lib/shared_toolbar.lua`
- Add support for `defines.relative_gui_type.character_gui`
- Extend `get_or_create_shared_toolbar()` to handle character GUI
- Register button for character GUI type
- Use same button registration system as vehicle toolbars

### 10. Button Click Handler
- **Location**: `control.lua` - Handle button click event
- Check if player has character and logistic requests enabled
- Immediately process player requests (bypass robot check)
- Assign spiders if available
- Use same assignment logic as regular processing but skip robot availability check

### 11. Storage Structure
Add to `storage`:
- `player_request_processing` - Track distributed processing state
  - `current_player_index` - Current player being processed
  - `players_to_process` - List of players to process
  - `last_processed_tick` - Last tick when processing occurred
- `player_requests_cache` - Cache player requests to avoid frequent API calls
  - Key: player_index
  - Value: {requests, last_updated_tick}

### 12. Spider Data Extensions
Add to `spider_data`:
- `player_target` - Boolean flag indicating this is a player delivery
- `target_player_index` - Index of target player
- `target_player` - Reference to player entity (for pathing updates)
- `target_character` - Reference to character entity (for inventory access)
- `following_player` - Boolean flag indicating spider is following player
- `last_pathing_update_tick` - Last tick when pathing was updated
- `last_player_position` - Last known player position (for movement detection)

## Files to Modify

1. **control.lua**
   - Add `on_nth_tick(1200)` handler for player request processing
   - Add button click handler for force button
   - Add pathing update logic in main `on_tick` handler
   - Handle player reference cleanup when player disconnects

2. **lib/logistics.lua**
   - Add `player_requesters()` function
   - Add network detection helper function
   - Add request extraction from character.logistic_sections
   - Modify or extend `assign_spider()` for player targets

3. **lib/journey.lua**
   - Modify delivery completion logic for player targets
   - Add following behavior when player inventory is full
   - Handle continuous delivery attempts while following

4. **lib/gui.lua**
   - Add character GUI button creation/management
   - Handle button visibility based on character and logistic requests
   - Clean up button when character is removed

5. **ceelos-vehicle-gui-util/lib/shared_toolbar.lua**
   - Add character GUI support to `get_or_create_shared_toolbar()`
   - Extend button registration to support character GUI type

6. **lib/constants.lua**
   - Add `player_request_check_interval = 1200` (20 seconds)
   - Add `player_request_batch_size = 2` (players per tick)
   - Add `player_pathing_update_interval = 60` (1 second)
   - Add `player_following_check_interval = 30` (0.5 seconds)
   - Add `player_movement_threshold = 2.0` (tiles)

## Key Considerations

### Performance
- Process 1-2 players per tick to avoid lag spikes
- Cache player requests to minimize API calls
- Limit pathing updates to reasonable frequency
- Clean up invalid player references promptly

### Safety & Validation
- Always check player.character.surface matches spider surface
- Validate player and character still exist before operations
- Handle cases where player has no network or is outside roboport range
- Support dummy engineers (players without characters)
- Handle player disconnection gracefully

### GUI
- Button visibility: Only show when character exists and has logistic requests enabled
- Match existing spidertron GUI style for consistency
- Clean up GUI elements when character is removed

### Pathing & Delivery
- Update spider destinations continuously for moving players
- Only update when player has moved significantly to reduce pathfinding calls
- Spiders follow players when inventory is full
- Check delivery possibility regularly while following
- Handle surface changes (player switches surfaces)

### Edge Cases
- Player dies (character removed)
- Player switches characters
- Player changes surfaces
- Player disconnects
- Player inventory full for extended period
- Spider destroyed while following player
- Network becomes available (robots can now deliver)

## API References

### Player Character Logistics
- `player.character.character_logistic_requests` - Boolean, true if requests enabled
- `player.character.logistic_network` - LuaLogisticNetwork or nil
- `player.character.logistic_sections` - LuaLogisticSections
- `logistic_sections.sections` - Array of LuaLogisticSection
- `section.filters` - Array of LogisticFilter
- `filter.name` - Item name
- `filter.count` - Requested count
- `filter.index` - Filter index

### Network Detection
- `find_logistic_network_by_position(position, surface)` - Find network at position
- `network.available_logistic_robots` - Number of available robots
- `network.all_logistic_robots` - Total robots in network

### Character Inventory
- `character.get_inventory(defines.inventory.character_main)` - Main inventory
- `inventory.can_insert({name = item, count = count})` - Check if can insert
- `inventory.insert({name = item, count = count})` - Insert items

### GUI Anchoring
- `defines.relative_gui_type.character_gui` - Character inventory GUI
- `defines.relative_gui_position.right` - Right side position

## Testing Checklist

- [ ] Player requests processed when robots unavailable
- [ ] Player requests NOT processed when robots available
- [ ] Force button triggers immediate assignment
- [ ] Force button ignores robot availability
- [ ] Pathing updates as player moves
- [ ] Spider follows player when inventory full
- [ ] Items delivered when inventory space available
- [ ] Dummy engineers supported
- [ ] Surface changes handled correctly
- [ ] Player disconnection handled gracefully
- [ ] Button appears/disappears correctly
- [ ] Processing spread across multiple ticks
- [ ] No performance issues with multiple players

