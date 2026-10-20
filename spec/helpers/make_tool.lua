-- Builds the PencilTool a spec's Pencil instance carries (self.tool), from the
-- settings the specs used to put in flat fields (current_tool, tool_settings,
-- swap_eraser_and_highlighter, experimental_text_highlight).
--   dofile("spec/helpers/make_tool.lua")(PencilTool, { tool_settings = {...}, text_highlight = true })
return function(PencilTool, o)
    o = o or {}
    local tool = PencilTool:new()
    if o.current_tool then tool.current_tool = o.current_tool end
    for name, settings in pairs(o.tool_settings or {}) do
        tool.tool_settings[name] = tool.tool_settings[name] or {}
        for k, v in pairs(settings) do tool.tool_settings[name][k] = v end
    end
    tool.swap_eraser_and_highlighter = o.swap or false
    tool.experimental_text_highlight = o.text_highlight or false
    return tool
end
