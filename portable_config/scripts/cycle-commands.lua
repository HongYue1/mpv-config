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

local mp = require("mp")
local msg = require("mp.msg")

local concat = table.concat
local fmt = string.format
local s_find = string.find
local s_match = string.match
local s_sub = string.sub
local pcall = pcall
local tonumber = tonumber
local tostring = tostring
local type = type
local huge = math.huge

local DEFAULT_OSD_DURATION = 2
local PARSE_ERROR_OSD_DURATION = 3
local COMMAND_ERROR_OSD_DURATION = 4
local UNAVAILABLE = "<unavailable>"

local positions = {}
local versions = {}
local state_serial = 0

local function next_serial()
    state_serial = state_serial + 1
    return state_serial
end

local function is_blank(s)
    return type(s) ~= "string" or s_find(s, "%S") == nil
end

local function trim(s)
    return s_match(s, "^%s*(.-)%s*$")
end

local function osd_prefixed(text, duration)
    mp.osd_message("cycle-commands: " .. text, duration)
end

local function parse_error(text)
    msg.error("cycle-commands: " .. text)
    osd_prefixed(text, PARSE_ERROR_OSD_DURATION)
    return nil, text
end

local function set_post_text(opts, text)
    if is_blank(text) then
        return false, "empty --osd-text"
    end

    opts.post_osd = {
        kind = "text",
        text = text,
    }

    return true
end

local function set_post_prop(opts, spec)
    if is_blank(spec) then
        return false, "empty --osd-prop"
    end

    local colon = s_find(spec, ":", 1, true)
    local prop
    local label

    if colon then
        prop = trim(s_sub(spec, 1, colon - 1))
        label = trim(s_sub(spec, colon + 1))
    else
        prop = trim(spec)
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

    if not duration or duration ~= duration or duration <= 0 or duration >= huge then
        return false, "invalid --osd-duration: " .. tostring(value)
    end

    opts.osd_duration = duration
    return true
end

local FLAG_NO_VALUE = {
    ["!reverse"] = function(opts)
        opts.reverse = not opts.reverse
    end,

    ["--reverse"] = function(opts)
        opts.reverse = true
    end,

    ["--forward"] = function(opts)
        opts.reverse = false
    end,

    ["--no-reverse"] = function(opts)
        opts.reverse = false
    end,

    ["!reset"] = function(opts)
        opts.reset = true
    end,

    ["--reset"] = function(opts)
        opts.reset = true
    end,

    ["--raw-osd"] = function(opts)
        opts.raw_osd = true
    end,

    ["--command-osd"] = function(opts)
        opts.raw_osd = true
    end,

    ["--osd"] = function(opts)
        opts.raw_osd = true
    end,

    ["--no-raw-osd"] = function(opts)
        opts.raw_osd = false
    end,

    ["--no-osd"] = function(opts)
        opts.raw_osd = false
        opts.post_osd = nil
    end,
}

local FLAG_WITH_VALUE = {
    ["--osd-text"] = set_post_text,
    ["--show-text"] = set_post_text,
    ["--osd-prop"] = set_post_prop,
    ["--show-prop"] = set_post_prop,
    ["--osd-duration"] = set_osd_duration,
}

local function split_equals_flag(flag)
    local eq = s_find(flag, "=", 1, true)

    if not eq then
        return nil
    end

    return s_sub(flag, 1, eq - 1), s_sub(flag, eq + 1)
end

local function parse_flags(argv, argc, defaults)
    defaults = defaults or {}

    local opts = {
        reverse = defaults.reverse == true,
        raw_osd = defaults.raw_osd == true,
        reset = defaults.reset == true,
        post_osd = defaults.post_osd,
        osd_duration = defaults.osd_duration or DEFAULT_OSD_DURATION,
    }

    local i = 1

    while i <= argc do
        local flag = argv[i]

        if type(flag) ~= "string" then
            break
        end

        if flag == "--" then
            return opts, i + 1
        end

        local handler = FLAG_NO_VALUE[flag]

        if handler then
            handler(opts)
            i = i + 1
        else
            handler = FLAG_WITH_VALUE[flag]

            if handler then
                if i >= argc then
                    return parse_error("missing value for " .. flag)
                end

                local ok, err = handler(opts, argv[i + 1])

                if not ok then
                    return parse_error(err)
                end

                i = i + 2
            else
                local option, value = split_equals_flag(flag)
                handler = option and FLAG_WITH_VALUE[option]

                if not handler then
                    break
                end

                local ok, err = handler(opts, value)

                if not ok then
                    return parse_error(err)
                end

                i = i + 1
            end
        end
    end

    return opts, i
end

local function validate_commands(argv, first, last)
    if first > last then
        msg.warn("cycle-commands: no commands supplied")
        osd_prefixed("no commands supplied", PARSE_ERROR_OSD_DURATION)
        return false
    end

    for i = first, last do
        if is_blank(argv[i]) then
            local n = i - first + 1
            msg.error(fmt("cycle-commands: invalid empty command at position %d", n))
            osd_prefixed(fmt("empty command #%d", n), PARSE_ERROR_OSD_DURATION)
            return false
        end
    end

    return true
end

local function stable_key(argv, first, last)
    -- Length-prefixed-ish key.
    -- Deterministic and avoids practical collisions from naive concatenation.
    local count = last - first + 1
    local parts = { tostring(count) }
    local n = 1

    for i = first, last do
        local command = argv[i]

        n = n + 1
        parts[n] = tostring(#command)

        n = n + 1
        parts[n] = command
    end

    return concat(parts, "\0")
end

local function advance_position(old_pos, count, reverse, reset)
    local pos = reset and 0 or old_pos

    if type(pos) ~= "number" or pos < 1 or pos > count then
        pos = 0
    end

    if reverse then
        return pos <= 1 and count or pos - 1
    end

    return pos >= count and 1 or pos + 1
end

local function remember_position(key, pos)
    positions[key] = pos

    local token = next_serial()
    versions[key] = token

    return token
end

local function restore_position(key, old_pos, old_version, token)
    -- Only restore if this invocation still owns the current state.
    -- This prevents a failed outer invocation from overwriting a newer nested
    -- successful invocation or a state clear.
    if versions[key] ~= token then
        return
    end

    positions[key] = old_pos
    versions[key] = old_version
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
    local post_osd = opts.post_osd

    if not post_osd then
        return
    end

    if post_osd.kind == "text" then
        local text, err = expand_text(post_osd.text)

        if text == nil then
            msg.warn("cycle-commands: could not expand --osd-text: " .. tostring(err))
            text = post_osd.text
        end

        mp.osd_message(text, opts.osd_duration)
        return
    end

    if post_osd.kind == "prop" then
        local ok, value = pcall(mp.get_property_osd, post_osd.prop, UNAVAILABLE)

        if not ok then
            msg.warn(fmt(
                "cycle-commands: could not query property %q: %s",
                post_osd.prop,
                tostring(value)
            ))

            value = UNAVAILABLE
        end

        mp.osd_message(
            fmt("%s: %s", post_osd.label, tostring(value)),
            opts.osd_duration
        )
    end
end

local function run_cycle(defaults, ...)
    local argc = select("#", ...)
    local argv = { ... }

    local opts, first_command = parse_flags(argv, argc, defaults)

    if not opts then
        return
    end

    if not validate_commands(argv, first_command, argc) then
        return
    end

    local command_count = argc - first_command + 1
    local key = stable_key(argv, first_command, argc)

    local old_pos = positions[key]
    local old_version = versions[key]

    local pos = advance_position(old_pos, command_count, opts.reverse, opts.reset)
    local token = remember_position(key, pos)

    local command = argv[first_command + pos - 1]

    msg.verbose(fmt(
        "cycle-commands: %d/%d%s%s: %s",
        pos,
        command_count,
        opts.reverse and " reverse" or "",
        opts.reset and " reset" or "",
        command
    ))

    if opts.raw_osd then
        mp.osd_message(command, opts.osd_duration)
    end

    local ok, err = run_mpv_command(command)

    if not ok then
        restore_position(key, old_pos, old_version, token)

        local text = fmt("cycle-commands failed:\n%s", tostring(err))
        msg.error(text)
        mp.osd_message(text, COMMAND_ERROR_OSD_DURATION)
        return
    end

    show_post_osd(opts)
end

local function clear_state()
    positions = {}
    versions = {}

    -- Do not reset state_serial. Keeping it monotonic prevents stale restore
    -- tokens from becoming valid again after state is cleared.
    msg.info("cycle-commands: state cleared")
    osd_prefixed("state cleared", DEFAULT_OSD_DURATION)
end

local function register_cycle_message(name, defaults)
    mp.register_script_message(name, function(...)
        run_cycle(defaults, ...)
    end)
end

register_cycle_message("cycle-commands", {
    raw_osd = false,
    reverse = false,
})

register_cycle_message("cycle-commands/osd", {
    raw_osd = true,
    reverse = false,
})

register_cycle_message("cycle-commands/reverse", {
    raw_osd = false,
    reverse = true,
})

register_cycle_message("cycle-commands/osd-reverse", {
    raw_osd = true,
    reverse = true,
})

mp.register_script_message("cycle-commands/clear", clear_state)
