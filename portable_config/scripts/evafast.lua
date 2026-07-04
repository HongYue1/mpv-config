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
    -- How far to jump on press.
    -- Set to 0 to disable tap-seeking and use pure hold-to-fast-forward.
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
    -- Only used when lookahead=yes. 0.50s is highly recommended to save CPU.
    lookahead_cache_interval = 0.50,

    -- Restore the user's custom base playback speed when releasing the hold.
    restore_user_speed = true,
}

options.read_options(opts, "evafast")

local VERSION = "2.4.1"
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
local original_speed = 1.0
local probing_subs = false

-- Subtitle tracking state
local sub_is_active = false
local primary_sub_active = false
local secondary_sub_active = false
local sub_visible = true
local secondary_sub_visible = true

-- Cache state
local lookahead_cache_time = -INF
local lookahead_cache_media_time = 0
local lookahead_cache_value = nil
local last_observed_sub_delay = nil
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

local function normalize_positive_number(value, fallback)
    local n = tonumber(value)

    if not valid_number(n) or n <= 0 then
        return fallback
    end

    return n
end

local function normalize_speed_cap(value, fallback)
    local n = tonumber(value)

    if not valid_number(n) or n <= 1 + EPS then
        return fallback
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
opts.speed_increase = normalize_positive_number(opts.speed_increase, 0.1)
opts.speed_decrease = normalize_positive_number(opts.speed_decrease, 0.1)
opts.speed_interval = normalize_number(opts.speed_interval, 0.05, 0.01)
opts.speed_cap = normalize_speed_cap(opts.speed_cap, 2)
opts.subs_speed_cap = normalize_optional_number(opts.subs_speed_cap)
opts.speed_osd_interval = normalize_number(opts.speed_osd_interval, 0.10, 0)
opts.lookahead_cache_interval = normalize_number(opts.lookahead_cache_interval, 0.50, 0)

if opts.subs_speed_cap then
    opts.subs_speed_cap = min(opts.speed_cap, max(1, opts.subs_speed_cap))

    if opts.subs_speed_cap >= opts.speed_cap - EPS then
        opts.subs_speed_cap = nil
        opts.lookahead = false
    end
end

local function almost_equal(a, b)
    return abs((a or 0) - (b or 0)) <= EPS
end

local function invalidate_lookahead_cache()
    if probing_subs then return end
    lookahead_cache_time = -INF
    lookahead_cache_media_time = 0
    lookahead_cache_value = nil
end

local function get_speed()
    return mp.get_property_number("speed", 1) or 1
end

local function set_speed(speed)
    speed = max(0.1, tonumber(speed) or 1)

    if almost_equal(speed, original_speed) then
        speed = original_speed
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
    floor = floor or original_speed

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
    from_speed = max(0.1, tonumber(from_speed) or 1)
    to_speed = max(0.1, tonumber(to_speed) or 1)

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

-- Approximate media-time distance covered while ramping from from_speed to
-- to_speed, assuming the newly set speed is used for the next timer interval.
local function ramp_media_distance(from_speed, to_speed)
    from_speed = max(0.1, tonumber(from_speed) or 1)
    to_speed = max(0.1, tonumber(to_speed) or 1)

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

    -- Safety check: prevent mathematical breakdown on reverse multipliers >= 1.0
    if opts.multiply_modifier and not increasing and modifier >= 1 then
        return to_speed * opts.speed_interval
    end

    local k = steps - 1
    local sum

    if opts.multiply_modifier then
        local factor

        if increasing then
            factor = 1 + modifier
        else
            factor = 1 - modifier
        end

        sum = from_speed * factor * ((factor ^ k) - 1) / (factor - 1) + to_speed
    else
        if increasing then
            sum = k * from_speed + modifier * k * (k + 1) / 2 + to_speed
        else
            sum = k * from_speed - modifier * k * (k + 1) / 2 + to_speed
        end
    end

    return max(0, sum) * opts.speed_interval
end

local function seconds_to_next_subtitle()
    if not opts.subs_speed_cap then
        return nil
    end

    local sid = mp.get_property("sid")
    local primary_active = sid and sid ~= "no"

    local has_secondary_delay = mp.get_property("secondary-sub-delay") ~= nil
    local secondary_sid = has_secondary_delay and mp.get_property("secondary-sid") or nil
    local secondary_active = secondary_sid and secondary_sid ~= "no"

    if not primary_active and not secondary_active then
        return nil
    end

    local closest_delta = nil
    probing_subs = true

    -- WIN: Unified DRY Subtitle Probe Helper
    local function probe(secondary)
        local prefix = secondary and "secondary-" or ""
        local delay_prop = prefix .. "sub-delay"
        local step_cmd = "no-osd sub-step 1" .. (secondary and " secondary" or "")

        local old_delay = mp.get_property_number(delay_prop, 0) or 0
        local ok = pcall(mp.command, step_cmd)
        local new_delay = mp.get_property_number(delay_prop, old_delay) or old_delay

        pcall(mp.set_property_number, delay_prop, old_delay)

        if not secondary then
            -- Pre-set the dedupe baseline so the async restore callback is a no-op.
            last_observed_sub_delay = old_delay
        end

        if ok then
            local delta = old_delay - new_delay
            if delta > 0 then
                if not closest_delta or delta < closest_delta then
                    closest_delta = delta
                end
            end
        end
    end

    if primary_active then
        probe(false)
    end

    if secondary_active then
        probe(true)
    end

    probing_subs = false
    return closest_delta
end

local function seconds_to_next_subtitle_cached()
    local now = mp.get_time()
    local current_media_time = mp.get_property_number("time-pos") or 0

    if opts.lookahead_cache_interval > 0 and now - lookahead_cache_time < opts.lookahead_cache_interval then
        if lookahead_cache_value then
            local elapsed_media = current_media_time - lookahead_cache_media_time
            return max(0, lookahead_cache_value - elapsed_media)
        else
            return nil
        end
    end

    local val = seconds_to_next_subtitle()

    lookahead_cache_time = now
    lookahead_cache_media_time = current_media_time
    lookahead_cache_value = val

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
                local worst_speed = max(speed, opts.speed_cap)
                local correction_distance = ramp_media_distance(worst_speed, opts.subs_speed_cap)

                if next_sub <= correction_distance + EPS then
                    cap = opts.subs_speed_cap
                end
            end
        end
    end

    return max(0.1, cap)
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

        if remaining <= max(speed, 1) * opts.speed_interval + EPS then
            state.target_braking = true
            return original_speed
        end

        if state.target_braking then
            return original_speed
        end

        local braking_distance = ramp_media_distance(speed, original_speed)

        if remaining <= braking_distance + EPS then
            state.target_braking = true
            return original_speed
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
        if ok then return end
        uosc_available = false
    end

    -- Duration passed dynamically in seconds (not multiplied to prevent long-locking).
    -- speed_osd_interval=0 disables throttling, so fall back to a fixed flash
    -- duration here (0 is truthy in Lua, so `or 0.5` alone would not catch it).
    local dur = opts.speed_osd_interval > 0 and opts.speed_osd_interval or 0.5
    mp.osd_message(("▶▶ x%.2f"):format(speed), dur)
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
    if mp.get_property_bool("pause") then
        return false
    end

    if state.paused_ramp then
        return speed > original_speed + EPS
    end

    if state.accelerating or state.toggle or state.target_time then
        return true
    end

    return speed > original_speed + EPS
end

local function stop_timer()
    if speed_timer then
        speed_timer:kill()
        speed_timer = nil
    end
end

local adjust_speed

local function ensure_timer()
    if mp.get_property_bool("pause") then
        return
    end
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
        speed = step_down(speed, original_speed)
    end

    if not almost_equal(speed, old_speed) then
        set_speed(speed)
        show_speed(speed)
    end

    if almost_equal(speed, original_speed) and not state.accelerating and not state.toggle and not state.target_time then
        set_speed(original_speed)
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
    -- Capture exact starting speed to restore to original_speed floor on key release
    if not owns_speed then
        original_speed = opts.restore_user_speed and get_speed() or 1.0
    end

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
        state.toggle = false
        state.target_time = nil
        state.target_braking = false
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

    -- WIN: exact seek prevents rounding and landing on the wrong scene cut frame
    mp.commandv("seek", opts.seek_distance, "relative+exact")

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
        if event == "down" or event == "repeat" then
            state.repeated = true
            start_speedup("normal")
        elseif event == "up" then
            start_slowdown()
        elseif event == "press" then
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
        or state.target_time ~= nil
        or state.repeated

    reset_state_at_normal_speed()

    if should_reset_speed then
        pcall(mp.set_property_number, "speed", original_speed)
    end

    original_speed = 1.0
    owns_speed = false
    invalidate_lookahead_cache()
end

if opts.subs_speed_cap then
    local has_secondary = mp.get_property("secondary-sub-delay") ~= nil

    local function update_sub_active()
        local primary = primary_sub_active and sub_visible
        local secondary = has_secondary and secondary_sub_active and secondary_sub_visible
        sub_is_active = primary or secondary
        invalidate_lookahead_cache()
    end

    primary_sub_active = mp.get_property_native("sub-start") ~= nil
    sub_visible = mp.get_property_native("sub-visibility") ~= false

    if has_secondary then
        secondary_sub_active = mp.get_property_native("secondary-sub-start") ~= nil
        secondary_sub_visible = mp.get_property_native("secondary-sub-visibility") ~= false
    end

    update_sub_active()

    mp.observe_property("sub-start", "native", function(_, value)
        primary_sub_active = value ~= nil
        update_sub_active()
    end)
    mp.observe_property("sub-visibility", "bool", function(_, value)
        sub_visible = value ~= false
        update_sub_active()
    end)

    if has_secondary then
        mp.observe_property("secondary-sub-start", "native", function(_, value)
            secondary_sub_active = value ~= nil
            update_sub_active()
        end)
        mp.observe_property("secondary-sub-visibility", "bool", function(_, value)
            secondary_sub_visible = value ~= false
            update_sub_active()
        end)
        mp.observe_property("secondary-sid", "native", invalidate_lookahead_cache)
    end

    mp.observe_property("sub-delay", "native", function(_, value)
        -- Dedupe by value: the subtitle probe restores sub-delay to its original
        -- value, but that observer callback is delivered asynchronously (possibly
        -- after probing_subs is cleared). Skipping no-op changes prevents
        -- needlessly invalidating a freshly computed lookahead cache.
        if value == last_observed_sub_delay then
            return
        end
        last_observed_sub_delay = value
        invalidate_lookahead_cache()
    end)
    mp.observe_property("sid", "native", invalidate_lookahead_cache)
end

-- WIN: Halt timer logic when player is manually paused (Pause awareness)
mp.observe_property("pause", "bool", function(_, paused)
    if paused then
        stop_timer()
    elseif timer_needed_at(get_speed()) then
        ensure_timer()
    end
end)

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
