-- cycle-commands.lua
--
-- Cycle through arbitrary mpv input commands from input.conf.
--
-- Basic syntax:
--   script-message cycle-commands "command 1" "command 2" "command 3"
--
-- Reverse:
--   script-message cycle-commands !reverse "command 1" "command 2"
--   script-message cycle-commands/reverse "command 1" "command 2"
--
-- Show raw command on OSD before running it:
--   script-message cycle-commands/osd "command 1" "command 2"
--
-- Recommended: put your own show-text inside each command instead of using /osd:
--   script-message cycle-commands `apply-profile pip; show-text "PiP: on"` `apply-profile pip-off; show-text "PiP: off"`
--
-- Notes:
--   - Each cycle step must be one quoted argument.
--   - If the command itself contains quotes, use backticks as the outer quotes.
--   - Backtick/single-quote quoting requires mpv 0.34+.
--   - Forward/reverse bindings share state as long as the command list is exactly identical.

local mp = require("mp")
local msg = require("mp.msg")
local utils = require("mp.utils")

local positions = {}

local function stable_key(commands)
    local ok, json = pcall(utils.format_json, commands)
    if ok and type(json) == "string" then
        return json
    end

    -- Fallback: length-prefixed key, avoids collisions from simple concatenation.
    local parts = { tostring(#commands) }
    for _, command in ipairs(commands) do
        parts[#parts + 1] = "\0"
        parts[#parts + 1] = tostring(#command)
        parts[#parts + 1] = ":"
        parts[#parts + 1] = command
    end
    return table.concat(parts)
end

local function parse_flags(args, default_reverse)
    local reverse = default_reverse or false
    local reset = false

    while #args > 0 do
        local flag = args[1]

        if flag == "!reverse" or flag == "--reverse" then
            reverse = not reverse
            table.remove(args, 1)
        elseif flag == "!reset" or flag == "--reset" then
            reset = true
            table.remove(args, 1)
        else
            break
        end
    end

    return reverse, reset
end

local function validate_commands(commands)
    if #commands == 0 then
        msg.warn("No commands supplied.")
        mp.osd_message("cycle-commands: no commands supplied", 3)
        return false
    end

    for i, command in ipairs(commands) do
        if type(command) ~= "string" or command == "" then
            msg.error(("Invalid empty command at position %d."):format(i))
            mp.osd_message(("cycle-commands: empty command #%d"):format(i), 3)
            return false
        end
    end

    return true
end

local function run_cycle(opts, ...)
    opts = opts or {}

    local commands = { ... }
    local reverse, reset = parse_flags(commands, opts.reverse)

    if not validate_commands(commands) then
        return
    end

    local key = stable_key(commands)

    local pos
    if reset then
        pos = 0
    else
        pos = positions[key] or 0
    end

    pos = pos + (reverse and -1 or 1)

    if pos > #commands then
        pos = 1
    elseif pos < 1 then
        pos = #commands
    end

    positions[key] = pos

    local command = commands[pos]

    msg.verbose(
        ("cycle-commands: %d/%d%s: %s"):format(
            pos,
            #commands,
            reverse and " reverse" or "",
            command
        )
    )

    if opts.osd then
        mp.osd_message(command, 2)
    end

    local ok, err = pcall(mp.command, command)
    if not ok then
        local text = ("cycle-commands failed:\n%s"):format(tostring(err))
        msg.error(text)
        mp.osd_message(text, 4)
    end
end

mp.register_script_message("cycle-commands", function(...)
    run_cycle({ osd = false, reverse = false }, ...)
end)

mp.register_script_message("cycle-commands/osd", function(...)
    run_cycle({ osd = true, reverse = false }, ...)
end)

mp.register_script_message("cycle-commands/reverse", function(...)
    run_cycle({ osd = false, reverse = true }, ...)
end)

mp.register_script_message("cycle-commands/osd-reverse", function(...)
    run_cycle({ osd = true, reverse = true }, ...)
end)
