-- evafast.lua
--
-- Hybrid seek / fast-forward for mpv.
--
-- Tap RIGHT: seek forward.
-- Hold RIGHT: ramp playback speed up.
-- Release after hold: ramp speed back to normal.
--
-- Script messages:
--   script-message-to evafast speedup
--   script-message-to evafast slowdown
--   script-message-to evafast toggle
--   script-message-to evafast speedup-target <time>
--   script-message-to evafast get-version <script>

local opts = {
    -- How far to jump on press. Set to 0 to disable tap-seeking and make
    -- the key behave as pure hold-to-fast-forward.
    seek_distance = 5,

    -- Playback speed modifier, applied once every speed_interval until cap.
    speed_increase = 0.1,
    speed_decrease = 0.1,

    -- Interval between speed changes.
    speed_interval = 0.05,

    -- Playback speed cap.
    speed_cap = 2,

    -- Playback speed cap when subtitles are displayed.
    -- Use "no" to disable subtitle-specific cap.
    subs_speed_cap = "1.6",

    -- Exponential speed ramping.
    -- Example: speed_increase=0.05, speed_decrease=0.025
    multiply_modifier = false,

    -- Show current speed during normal hold fast-forward.
    show_speed = true,

    -- Show current speed during toggled fast-forward.
    show_speed_toggled = true,

    -- Show current speed during speedup-target mode.
    show_speed_target = false,

    -- Minimum time between speed OSD/uosc speed flashes.
    -- Set to 0 to disable throttling.
    speed_osd_interval = 0.10,

    -- Show seek / timeline feedback.
    show_seek = true,

    -- Look ahead for smoother transition when subs_speed_cap is enabled.
    lookahead = false,

    -- Minimum time between subtitle lookahead checks.
    -- Only used when lookahead=yes.
    lookahead_cache_interval = 0.15,
}

local options = require "mp.options"
options.read_options(opts, "evafast")

local VERSION = "2.1.0"
local EPS = 0.0001

local uosc_available = false
local speed_timer = nil

local sub_is_active = false
local lookahead_cache_time = -math.huge
local lookahead_cache_value = nil
local last_speed_osd_time = -math.huge

local state = {
    key_down = false,
    repeated = false,

    accelerating = false,
    paused_ramp = false,

    toggle = false,
    target_time = nil,

    display_mode = "normal", -- normal, toggle, target
}

local function normalize_number(value, fallback, min)
    local n = tonumber(value)

    if not n then
        return fallback
    end

    if min and n < min then
        return min
    end

    return n
end

local function normalize_optional_number(value)
    if value == nil or value == false or value == "no" or value == "false" or value == "" then
        return nil
    end

    return tonumber(value)
end

opts.seek_distance = normalize_number(opts.seek_distance, 5)
opts.speed_increase = normalize_number(opts.speed_increase, 0.1, 0)
opts.speed_decrease = normalize_number(opts.speed_decrease, 0.1, 0)
opts.speed_interval = normalize_number(opts.speed_interval, 0.05, 0.001)
opts.speed_cap = normalize_number(opts.speed_cap, 2, 1)
opts.subs_speed_cap = normalize_optional_number(opts.subs_speed_cap)
opts.speed_osd_interval = normalize_number(opts.speed_osd_interval, 0.10, 0)
opts.lookahead_cache_interval = normalize_number(opts.lookahead_cache_interval, 0.15, 0)

if opts.subs_speed_cap then
    opts.subs_speed_cap = math.max(1, opts.subs_speed_cap)
end

local function invalidate_lookahead_cache()
    lookahead_cache_time = -math.huge
    lookahead_cache_value = nil
end

if opts.subs_speed_cap then
    sub_is_active = mp.get_property_native("sub-start") ~= nil

    mp.observe_property("sub-start", "native", function(_, value)
        sub_is_active = value ~= nil
        invalidate_lookahead_cache()
    end)
end

local function almost_equal(a, b)
    return math.abs((a or 0) - (b or 0)) <= EPS
end

local function get_speed()
    return mp.get_property_number("speed", 1) or 1
end

local function set_speed(speed)
    speed = math.max(1, speed)

    if almost_equal(speed, 1) then
        speed = 1
    end

    mp.set_property_native("speed", speed)
end

local function step_up(speed, cap)
    if speed >= cap then
        return cap
    end

    local delta

    if opts.multiply_modifier then
        delta = speed * opts.speed_increase
    else
        delta = opts.speed_increase
    end

    if delta <= 0 then
        return speed
    end

    local next_speed = math.min(speed + delta, cap)

    if almost_equal(next_speed, cap) then
        return cap
    end

    return next_speed
end

local function step_down(speed, floor)
    floor = floor or 1

    if speed <= floor then
        return floor
    end

    local delta

    if opts.multiply_modifier then
        delta = speed * opts.speed_decrease
    else
        delta = opts.speed_decrease
    end

    if delta <= 0 then
        return speed
    end

    local next_speed = math.max(speed - delta, floor)

    if almost_equal(next_speed, floor) then
        return floor
    end

    return next_speed
end

local function transition_time(from_speed, to_speed)
    from_speed = math.max(1, tonumber(from_speed) or 1)
    to_speed = math.max(1, tonumber(to_speed) or 1)

    if almost_equal(from_speed, to_speed) then
        return 0
    end

    local increasing = from_speed < to_speed
    local modifier = increasing and opts.speed_increase or opts.speed_decrease

    if modifier <= 0 then
        return math.huge
    end

    local steps

    if opts.multiply_modifier then
        if increasing then
            steps = math.ceil(math.log(to_speed / from_speed) / math.log(1 + modifier) - EPS)
        else
            if modifier >= 1 then
                steps = 1
            else
                steps = math.ceil(math.log(to_speed / from_speed) / math.log(1 - modifier) - EPS)
            end
        end
    else
        steps = math.ceil(math.abs(to_speed - from_speed) / modifier - EPS)
    end

    return math.max(0, steps) * opts.speed_interval
end

local function subtitle_active()
    return opts.subs_speed_cap ~= nil and sub_is_active
end

local function seconds_to_next_subtitle()
    if not opts.subs_speed_cap then
        return nil
    end

    local old_delay = mp.get_property_number("sub-delay", 0)
    local old_visibility = mp.get_property_native("sub-visibility")

    local ok = pcall(function()
        if old_visibility then
            mp.set_property_native("sub-visibility", false)
        end

        mp.command("no-osd sub-step 1")
    end)

    local new_delay = mp.get_property_number("sub-delay", old_delay)

    pcall(function()
        mp.set_property_number("sub-delay", old_delay)

        if old_visibility ~= nil then
            mp.set_property_native("sub-visibility", old_visibility)
        end
    end)

    if not ok then
        return nil
    end

    local delta = old_delay - new_delay

    if delta and delta > 0 then
        return delta
    end

    return nil
end

local function seconds_to_next_subtitle_cached()
    local now = mp.get_time()

    if opts.lookahead_cache_interval > 0 and now - lookahead_cache_time < opts.lookahead_cache_interval then
        return lookahead_cache_value
    end

    lookahead_cache_time = now
    lookahead_cache_value = seconds_to_next_subtitle()

    return lookahead_cache_value
end

local function base_speed_cap(speed)
    local cap = opts.speed_cap

    if opts.subs_speed_cap and subtitle_active() then
        cap = opts.subs_speed_cap
    elseif opts.lookahead and opts.subs_speed_cap then
        local next_sub = seconds_to_next_subtitle_cached()

        if next_sub then
            local correction_time = transition_time(speed, opts.subs_speed_cap)

            -- Subtitle times are media-time based. During correction, media time
            -- advances roughly by real_time * current_speed.
            if next_sub <= correction_time * math.max(speed, 1) then
                cap = opts.subs_speed_cap
            end
        end
    end

    return math.max(1, cap)
end

local function effective_speed_cap(speed)
    local cap = base_speed_cap(speed)

    if state.target_time then
        local current_time = mp.get_property_number("time-pos", 0) or 0

        if current_time >= state.target_time then
            state.target_time = nil
            state.accelerating = false
            state.toggle = false
            state.display_mode = "normal"
            return cap
        end

        local normal_target_cap = opts.speed_cap

        if opts.subs_speed_cap then
            normal_target_cap = math.min(normal_target_cap, opts.subs_speed_cap)
        end

        -- Keep this slightly above 1 so target mode does not get stuck.
        normal_target_cap = math.max(normal_target_cap, 1.1)

        local correction_time = transition_time(speed, normal_target_cap)

        if current_time + correction_time * math.max(speed, 1) > state.target_time then
            cap = 1.1
        end
    end

    return math.max(1, cap)
end

local function should_show_speed()
    if state.display_mode == "target" then
        return opts.show_speed_target
    end

    if state.display_mode == "toggle" then
        return opts.show_speed_toggled
    end

    return opts.show_speed
end

local function show_speed(speed)
    if not should_show_speed() then
        return
    end

    if opts.speed_osd_interval > 0 then
        local now = mp.get_time()

        if now - last_speed_osd_time < opts.speed_osd_interval then
            return
        end

        last_speed_osd_time = now
    end

    if uosc_available then
        mp.commandv("script-binding", "uosc/flash-speed")
    else
        mp.osd_message(("▶▶ x%.2f"):format(speed))
    end
end

local function reset_state_at_normal_speed()
    state.key_down = false
    state.repeated = false
    state.accelerating = false
    state.paused_ramp = false
    state.toggle = false
    state.target_time = nil
    state.display_mode = "normal"
end

local function timer_needed_at(speed)
    if state.paused_ramp then
        return speed > 1 + EPS
    end

    if state.accelerating or state.toggle or state.target_time then
        return true
    end

    return speed > 1 + EPS
end

local function stop_timer()
    if speed_timer then
        speed_timer:kill()
        speed_timer = nil
    end
end

local adjust_speed

local function ensure_timer()
    if speed_timer then
        if not speed_timer:is_enabled() then
            speed_timer:resume()
        end

        return
    end

    speed_timer = mp.add_periodic_timer(opts.speed_interval, adjust_speed)
end

adjust_speed = function()
    if state.paused_ramp then
        return
    end

    local old_speed = get_speed()
    local speed = old_speed
    local cap = effective_speed_cap(speed)

    if state.accelerating then
        if speed < cap then
            speed = step_up(speed, cap)
        elseif speed > cap then
            speed = step_down(speed, cap)
        else
            speed = cap
        end
    else
        speed = step_down(speed, 1)
    end

    if not almost_equal(speed, old_speed) then
        set_speed(speed)
        show_speed(speed)
    end

    if almost_equal(speed, 1) and not state.accelerating and not state.toggle and not state.target_time then
        set_speed(1)
        reset_state_at_normal_speed()
        stop_timer()
        return
    end

    if timer_needed_at(speed) then
        ensure_timer()
    else
        stop_timer()
    end
end

local function start_speedup(mode)
    state.accelerating = true
    state.paused_ramp = false

    if mode == "toggle" then
        state.toggle = true
        state.display_mode = "toggle"
    elseif mode == "target" then
        state.toggle = true
        state.display_mode = "target"
    else
        state.display_mode = "normal"
    end

    adjust_speed()
end

local function start_slowdown()
    state.accelerating = false
    state.paused_ramp = false
    state.toggle = false
    state.target_time = nil
    state.repeated = false

    adjust_speed()
end

local function perform_seek()
    if opts.seek_distance == 0 then
        return
    end

    invalidate_lookahead_cache()

    mp.commandv("seek", opts.seek_distance)

    if opts.show_seek and uosc_available then
        mp.commandv("script-binding", "uosc/flash-timeline")
    end
end

local function handle_down()
    state.key_down = true
    state.repeated = false
    state.paused_ramp = true

    if opts.show_seek and not uosc_available then
        mp.osd_message("▶▶")
    end

    if timer_needed_at(get_speed()) then
        ensure_timer()
    end
end

local function handle_repeat()
    state.key_down = true
    state.repeated = true
    state.paused_ramp = false

    start_speedup("normal")
end

local function handle_up_or_press()
    state.key_down = false
    state.paused_ramp = false

    local was_repeat = state.repeated

    if not was_repeat or state.target_time then
        perform_seek()
    end

    state.repeated = false

    if not state.toggle then
        start_slowdown()
    elseif was_repeat then
        -- A normal held key should always slow down after release.
        start_slowdown()
    end
end

local function evafast(keypress)
    local event = keypress and keypress.event

    if opts.seek_distance == 0 then
        if event == "down" or event == "repeat" or event == "press" then
            state.repeated = true
            start_speedup("normal")
        elseif event == "up" then
            start_slowdown()
        end

        return
    end

    if event == "down" then
        handle_down()
    elseif event == "repeat" then
        handle_repeat()
    elseif event == "up" or event == "press" then
        handle_up_or_press()
    end
end

local function evafast_speedup()
    state.target_time = nil
    start_speedup("toggle")
end

local function evafast_slowdown()
    start_slowdown()
end

local function evafast_toggle()
    if state.accelerating or state.toggle or state.target_time then
        evafast_slowdown()
    else
        evafast_speedup()
    end
end

mp.register_script_message("uosc-version", function()
    uosc_available = true
end)

mp.register_script_message("speedup", evafast_speedup)
mp.register_script_message("slowdown", evafast_slowdown)
mp.register_script_message("toggle", evafast_toggle)

mp.register_script_message("speedup-target", function(time)
    time = tonumber(time)

    if not time then
        return
    end

    local current_time = mp.get_property_number("time-pos", 0) or 0

    if current_time >= time then
        if state.target_time then
            evafast_slowdown()
        end

        return
    end

    state.target_time = time
    start_speedup("target")
end)

mp.register_script_message("get-version", function(script)
    if script and script ~= "" then
        mp.commandv("script-message-to", script, "evafast-version", VERSION)
    end
end)

mp.add_key_binding("RIGHT", "evafast", evafast, {
    repeatable = true,
    complex = true,
})

mp.add_key_binding(nil, "speedup", evafast_speedup)
mp.add_key_binding(nil, "slowdown", evafast_slowdown)
mp.add_key_binding(nil, "toggle", evafast_toggle)

mp.commandv("script-message-to", "uosc", "get-version", mp.get_script_name())
