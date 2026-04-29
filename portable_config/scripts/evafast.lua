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

local options = require "mp.options"

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

options.read_options(opts, "evafast")

local VERSION = "2.2.0"
local EPS = 0.0001
local INF = math.huge

local abs = math.abs
local ceil = math.ceil
local log = math.log
local max = math.max
local min = math.min

local uosc_available = false
local speed_timer = nil
local owns_speed = false

local sub_is_active = false
local lookahead_cache_time = -INF
local lookahead_cache_value = nil
local last_speed_osd_time = -INF

local state = {
    key_down = false,
    repeated = false,

    accelerating = false,
    paused_ramp = false,

    toggle = false,
    target_time = nil,
    target_braking = false,

    -- normal, toggle, target
    display_mode = "normal",
}

local function valid_number(n)
    return n and n == n and n ~= INF and n ~= -INF
end

local function normalize_number(value, fallback, min_value)
    local n = tonumber(value)

    if not valid_number(n) then
        n = fallback
    end

    if min_value and n < min_value then
        n = min_value
    end

    return n
end

local function normalize_optional_number(value)
    if value == nil or value == false then
        return nil
    end

    if type(value) == "string" then
        local v = value:lower()

        if v == "" or v == "no" or v == "false" or v == "nil" or v == "none" then
            return nil
        end
    end

    local n = tonumber(value)

    if not valid_number(n) then
        return nil
    end

    return n
end

opts.seek_distance = normalize_number(opts.seek_distance, 5, 0)
opts.speed_increase = normalize_number(opts.speed_increase, 0.1, 0)
opts.speed_decrease = normalize_number(opts.speed_decrease, 0.1, 0)
opts.speed_interval = normalize_number(opts.speed_interval, 0.05, 0.001)
opts.speed_cap = normalize_number(opts.speed_cap, 2, 1)
opts.subs_speed_cap = normalize_optional_number(opts.subs_speed_cap)
opts.speed_osd_interval = normalize_number(opts.speed_osd_interval, 0.10, 0)
opts.lookahead_cache_interval = normalize_number(opts.lookahead_cache_interval, 0.15, 0)

if opts.subs_speed_cap then
    -- Subtitle cap should be a stricter cap, never higher than the normal cap.
    opts.subs_speed_cap = min(opts.speed_cap, max(1, opts.subs_speed_cap))

    if opts.subs_speed_cap >= opts.speed_cap - EPS then
        -- Same effective cap; no need for subtitle-specific logic.
        opts.subs_speed_cap = nil
        opts.lookahead = false
    end
end

local function almost_equal(a, b)
    return abs((a or 0) - (b or 0)) <= EPS
end

local function invalidate_lookahead_cache()
    lookahead_cache_time = -INF
    lookahead_cache_value = nil
end

local function get_speed()
    return mp.get_property_number("speed", 1) or 1
end

local function set_speed(speed)
    speed = max(1, tonumber(speed) or 1)

    if almost_equal(speed, 1) then
        speed = 1
    end

    mp.set_property_number("speed", speed)
    owns_speed = true
end

local function step_up(speed, cap)
    if speed >= cap - EPS then
        return cap
    end

    local delta = opts.multiply_modifier and speed * opts.speed_increase or opts.speed_increase

    if delta <= 0 then
        return speed
    end

    local next_speed = min(speed + delta, cap)

    if almost_equal(next_speed, cap) then
        return cap
    end

    return next_speed
end

local function step_down(speed, floor)
    floor = floor or 1

    if speed <= floor + EPS then
        return floor
    end

    local delta = opts.multiply_modifier and speed * opts.speed_decrease or opts.speed_decrease

    if delta <= 0 then
        return speed
    end

    local next_speed = max(speed - delta, floor)

    if almost_equal(next_speed, floor) then
        return floor
    end

    return next_speed
end

local function ramp_steps(from_speed, to_speed)
    from_speed = max(1, tonumber(from_speed) or 1)
    to_speed = max(1, tonumber(to_speed) or 1)

    if almost_equal(from_speed, to_speed) then
        return 0
    end

    local increasing = from_speed < to_speed
    local modifier = increasing and opts.speed_increase or opts.speed_decrease

    if modifier <= 0 then
        return INF
    end

    local steps

    if opts.multiply_modifier then
        if increasing then
            steps = ceil(log(to_speed / from_speed) / log(1 + modifier) - EPS)
        else
            if modifier >= 1 then
                steps = 1
            else
                steps = ceil(log(to_speed / from_speed) / log(1 - modifier) - EPS)
            end
        end
    else
        steps = ceil(abs(to_speed - from_speed) / modifier - EPS)
    end

    return max(0, steps)
end

local function transition_time(from_speed, to_speed)
    local steps = ramp_steps(from_speed, to_speed)

    if steps == INF then
        return INF
    end

    return steps * opts.speed_interval
end

-- Approximate media-time distance covered while ramping from from_speed to
-- to_speed, assuming the newly set speed is used for the next timer interval.
local function ramp_media_distance(from_speed, to_speed)
    from_speed = max(1, tonumber(from_speed) or 1)
    to_speed = max(1, tonumber(to_speed) or 1)

    if almost_equal(from_speed, to_speed) then
        return 0
    end

    local steps = ramp_steps(from_speed, to_speed)

    if steps == INF then
        return INF
    end

    if steps <= 0 then
        return 0
    end

    if steps == 1 then
        return to_speed * opts.speed_interval
    end

    local increasing = from_speed < to_speed
    local modifier = increasing and opts.speed_increase or opts.speed_decrease
    local k = steps - 1
    local sum

    if opts.multiply_modifier then
        local factor

        if increasing then
            factor = 1 + modifier
        else
            if modifier >= 1 then
                return to_speed * opts.speed_interval
            end

            factor = 1 - modifier
        end

        -- Sum of from_speed * factor^i for i = 1..k, plus final capped speed.
        sum = from_speed * factor * ((factor ^ k) - 1) / (factor - 1) + to_speed
    else
        if increasing then
            -- Sum of from_speed + i * modifier for i = 1..k, plus final cap.
            sum = k * from_speed + modifier * k * (k + 1) / 2 + to_speed
        else
            -- Sum of from_speed - i * modifier for i = 1..k, plus final floor.
            sum = k * from_speed - modifier * k * (k + 1) / 2 + to_speed
        end
    end

    return max(0, sum) * opts.speed_interval
end

local function seconds_to_next_subtitle()
    local old_delay = mp.get_property_number("sub-delay", 0) or 0
    local old_visibility = mp.get_property_native("sub-visibility")

    local ok = pcall(function()
        if old_visibility then
            mp.set_property_native("sub-visibility", false)
        end

        mp.command("no-osd sub-step 1")
    end)

    local new_delay = mp.get_property_number("sub-delay", old_delay) or old_delay

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

    if delta > 0 then
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

    if opts.subs_speed_cap then
        if sub_is_active then
            cap = opts.subs_speed_cap
        elseif opts.lookahead then
            local next_sub = seconds_to_next_subtitle_cached()

            if next_sub then
                -- Be conservative: assume we might reach the normal cap before
                -- needing to decelerate back to the subtitle cap.
                local worst_speed = max(speed, opts.speed_cap)
                local correction_distance = ramp_media_distance(worst_speed, opts.subs_speed_cap)

                if next_sub <= correction_distance + EPS then
                    cap = opts.subs_speed_cap
                end
            end
        end
    end

    return max(1, cap)
end

local function finish_target()
    state.target_time = nil
    state.target_braking = false
    state.accelerating = false
    state.toggle = false
    state.display_mode = "normal"
end

local function effective_speed_cap(speed)
    local cap = base_speed_cap(speed)

    if state.target_time then
        local current_time = mp.get_property_number("time-pos")

        if not current_time then
            return cap
        end

        local remaining = state.target_time - current_time

        if remaining <= EPS then
            finish_target()
            return cap
        end

        if state.target_braking then
            return 1
        end

        local braking_distance = ramp_media_distance(speed, 1)

        if remaining <= braking_distance + EPS then
            state.target_braking = true
            return 1
        end
    end

    return cap
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
        local ok = pcall(mp.commandv, "script-binding", "uosc/flash-speed")

        if ok then
            return
        end

        uosc_available = false
    end

    mp.osd_message(("▶▶ x%.2f"):format(speed))
end

local function reset_state_at_normal_speed()
    state.key_down = false
    state.repeated = false
    state.accelerating = false
    state.paused_ramp = false
    state.toggle = false
    state.target_time = nil
    state.target_braking = false
    state.display_mode = "normal"
end

local function timer_needed_at(speed)
    if state.paused_ramp then
        return speed > 1 + EPS
    end

    if state.target_time then
        return true
    end

    if state.accelerating or state.toggle then
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
    if not speed_timer then
        speed_timer = mp.add_periodic_timer(opts.speed_interval, adjust_speed)
    end
end

adjust_speed = function()
    if state.paused_ramp then
        return
    end

    local old_speed = get_speed()
    local speed = old_speed
    local cap = effective_speed_cap(speed)

    if state.accelerating then
        if speed < cap - EPS then
            speed = step_up(speed, cap)
        elseif speed > cap + EPS then
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
        owns_speed = false
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
    last_speed_osd_time = -INF

    if mode == "toggle" then
        state.toggle = true
        state.target_time = nil
        state.target_braking = false
        state.display_mode = "toggle"
    elseif mode == "target" then
        state.toggle = true
        state.target_braking = false
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
    state.target_braking = false
    state.repeated = false

    adjust_speed()
end

local function perform_seek()
    if almost_equal(opts.seek_distance, 0) then
        return
    end

    invalidate_lookahead_cache()

    mp.commandv("seek", opts.seek_distance, "relative")

    if opts.show_seek and uosc_available then
        local ok = pcall(mp.commandv, "script-binding", "uosc/flash-timeline")

        if not ok then
            uosc_available = false
        end
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

    if not was_repeat then
        perform_seek()
    end

    state.repeated = false

    if was_repeat or not state.toggle then
        start_slowdown()
    end
end

local function evafast(keypress)
    local event = keypress and keypress.event

    if almost_equal(opts.seek_distance, 0) then
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
    state.target_braking = false
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

local function evafast_speedup_target(time)
    time = tonumber(time)

    if not valid_number(time) then
        return
    end

    local current_time = mp.get_property_number("time-pos")

    if not current_time then
        return
    end

    if current_time >= time then
        if state.target_time then
            evafast_slowdown()
        end

        return
    end

    state.target_time = time
    state.target_braking = false
    start_speedup("target")
end

local function hard_reset()
    stop_timer()

    local should_reset_speed =
        owns_speed
        or state.accelerating
        or state.toggle
        or state.target_time
        or state.repeated

    reset_state_at_normal_speed()

    if should_reset_speed then
        mp.set_property_number("speed", 1)
    end

    owns_speed = false
    invalidate_lookahead_cache()
end

if opts.subs_speed_cap then
    sub_is_active = mp.get_property_native("sub-start") ~= nil

    mp.observe_property("sub-start", "native", function(_, value)
        sub_is_active = value ~= nil
        invalidate_lookahead_cache()
    end)

    mp.observe_property("sub-delay", "native", invalidate_lookahead_cache)
    mp.observe_property("sid", "native", invalidate_lookahead_cache)
    mp.observe_property("secondary-sid", "native", invalidate_lookahead_cache)
end

mp.register_event("seek", invalidate_lookahead_cache)
mp.register_event("file-loaded", invalidate_lookahead_cache)
mp.register_event("tracks-changed", invalidate_lookahead_cache)
mp.register_event("end-file", hard_reset)
mp.register_event("shutdown", hard_reset)

mp.register_script_message("uosc-version", function()
    uosc_available = true
end)

mp.register_script_message("speedup", evafast_speedup)
mp.register_script_message("slowdown", evafast_slowdown)
mp.register_script_message("toggle", evafast_toggle)
mp.register_script_message("speedup-target", evafast_speedup_target)

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

pcall(mp.commandv, "script-message-to", "uosc", "get-version", mp.get_script_name())
