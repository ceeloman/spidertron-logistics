-- Function to update the remote selection GUI (shown when holding a spidertron remote)
function spidertron_gui.update_remote_selection_gui(player)
    if not player or not player.valid then return end
    
    -- Check if player is holding a spidertron remote
    local selected_spiders = player.spidertron_remote_selection
    local has_remote = selected_spiders ~= nil
    
    -- Get the left GUI container
    local left_gui = player.gui.left
    local frame_name = MOD_NAME .. "_remote_selection_frame"
    local existing_frame = left_gui[frame_name]
    
    if has_remote and #selected_spiders > 0 then
        -- Try to use FilterHelper's style for matching appearance, fallback to standard if not available
        local frame_style = "inside_shallow_frame"
        local inner_frame_style = "inside_shallow_frame"
        local use_filter_helper_style = false
        
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
        
        -- Create or update the frame
        local frame
        if existing_frame and existing_frame.valid then
            frame = existing_frame
            -- Clear existing content by destroying all children
            for _, child in pairs(frame.children) do
                if child.valid then
                    child.destroy()
                end
            end
        else
            if existing_frame then
                existing_frame.destroy()
            end
            
            -- Create the toolbar frame with same structure as shared toolbar
            local glib_available, glib = pcall(require, "__glib__/glib")
            if glib_available and glib then
                local refs = {}
                local style_mods = {
                    horizontally_stretchable = false,
                    vertically_stretchable = false
                }
                
                if not use_filter_helper_style then
                    style_mods.top_padding = 3
                    style_mods.bottom_padding = 6
                    style_mods.left_padding = 6
                    style_mods.right_padding = 6
                end
                
                frame, refs = glib.add(left_gui, {
                    args = {
                        type = "frame",
                        name = frame_name,
                        style = frame_style
                    },
                    ref = "toolbar",
                    style_mods = style_mods,
                    children = {{
                        args = {
                            type = "frame",
                            name = "button_frame",
                            direction = "vertical",
                            style = inner_frame_style
                        },
                        ref = "button_frame",
                        style_mods = {
                            vertically_stretchable = false
                        },
                        children = {{
                            args = {
                                type = "flow",
                                name = "button_flow",
                                direction = "vertical"
                            },
                            ref = "button_flow"
                        }}
                    }}
                }, refs)
            else
                -- Fallback without glib
                frame = left_gui.add{
                    type = "frame",
                    name = frame_name,
                    style = frame_style
                }
                frame.style.horizontally_stretchable = false
                frame.style.vertically_stretchable = false
                if not use_filter_helper_style then
                    frame.style.top_padding = 3
                    frame.style.bottom_padding = 6
                    frame.style.left_padding = 6
                    frame.style.right_padding = 6
                end
                
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
            end
        end
        
        -- Navigate to button_flow (same structure as shared toolbar)
        local button_frame = frame["button_frame"]
        if not button_frame then
            -- Try to find it in children
            for _, child in ipairs(frame.children) do
                if child.name == "button_frame" then
                    button_frame = child
                    break
                end
            end
        end
        
        if not button_frame or not button_frame.valid then
            log_debug("Button frame not found in remote selection frame")
            return
        end
        
        local button_flow = button_frame["button_flow"]
        if not button_flow then
            -- Try to find it in children
            for _, child in ipairs(button_frame.children) do
                if child.name == "button_flow" then
                    button_flow = child
                    break
                end
            end
        end
        
        if not button_flow or not button_flow.valid then
            log_debug("Button flow not found in remote selection frame")
            return
        end
        
        -- Add label showing count (as a header)
        local count_label = button_flow.add{
            type = "label",
            caption = #selected_spiders .. " spider" .. (#selected_spiders > 1 and "s" or "") .. " selected"
        }
        count_label.style.font = "default-bold"
        count_label.style.bottom_margin = 4
        
        -- Add buttons for each selected spider (using same style as shared toolbar)
        local glib_available, glib = pcall(require, "__glib__/glib")
        for i, spider in ipairs(selected_spiders) do
            if spider and spider.valid then
                local button_name = MOD_NAME .. "_remote_connect_" .. spider.unit_number
                
                -- Check if button already exists
                local existing_button = button_flow[button_name]
                if existing_button and existing_button.valid then
                    -- Update caption if needed
                    local display_name = spider.name
                    if spider.unit_number then
                        display_name = display_name .. " (#" .. spider.unit_number .. ")"
                    end
                    existing_button.caption = display_name
                else
                    local display_name = spider.name
                    if spider.unit_number then
                        display_name = display_name .. " (#" .. spider.unit_number .. ")"
                    end
                    
                    local button
                    if glib_available and glib then
                        local refs = {}
                        button, refs = glib.add(button_flow, {
                            args = {
                                type = "sprite-button",
                                name = button_name,
                                sprite = "neural-connection-sprite",
                                tooltip = display_name,
                                style = "slot_sized_button"
                            },
                            ref = "connect_button"
                        }, refs)
                    else
                        button = button_flow.add{
                            type = "sprite-button",
                            name = button_name,
                            sprite = "neural-connection-sprite",
                            tooltip = display_name,
                            style = "slot_sized_button"
                        }
                    end
                end
            end
        end
    else
        -- Remove the frame if it exists
        if existing_frame and existing_frame.valid then
            existing_frame.destroy()
        end
    end
end
