-- Main control file for spidertron logistics mod
-- Modularized structure with separate modules for different concerns

-- Load core modules
local constants = require('lib.constants')
local utils = require('lib.utils')
local beacon_assignment = require('lib.beacon_assignment')
local registration = require('lib.registration')
local gui = require('lib.gui')
local logistics = require('lib.logistics')
local journey = require('lib.journey')
local rendering = require('lib.rendering')
local debug_commands = require('lib.commands')
local pathing = require('lib.pathing')
local logging = require('lib.logging')
local route_planning = require('lib.route_planning')
local shared_toolbar = require("__ceelos-vehicle-gui-util__/lib/shared_toolbar")

-- Load event handler modules
local events_gui = require('lib.events_gui')
local events_tick = require('lib.events_tick')
local events_spider = require('lib.events_spider')
local events_entity = require('lib.events_entity')
local events_blueprint = require('lib.events_blueprint')
local setup_module = require('lib.setup')

-- Register all event handlers
events_gui.register()
events_tick.register()
events_spider.register()
events_entity.register()
events_blueprint.register()

-- Utility commands (kept in control.lua for convenience)
commands.add_command("cleanup", "Clear old flow-based GUI (the stuck one with no name)", function(event)
    local player = game.get_player(event.player_index)
    if not player or not player.valid then return end
    
    local relative_gui = player.gui.relative
    if not relative_gui then 
        player.print("No relative GUI found")
        return 
    end
    
    local count = 0
    
    -- ONLY clean up old flow-based GUI (no name, no anchor) - DO NOT destroy the new frame GUI!
    for _, child in pairs(relative_gui.children) do
        if child and child.valid then
            -- Only target flow elements (old GUI was a flow, new GUI is a frame)
            if child.type == 'flow' then
                -- Check if name exists and is not empty
                local has_name = child.name ~= nil and child.name ~= ''
                local has_anchor = child.anchor ~= nil
                
                -- Destroy flows with no name and no anchor (stuck old GUI)
                if not has_name and not has_anchor then
                    child.destroy()
                    count = count + 1
                -- Also destroy flows with requester chest anchor (old GUI with anchor)
                elseif has_anchor and child.anchor.gui == defines.relative_gui_type.container_gui 
                       and child.anchor.name == constants.spidertron_requester_chest then
                    child.destroy()
                    count = count + 1
                end
            end
            -- DO NOT destroy frames - the new GUI is a frame and should be kept!
        end
    end
    
    -- Also close any open item selector modals (these are safe to close)
    if player.gui.screen["spidertron_item_selector"] then
        player.gui.screen["spidertron_item_selector"].destroy()
        count = count + 1
    end
    
    if count > 0 then
        player.print("Destroyed " .. count .. " old GUI elements (kept new frame GUI)")
    else
        player.print("No old GUI elements found to clean up")
    end
end)

commands.add_command("debug-gui", "Show all GUIs", function(event)
    local player = game.get_player(event.player_index)
    if not player or not player.valid then return end
    
    player.print("=== ALL GUI ELEMENTS ===")
    
    local relative_gui = player.gui.relative
    if not relative_gui then
        player.print("No relative GUI found")
        return
    end
    
    local count = 0
    for _, child in pairs(relative_gui.children) do
        if child and child.valid then
            count = count + 1
            local anchor_info = "No anchor"
            -- Anchor is a PROPERTY, not a method!
            if child.anchor then
                local anchor_name = child.anchor.name or "no name"
                local anchor_gui = child.anchor.gui or "unknown"
                anchor_info = "Anchor: " .. anchor_name .. " (gui: " .. tostring(anchor_gui) .. ")"
            end
            
            local name = child.name or "(empty)"
            local direction = ""
            if child.type == 'flow' and child.direction then
                direction = ", Direction: " .. child.direction
            end
            player.print(count .. ". Type: " .. child.type .. ", Name: " .. name .. direction .. ", " .. anchor_info)
        end
    end
    
    player.print("Total: " .. count .. " elements")
end)

-- Initialize the mod
script.on_init(setup_module.setup)
script.on_configuration_changed(setup_module.setup)
