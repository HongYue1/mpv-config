-- cycle-commands.lua
--
-- Cycle through arbitrary mpv input commands from input.conf.
--
-- Basic syntax:
--   script-message cycle-commands "command 1" "command 2" "command 3"
--
-- Reverse:
--   script-message cycle-commands !reverse "command 1" "command 2"
--   script-message cycle-commands --reverse "command 1" "command 2"
--   script-message cycle-commands/reverse "command 1" "command 2"
--
-- Force forward when using a reverse message/default:
--   script-message cycle-commands/reverse --forward "command 1" "command 2"
--
-- Reset this command list before cycling:
--   script-message cycle-commands !reset "command 1" "command 2"
--   script-message cycle-commands --reset "command 1" "command 2"
--
-- Show raw command on OSD before running it:
--   script-message cycle-commands/osd "command 1" "command 2"
--   script-message cycle-commands --raw-osd "command 1" "command 2"
--
-- Reverse with raw-command OSD:
--   script-message cycle-commands/osd-reverse "command 1" "command 2"
--
-- Dynamic post-command OSD by querying a property:
--   script-message cycle-commands "--osd-prop=ontop:Always on Top" "set ontop yes" "set ontop no"
--
-- Dynamic post-command OSD by expanding mpv properties after the command succeeds:
--   script-message cycle-commands "--osd-text=Always on Top: ${ontop}" "set ontop yes" "set ontop no"
--
-- Optional OSD duration:
--   script-message cycle-commands --osd-duration=3 "--osd-prop=ontop:Always on Top" "set ontop yes" "set ontop no"
--
-- End option parsing with -- if your first command looks like a flag:
--   script-message cycle-commands -- "--reverse" "show-text test"
--
-- Clear all remembered cycle positions:
--   script-message cycle-commands/clear
--
-- Notes:
--   - Each cycle step must be one quoted argument.
--   - If the command itself contains quotes, use backticks or single quotes as the outer quotes.
--   - Backtick/single-quote quoting requires mpv 0.34+.
--   - Forward/reverse/raw-OSD/post-OSD bindings share state as long as the command list is exactly identical.
--   - /osd shows the raw command before execution.
--   - --osd-text and --osd-prop show after successful execution.

local mp = require("mp")
local msg = require("mp.msg")
local utils = require("mp.utils")

local positions = {}

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

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

local function fail_parse(text)
    msg.error(text)
    mp.osd_message("cycle-commands: " .. text, 3)
    return nil, text
end

local function value_after_equals(flag, option)
    local prefix = option .. "="
    if type(flag) == "string" and flag:sub(1, #prefix) == prefix then
        return flag:sub(#prefix + 1)
    end
    return nil
end

local function take_value(args, flag)
    table.remove(args, 1)

    if #args == 0 then
        return nil, "missing value for " .. flag
    end

    local value = args[1]
    table.remove(args, 1)

    return value
end

local function set_post_text(opts, text)
    if type(text) ~= "string" or not text:find("%S") then
        return false, "empty --osd-text"
    end

    opts.post_osd = {
        kind = "text",
        text = text,
    }

    return true
end

local function set_post_prop(opts, spec)
    if type(spec) ~= "string" or not spec:find("%S") then
        return false, "empty --osd-prop"
    end

    local prop, label = spec:match("^([^:]+):(.*)$")
    if not prop then
        prop = spec
    end

    prop = trim(prop)

    if label ~= nil then
        label = trim(label)
    end

    if prop == "" then
        return false, "empty property in --osd-prop"
    end

    opts.post_osd = {
        kind = "prop",
        prop = prop,
        label = label and label ~= "" and label or prop,
    }

    return true
end

local function set_osd_duration(opts, value)
    local duration = tonumber(value)

    if not duration or duration <= 0 then
        return false, "invalid --osd-duration: " .. tostring(value)
    end

    opts.osd_duration = duration
    return true
end

local function parse_flags(args, defaults)
    defaults = defaults or {}

    local opts = {
        reverse = defaults.reverse or false,
        raw_osd = defaults.raw_osd or false,
        reset = false,
        post_osd = nil,
        osd_duration = defaults.osd_duration or 2,
    }

    while #args > 0 do
        local flag = args[1]

        local osd_text_value = value_after_equals(flag, "--osd-text")
        if osd_text_value == nil then
            osd_text_value = value_after_equals(flag, "--show-text")
        end

        local osd_prop_value = value_after_equals(flag, "--osd-prop")
        if osd_prop_value == nil then
            osd_prop_value = value_after_equals(flag, "--show-prop")
        end

        local osd_duration_value = value_after_equals(flag, "--osd-duration")

        if flag == "--" then
            table.remove(args, 1)
            break
        elseif flag == "!reverse" then
            opts.reverse = not opts.reverse
            table.remove(args, 1)
        elseif flag == "--reverse" then
            opts.reverse = true
            table.remove(args, 1)
        elseif flag == "--forward" or flag == "--no-reverse" then
            opts.reverse = false
            table.remove(args, 1)
        elseif flag == "!reset" or flag == "--reset" then
            opts.reset = true
            table.remove(args, 1)
        elseif flag == "--raw-osd" or flag == "--command-osd" or flag == "--osd" then
            opts.raw_osd = true
            table.remove(args, 1)
        elseif flag == "--no-raw-osd" then
            opts.raw_osd = false
            table.remove(args, 1)
        elseif flag == "--no-osd" then
            opts.raw_osd = false
            opts.post_osd = nil
            table.remove(args, 1)
        elseif flag == "--osd-text" or flag == "--show-text" then
            local value, err = take_value(args, flag)
            if value == nil then
                return fail_parse(err)
            end

            local ok, set_err = set_post_text(opts, value)
            if not ok then
                return fail_parse(set_err)
            end
        elseif osd_text_value ~= nil then
            local ok, set_err = set_post_text(opts, osd_text_value)
            if not ok then
                return fail_parse(set_err)
            end

            table.remove(args, 1)
        elseif flag == "--osd-prop" or flag == "--show-prop" then
            local value, err = take_value(args, flag)
            if value == nil then
                return fail_parse(err)
            end

            local ok, set_err = set_post_prop(opts, value)
            if not ok then
                return fail_parse(set_err)
            end
        elseif osd_prop_value ~= nil then
            local ok, set_err = set_post_prop(opts, osd_prop_value)
            if not ok then
                return fail_parse(set_err)
            end

            table.remove(args, 1)
        elseif flag == "--osd-duration" then
            local value, err = take_value(args, flag)
            if value == nil then
                return fail_parse(err)
            end

            local ok, set_err = set_osd_duration(opts, value)
            if not ok then
                return fail_parse(set_err)
            end
        elseif osd_duration_value ~= nil then
            local ok, set_err = set_osd_duration(opts, osd_duration_value)
            if not ok then
                return fail_parse(set_err)
            end

            table.remove(args, 1)
        else
            break
        end
    end

    return opts
end

local function validate_commands(commands)
    if #commands == 0 then
        msg.warn("No commands supplied.")
        mp.osd_message("cycle-commands: no commands supplied", 3)
        return false
    end

    for i, command in ipairs(commands) do
        if type(command) ~= "string" or not command:find("%S") then
            msg.error(("Invalid empty command at position %d."):format(i))
            mp.osd_message(("cycle-commands: empty command #%d"):format(i), 3)
            return false
        end
    end

    return true
end

local function run_mpv_command(command)
    local ok, result, err = pcall(mp.command, command)

    if not ok then
        return false, result
    end

    if not result then
        return false, err or "unknown mp.command failure"
    end

    return true
end

local function expand_text(template)
    local ok, result, err = pcall(mp.command_native, { "expand-text", template })

    if not ok then
        return nil, result
    end

    if result == nil then
        return nil, err or "expand-text returned nil"
    end

    return tostring(result)
end

local function show_post_osd(opts)
    if not opts.post_osd then
        return
    end

    if opts.post_osd.kind == "text" then
        local text, err = expand_text(opts.post_osd.text)

        if not text then
            msg.warn("Could not expand --osd-text: " .. tostring(err))
            text = opts.post_osd.text
        end

        mp.osd_message(text, opts.osd_duration)
        return
    end

    if opts.post_osd.kind == "prop" then
        local ok, value = pcall(mp.get_property_osd, opts.post_osd.prop)

        if not ok then
            msg.warn(
                ("Could not query property %q: %s"):format(
                    opts.post_osd.prop,
                    tostring(value)
                )
            )
            value = "<unavailable>"
        elseif value == nil then
            value = "<unavailable>"
        end

        mp.osd_message(
            ("%s: %s"):format(opts.post_osd.label, value),
            opts.osd_duration
        )
    end
end

local function restore_position(key, old_pos)
    if old_pos == nil then
        positions[key] = nil
    else
        positions[key] = old_pos
    end
end

local function run_cycle(defaults, ...)
    defaults = defaults or {}

    local commands = { ... }
    local opts = parse_flags(commands, defaults)

    if not opts then
        return
    end

    if not validate_commands(commands) then
        return
    end

    local key = stable_key(commands)
    local old_pos = positions[key]

    local pos
    if opts.reset then
        pos = 0
    else
        pos = old_pos or 0
    end

    pos = pos + (opts.reverse and -1 or 1)

    if pos > #commands then
        pos = 1
    elseif pos < 1 then
        pos = #commands
    end

    -- Store before running to behave sensibly if a command recursively invokes
    -- this script. On failure, restore below.
    positions[key] = pos

    local command = commands[pos]

    msg.verbose(
        ("cycle-commands: %d/%d%s%s: %s"):format(
            pos,
            #commands,
            opts.reverse and " reverse" or "",
            opts.reset and " reset" or "",
            command
        )
    )

    if opts.raw_osd then
        mp.osd_message(command, opts.osd_duration)
    end

    local ok, err = run_mpv_command(command)
    if not ok then
        restore_position(key, old_pos)

        local text = ("cycle-commands failed:\n%s"):format(tostring(err))
        msg.error(text)
        mp.osd_message(text, 4)
        return
    end

    show_post_osd(opts)
end

local function clear_state()
    positions = {}
    msg.info("cycle-commands: state cleared")
    mp.osd_message("cycle-commands: state cleared", 2)
end

mp.register_script_message("cycle-commands", function(...)
    run_cycle({ raw_osd = false, reverse = false }, ...)
end)

mp.register_script_message("cycle-commands/osd", function(...)
    run_cycle({ raw_osd = true, reverse = false }, ...)
end)

mp.register_script_message("cycle-commands/reverse", function(...)
    run_cycle({ raw_osd = false, reverse = true }, ...)
end)

mp.register_script_message("cycle-commands/osd-reverse", function(...)
    run_cycle({ raw_osd = true, reverse = true }, ...)
end)

mp.register_script_message("cycle-commands/clear", clear_state)
