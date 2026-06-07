-- 1. Show Shaders
mp.register_script_message("show-shaders", function()
    local shaders = mp.get_property("glsl-shaders")
    if not shaders or shaders == "" then
        mp.osd_message("No shaders", 5)
    else
        mp.osd_message(shaders, 5)
    end
end)

-- 2. Smart Paste (Strips Windows Quotes & prevents crashes)
mp.register_script_message("smart-paste", function(mode)
-- Explicitly tell mpv to fetch the latest clipboard data first
mp.commandv("update-clipboard", "text")

local text = mp.get_property("clipboard/text")

if not text or text == "" then
    mp.osd_message("Clipboard empty!")
    return
    end

    -- Clean up the string by removing surrounding double quotes ("Copy as path")
if text:sub(1, 1) == '"' and text:sub(-1) == '"' then
    text = text:sub(2, -2)
    end

    -- Load the file based on the mode requested
    if mode == "append" then
        mp.commandv("loadfile", text, "append-play")
        mp.osd_message("Added to playlist")
        else
            mp.commandv("loadfile", text, "replace")
            mp.osd_message("Playing from clipboard")
            end
end)
