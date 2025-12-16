# Remove All pcall Usages and Fix API References - Project Plan

## Overview
Remove all 35 `pcall` usages, eliminate glib and FilterHelper dependencies, fix deprecated `game.*_prototypes` references to use `prototypes.*` API, and replace with proper Factorio 2.0+ API patterns.

## Critical API Changes (Factorio 2.0+)
- `game.item_prototypes` → `prototypes.item["item-name"]`
- `game.entity_prototypes` → `prototypes.entity["entity-name"]`
- All prototype access must use `prototypes` table, not `game.*_prototypes`
- `game.players`, `game.get_player()`, `game.tick`, `game.surfaces` are still valid

## Files to Modify

### 1. lib/setup.lua
**Changes:**
- Line 34: Remove `pcall(function() return game.item_prototypes end)`
- Line 44: Replace `game.item_prototypes[item_name]` with `prototypes.item[item_name]`
- Remove pcall wrapper, use direct access with nil check

**Before:**
```lua
local success, _ = pcall(function() return game.item_prototypes end)
can_check_prototypes = success
...
local item_prototype = game.item_prototypes[item_name]
```

**After:**
```lua
-- Remove pcall check entirely
...
local item_prototype = prototypes.item[item_name]
if item_prototype then
    -- Item exists
end
```

### 2. lib/gui.lua
**Changes:**
- Line 6: Remove `local glib = require("__glib__/glib")`
- Lines 931, 954, 990, 1013, 1050, 1074: Replace all `glib.add()` calls with native GUI API
- Remove all pcall wrappers around button creation
- Add proper existence checks before button creation

**Context:** Creates toolbar buttons in shared toolbar (from ceelos-vehicle-gui-util) when opening spidertron GUI

**Before:**
```lua
local glib = require("__glib__/glib")
...
local success, remote_button = pcall(function()
    return glib.add(button_flow, {
        args = {
            type = "sprite-button",
            name = remote_name,
            style = "slot_sized_button",
            sprite = "item/spidertron-remote",
            tooltip = {"gui.spidertron-remote-tooltip"}
        },
        ref = "remote"
    }, {})
end)
```

**After:**
```lua
-- Remove glib require
...
if not button_flow[remote_name] or not button_flow[remote_name].valid then
    local remote_button = button_flow.add{
        type = "sprite-button",
        name = remote_name,
        style = "slot_sized_button",
        sprite = "item/spidertron-remote",
        tooltip = {"gui.spidertron-remote-tooltip"}
    }
    -- Apply style mods if needed
    remote_button.style.width = 40
    remote_button.style.height = 40
end
```

**All button creations need similar changes:**
- remote button (line 931, 990)
- repath button (line 954, 1074)
- toggle button (line 1013)
- dump button (line 1050)

### 3. lib/events_blueprint.lua
**Changes:**
- Line 61: Remove pcall wrapper around `blueprint.set_blueprint_entity_tag()`

**Before:**
```lua
pcall(function()
    blueprint.set_blueprint_entity_tag(i, 'requested_items', items_list)
end)
```

**After:**
```lua
if blueprint.valid and blueprint.set_blueprint_entity_tag then
    blueprint.set_blueprint_entity_tag(i, 'requested_items', items_list)
end
```

### 4. lib/journey.lua
**Changes:**
- Lines 695, 700: Remove pcalls around `container.logistic_mode` access

**Before:**
```lua
local success_entity, entity_mode = pcall(function() return container.logistic_mode end)
if success_entity and entity_mode then
    logistic_mode = entity_mode
else
    local success_proto, proto_mode = pcall(function() return container.prototype.logistic_mode end)
    if success_proto and proto_mode then
        logistic_mode = proto_mode
    end
end
```

**After:**
```lua
local entity_mode = container.logistic_mode
if entity_mode then
    logistic_mode = entity_mode
else
    local proto_mode = container.prototype.logistic_mode
    if proto_mode then
        logistic_mode = proto_mode
    end
end
```

### 5. lib/events_gui.lua
**Changes:**
- Lines 1095, 1108, 1112: Remove pcalls around neural-spider-control integration

**Before:**
```lua
local success, result = pcall(function()
    remote.call("neural-spider-control", "connect_to_vehicle", {
        player_index = player.index,
        vehicle = spidertron
    })
end)
...
local success, neural_connect = pcall(function()
    return require("__neural-spider-control__.scripts.neural_connect")
end)
...
local connect_success, connect_error = pcall(function()
    neural_connect.connect_to_spidertron({...})
end)
```

**After:**
```lua
if script.active_mods["neural-spider-control"] then
    if remote.interfaces["neural-spider-control"] and 
       remote.interfaces["neural-spider-control"]["connect_to_vehicle"] then
        remote.call("neural-spider-control", "connect_to_vehicle", {
            player_index = player.index,
            vehicle = spidertron
        })
        connected = true
    end
    
    if not connected then
        local neural_connect = require("__neural-spider-control__.scripts.neural_connect")
        if neural_connect and neural_connect.connect_to_spidertron then
            neural_connect.connect_to_spidertron({
                player_index = player.index,
                spidertron = spidertron
            })
            connected = true
        end
    end
end
```

### 6. lib/commands.lua
**Changes:**
- Add command tracking system at start of `register_all()`
- Lines 11, 88, 129, 193, 235, 316, 331, 402, 414, 424, 435, 531: Remove all pcall wrappers

**Before:**
```lua
function debug_commands.register_all()
    local success, err = pcall(function()
        commands.add_command("show_active_spiders", {...}, function(event)
            -- command code
        end)
    end)
    if not success then
        -- Command already exists, skip registration
    end
    ...
end
```

**After:**
```lua
function debug_commands.register_all()
    storage.registered_commands = storage.registered_commands or {}
    
    if not storage.registered_commands["show_active_spiders"] then
        commands.add_command("show_active_spiders", {...}, function(event)
            -- command code
        end)
        storage.registered_commands["show_active_spiders"] = true
    end
    
    -- Repeat for all other commands
    ...
end
```

**Commands to track:**
- show_active_spiders
- show_requesters
- show_providers
- show_beacons
- show_tasks
- validate_requests
- show_status
- test_spidertron
- list_guis

### 7. lib/pathing.lua
**Changes:**
- Lines 32, 92, 214, 330, 1970: Remove pcalls around `spider.get_spider_legs()`

**Before:**
```lua
local success, legs = pcall(function()
    return spider.get_spider_legs()
end)
if not success or not legs or #legs == 0 then
    -- handle no legs
end
```

**After:**
```lua
if spider.type == "spider-vehicle" and spider.get_spider_legs then
    local legs = spider.get_spider_legs()
    if legs and #legs > 0 then
        -- use legs
    else
        -- handle no legs
    end
else
    -- handle no legs method
end
```

### 8. scripts/spidertron_gui.lua
**Changes:**
- Remove FilterHelper style checks (lines 15-29)
- Lines 47, 165: Remove `pcall(require, "__glib__/glib")`
- Replace all glib.add() with native GUI API
- Remove FilterHelper style references

**Context:** Creates remote selection GUI in left panel when holding spidertron remote

**Before:**
```lua
-- Check if FilterHelper styles exist
local success, test_frame = pcall(function()
    return left_gui.add{type = "frame", style = "fh_content_frame"}
end)
if success and test_frame and test_frame.valid then
    test_frame.destroy()
    frame_style = "fh_content_frame"
    inner_frame_style = "fh_deep_frame"
    use_filter_helper_style = true
end

local glib_available, glib = pcall(require, "__glib__/glib")
if glib_available and glib then
    frame, refs = glib.add(left_gui, {...})
end
```

**After:**
```lua
-- Remove FilterHelper checks entirely
local frame_style = "inside_shallow_frame"
local inner_frame_style = "inside_shallow_frame"

-- Remove glib, use native API
local frame = left_gui.add{
    type = "frame",
    name = frame_name,
    style = frame_style
}
frame.style.horizontally_stretchable = false
frame.style.vertically_stretchable = false
frame.style.top_padding = 3
frame.style.bottom_padding = 6
frame.style.left_padding = 6
frame.style.right_padding = 6

local button_frame = frame.add{
    type = "frame",
    name = "button_frame",
    direction = "vertical",
    style = inner_frame_style
}
button_frame.style.vertically_stretchable = false

button_frame.add{
    type = "flow",
    name = "button_flow",
    direction = "vertical"
}
```

**Also fix button creation (line 165-206):**
```lua
-- Remove glib check
for i, spider in ipairs(selected_spiders) do
    if spider and spider.valid then
        local button_name = MOD_NAME .. "_remote_connect_" .. spider.unit_number
        local existing_button = button_flow[button_name]
        if existing_button and existing_button.valid then
            -- Update existing
        else
            local button = button_flow.add{
                type = "sprite-button",
                name = button_name,
                sprite = "neural-connection-sprite",
                tooltip = display_name,
                style = "slot_sized_button"
            }
        end
    end
end
```

### 9. lib/registration.lua
**Changes:**
- Line 21: Remove pcall around entity tags setting

**Before:**
```lua
local success, err = pcall(function()
    if requester.tags == nil then
        requester.tags = {}
    end
    requester.tags.requested_items = items_list
end)
if not success then
    -- Entity ghost doesn't support tags, which is fine
    return
end
```

**After:**
```lua
if requester.type == "entity-ghost" then
    if requester.tags == nil then
        requester.tags = {}
    end
    if requested_items and next(requested_items) then
        requester.tags.requested_items = items_list
    else
        if requester.tags then
            requester.tags.requested_items = nil
        end
    end
end
```

### 10. lib/utils.lua
**Changes:**
- Line 37: Remove pcall around prototype access

**Before:**
```lua
local success, prototype = pcall(function() return prototypes.item[item] end)
if not success or not prototype then return 1 end
return prototype.stack_size
```

**After:**
```lua
local prototype = prototypes.item[item]
if prototype then
    return prototype.stack_size
else
    return 1
end
```

## Additional Global Search and Replace

### Find and Replace All `game.item_prototypes`
**Search for:** `game.item_prototypes`
**Replace with:** `prototypes.item`
**Files to check:**
- lib/setup.lua (lines 31, 34, 44)

### Find and Replace All `game.entity_prototypes`
**Search for:** `game.entity_prototypes`
**Replace with:** `prototypes.entity`
**Files to check:**
- Verify no instances exist (should be none)

### Verify Other `game.` References
These are still valid in Factorio 2.0+:
- `game.players` - OK
- `game.get_player()` - OK
- `game.tick` - OK
- `game.surfaces` - OK
- `game.print()` - OK

## Testing Checklist

- [ ] Test with and without neural-spider-control mod
- [ ] Test command registration (verify no duplicates)
- [ ] Test GUI creation (toolbar buttons appear correctly)
- [ ] Test remote selection GUI (appears when holding remote)
- [ ] Test spider leg access (different spider types)
- [ ] Test blueprint tag setting
- [ ] Test item prototype access (with removed mods)
- [ ] Test requester GUI (separate from toolbar)
- [ ] Verify no glib errors in log
- [ ] Verify no FilterHelper references
- [ ] Verify no pcall usages remain (grep for "pcall")

## Summary of Changes

**Total pcall removals:** 35
- lib/setup.lua: 1
- lib/gui.lua: 6
- lib/events_blueprint.lua: 1
- lib/journey.lua: 2
- lib/events_gui.lua: 3
- lib/commands.lua: 12
- lib/pathing.lua: 5
- scripts/spidertron_gui.lua: 3
- lib/registration.lua: 1
- lib/utils.lua: 1

**Dependencies to remove:**
- glib (from lib/gui.lua and scripts/spidertron_gui.lua)
- FilterHelper (from scripts/spidertron_gui.lua)

**API fixes:**
- game.item_prototypes → prototypes.item
- game.entity_prototypes → prototypes.entity

## Notes

- The requester GUI (lib/gui.lua `requester_gui()` function) is separate from toolbar buttons and doesn't use glib
- Toolbar buttons are created in `add_spidertron_toggle_button()` function
- Remote selection GUI is in scripts/spidertron_gui.lua
- All GUI code should use native Factorio API, no external dependencies except ceelos-vehicle-gui-util for shared toolbar

