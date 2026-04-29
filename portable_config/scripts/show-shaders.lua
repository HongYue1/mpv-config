mp.register_script_message("show-shaders", function()
    local shaders = mp.get_property("glsl-shaders")
    if shaders == "" then
        mp.osd_message("No shaders", 5)
    else
        mp.osd_message(shaders, 5)
    end
end)
